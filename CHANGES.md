# in-cluster-defaults — changes to apply in the air-gapped repos

Everything done in this mock since the start, as git-style unified diffs against the
pre-change (production) file contents. `-` lines exist today, `+` lines are the
additions — there are **no removed or modified lines anywhere, only additions and
new files**. Line numbers may drift slightly if a prod file differs from the mock;
anchor each hunk by its context lines, not by line number.

---

## ⚠️ Apply order

1. **`argocd-day2-platform`** — all five diffs below, **one commit** (the
   clustersAppset exclude and the new static `inClusterApp.yaml` must never ship
   separately — apart they produce a missing or duplicated `<group>-in-cluster`
   app).
   Impact per MCE:
   - **MCE that has a `mces/<mce>/in-cluster/` folder** — one-time ownership
     handoff of `<group>-in-cluster` from the clusters appset to the static
     template. The appset cascade-deletes the Argo CR subtree (operators appset,
     generated apps, deploy app CRs) and the static app rebuilds it under the
     same names. **Deployed workloads are untouched** (deploy apps carry no
     resources finalizer; the rebuilt apps re-adopt by comparison — same names,
     same releaseNames), but expect a few minutes of Argo CR churn per MCE with
     no self-heal for those apps during the window. Optional zero-churn variant:
     right before the push, strip the finalizer from `<group>-in-cluster` on
     each MCE hub (`kubectl -n gitops-<group> patch application
     <group>-in-cluster --type json -p
     '[{"op":"remove","path":"/metadata/finalizers"}]'`) — then the operators
     appset survives the handoff and nothing below it is recreated. A lost race
     (controller re-adds the finalizer before the push lands) merely degrades to
     the churn case.
   - **MCE without an `in-cluster/` folder** — gains a dormant static
     `<group>-in-cluster` app plus an empty operators appset, and from then on
     receives defaults charts automatically (this is the point of the static
     app: defaults no longer require the folder to exist).
   - **Hosted (spoke) cluster apps** — render byte-identical.
   *Preconditions:* verify no team's sigs repo already contains a folder named
   `mces/in-cluster-defaults` — and in particular none with the OLD nested
   `charts/` layout (this doc's layout is flat; a `charts/` directory would be
   generated as a bogus `<group>-in-cluster-charts` app on every hub); verify
   nothing besides the mcesAppset scans `mces/*` in team repos.
2. **`sigs/redbull`** — add the folder (flat layout below). **Never before
   step 1**: without the mcesAppset exclude, the folder is generated as a bogus
   "MCE" Application with a nonexistent destination cluster.
3. Per chart, later: add new charts (new apps only) or migrate duplicated ones
   (runbook in the folder's README — verify pre-merge, `selfHeal` leaves no
   post-merge window).

---

## Repo 1: `argocd-day2-platform`

### `mces/templates/mcesAppset.yaml` — exclude the defaults folder from MCE discovery

```diff
--- a/mces/templates/mcesAppset.yaml
+++ b/mces/templates/mcesAppset.yaml
@@ -10,6 +10,8 @@
         revision: main
         directories:
           - path: "mces/*"
+          - path: "mces/in-cluster-defaults"
+            exclude: true
   template:
     metadata:
       name: '{{ .Values.group }}-{{ "{{" }}path.basename{{ "}}" }}'
```

### `clusters/templates/clustersAppset.yaml` — stop discovering `in-cluster` from git

```diff
--- a/clusters/templates/clustersAppset.yaml
+++ b/clusters/templates/clustersAppset.yaml
@@ -9,6 +9,8 @@
         revision: main
         directories:
           - path: "mces/{{ .Values.mce }}/*"
+          - path: "mces/{{ .Values.mce }}/in-cluster"
+            exclude: true
   template:
     metadata:
```

### `clusters/templates/inClusterApp.yaml` — NEW FILE: static in-cluster Application

The MCE hub app is rendered unconditionally per MCE instead of being discovered
from a `mces/<mce>/in-cluster/` folder — so defaults reach every MCE hub even
when that folder doesn't exist. Ships atomically with the exclude above (same
commit). Pure Helm — no `path.basename` escaping. The `repoURL` must match the
platform-repo URL your prod clustersAppset template already uses.

```diff
--- /dev/null
+++ b/clusters/templates/inClusterApp.yaml
@@ -0,0 +1,26 @@
+apiVersion: argoproj.io/v1alpha1
+kind: Application
+metadata:
+  name: {{ .Values.group }}-in-cluster
+  namespace: gitops-{{ .Values.group }}
+spec:
+  project: '{{ .Values.group }}'
+  sources:
+    - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/argocd-day2-platform.git'
+      targetRevision: main
+      path: operators
+      helm:
+        ignoreMissingValueFiles: true
+        values: |
+          group: '{{ .Values.group }}'
+          mce: {{ .Values.mce }}
+          cluster: 'in-cluster'
+  destination:
+    name: in-cluster
+    namespace: gitops-{{ .Values.group }}
+  syncPolicy:
+    automated:
+      selfHeal: true
+      prune: false
+    syncOptions:
+      - CreateNamespace=true
```

