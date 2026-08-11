# in-cluster-defaults — changes to apply in the air-gapped repos

Everything done in this mock since the start, as git-style unified diffs against the
pre-change (production) file contents. `-` lines exist today, `+` lines are the
additions — there are **no removed or modified lines anywhere, only additions and
new files**. Line numbers may drift slightly if a prod file differs from the mock;
anchor each hunk by its context lines, not by line number.

---

## ⚠️ Apply order (this is the only ordering that is zero-impact)

1. **`argocd-day2-platform`** — all three diffs below, one commit. With no
   `mces/in-cluster-defaults/` folder existing yet in any team repo, this is a
   no-op: hosted-cluster apps render byte-identical; in-cluster apps get a
   spec-only update (valueFiles entries pointing at not-yet-existing files,
   tolerated by `ignoreMissingValueFiles: true`).
   *Precondition:* verify no team's sigs repo already contains a folder named
   `mces/in-cluster-defaults`, and that nothing besides the mcesAppset scans
   `mces/*` in team repos.
2. **`sigs/redbull`** — add the folder. **Never before step 1**: without the
   mcesAppset exclude, the folder is generated as a bogus "MCE" Application with
   a nonexistent destination cluster.
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
+          - path: "mces/in-cluster-defaults/charts/*"
+    {{- end }}
   template:
     metadata:
       name: '{{ .Values.group }}-{{ .Values.cluster }}-{{ "{{" }}path.basename{{ "}}" }}'
@@ -28,6 +35,9 @@
               operator: {{ "{{" }}path.basename{{ "}}" }}
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              {{- if eq .Values.cluster "in-cluster" }}
+              - '$values/mces/in-cluster-defaults/charts/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
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
+          - '$values/mces/in-cluster-defaults/charts/{{ .Values.operator }}/values.yaml'
+          - '$values/mces/in-cluster-defaults/charts/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
+          {{- end }}
           - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/{{ .Values.operator }}/values.yaml'
     - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
       targetRevision: main
```

---

## Repo 2: `sigs/redbull`

New files only — nothing existing was touched.

```
sigs/redbull/
└── mces/
    └── in-cluster-defaults/          ← NEW
        ├── README.md                  (conventions, precedence, migration runbook — copy verbatim from the mock)
        └── charts/
            └── example-chart/         ⚠️ convention demo — do NOT ship to prod (placeholder repoUrl
                │                         would create a failing Application on every MCE)
                ├── example-chart.yaml
                ├── values.yaml                          (empty)
                └── values-ocp4-prep-mce-site1-a.yaml    (empty)
```

```diff
--- /dev/null
+++ b/mces/in-cluster-defaults/charts/example-chart/example-chart.yaml
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

## What was verified (Argo CD 3.1.11, `helm template` old vs new)

| Render                          | Result                                                        |
|---------------------------------|---------------------------------------------------------------|
| operators chart, hosted cluster | byte-identical                                                |
| deploy chart, hosted cluster    | byte-identical                                                |
| mces chart                      | only the two exclude lines                                    |
| operators chart, in-cluster     | only the added generator + one missing-tolerant valueFiles    |
| deploy chart, in-cluster        | only the two missing-tolerant valueFiles                      |
| value resolution on migration   | identical, including deliberately colliding keys              |

Rules that keep it safe long-term (full detail in
`sigs/redbull/mces/in-cluster-defaults/README.md`): a chart lives in defaults XOR
a per-MCE `in-cluster` dir; per-MCE overrides for defaults charts go in
`values-<mce>.yaml` inside the defaults chart dir (never create a per-MCE chart
dir just for values); any future scanner of `mces/*` must replicate the exclude.