### `operators/templates/operators.yaml` — second generator + config layer (in-cluster only)

```diff
--- a/operators/templates/operators.yaml
+++ b/operators/templates/operators.yaml
@@ -10,6 +10,13 @@
         revision: main
         directories:
           - path: "mces/{{ .Values.mce }}/{{ .Values.cluster }}/*"
+    {{- if eq .Values.cluster "in-cluster" }}
+    - git:
+        repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+        revision: main
+        directories:
+          - path: "mces/in-cluster-defaults/*"
+    {{- end }}
   template:
     metadata:
       name: '{{ .Values.group }}-{{ .Values.cluster }}-{{ "{{" }}path.basename{{ "}}" }}'
@@ -28,6 +35,9 @@
               operator: {{ "{{" }}path.basename{{ "}}" }}
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              {{- if eq .Values.cluster "in-cluster" }}
+              - '$values/mces/in-cluster-defaults/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              {{- end }}
               - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
         - ref: values
           repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
```

(The generator's `repoURL` line must match whatever the existing generator in your
prod file uses — copy it from the line a few rows above.)

### `deploy/templates/deployApp.yaml` — two value layers (in-cluster only)

Placement is load-bearing: the new layers sit **after** the MCE/cluster-wide files
and **before** the per-cluster chart file — the same precedence slot a chart's own
values occupy today, so migrating a chart cannot flip any colliding key.

```diff
--- a/deploy/templates/deployApp.yaml
+++ b/deploy/templates/deployApp.yaml
@@ -24,6 +24,10 @@
           - '$values/operators/{{ .Values.operator }}/values.yaml'
           - '$values/mces/{{ .Values.mce }}/values.yaml'
           - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/values.yaml'
+          {{- if eq .Values.cluster "in-cluster" }}
+          - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values.yaml'
+          - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
+          {{- end }}
           - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/{{ .Values.operator }}/values.yaml'
     - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
       targetRevision: main
```

---

## Repo 2: `sigs/redbull`

New files only — nothing existing was touched.

Layout is **flat** — chart folders sit directly under `in-cluster-defaults/`,
there is no intermediate `charts/` level. Consequence: every directory here
becomes a generated Application, so never create non-chart directories (plain
files like the README are ignored by the directory generator).

```
sigs/redbull/
└── mces/
    └── in-cluster-defaults/          ← NEW
        ├── README.md                  (conventions, precedence, migration runbook — copy verbatim from the mock)
        └── example-chart/             ⚠️ convention demo — do NOT ship to prod (placeholder repoUrl
            │                             would create a failing Application on every MCE)
            ├── example-chart.yaml
            ├── values.yaml                          (empty)
            └── values-ocp4-prep-mce-site1-a.yaml    (empty)
```

```diff
--- /dev/null
+++ b/mces/in-cluster-defaults/example-chart/example-chart.yaml
@@ -0,0 +1,6 @@
+projectNamespace: example-namespace
+repoUrl: ...helm-charts...
+targetRevision: main
+syncPolicy:
+  syncOptions:
+    - CreateNamespace=true
```

In prod, create the folder with your first real chart (or just the README) — a
chart dir here follows the exact same convention as `mces/<mce>/in-cluster/<chart>/`:
`<chart>.yaml` deploy config + `values.yaml`, plus optional `values-<mce>.yaml`
per-MCE overrides.

---

## What was verified

Original implementation (nested `charts/` layout) — live-verified on
Argo CD 3.1.11 via `helm template` old vs new:

| Render                          | Result                                                        |
|---------------------------------|---------------------------------------------------------------|
| operators chart, hosted cluster | byte-identical                                                |
| deploy chart, hosted cluster    | byte-identical                                                |
| mces chart                      | only the two exclude lines                                    |
| operators chart, in-cluster     | only the added generator + one missing-tolerant valueFiles    |
| deploy chart, in-cluster        | only the two missing-tolerant valueFiles                      |
| value resolution on migration   | identical, including deliberately colliding keys              |

2026-08-11 revision (flat layout + static in-cluster app, i.e. the diffs as they
now appear above) — **helm-render verified in the mock only, not yet
live-verified**: clusters chart renders the static app + excluded generator;
operators appset (in-cluster) carries both generators with the flat paths; a
spoke render contains zero in-cluster-defaults references; deploy valueFiles
resolve to the flat paths. Rehearse the ownership handoff in the mock before the
prod push.

Rules that keep it safe long-term (full detail in
`sigs/redbull/mces/in-cluster-defaults/README.md`): a chart lives in defaults XOR
a per-MCE `in-cluster` dir; per-MCE overrides for defaults charts go in
`values-<mce>.yaml` inside the defaults chart dir (never create a per-MCE chart
dir just for values); any future scanner of `mces/*` must replicate the exclude.
