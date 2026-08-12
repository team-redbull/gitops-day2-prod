# Top-level `in-cluster/` (prod-hub charts) — changes to apply in the air-gapped repos

This refactor only: `sigs/<team>/in-cluster/<chart>/` deploys `<chart>` onto the
**prod-hub mgmt cluster itself** (the cluster running the `groups` ApplicationSet
in `openshift-gitops`). It claims the top-level reservation stated in
`sigs/redbull/mces/in-cluster-defaults/README.md`: a folder's name is the
destination as seen by the consuming Argo; the repo top level is consumed by
prod-hub's Argo, and `in-cluster` is prod-hub's name for itself.

Diffs are git-style unified diffs against the pre-change production file
contents. One existing line is **modified** (the deployApp defaults guard —
called out below); everything else is additions and new files. Anchor each hunk
by its context lines, not by line number.

Resulting chain, per team, entirely on prod-hub's Argo:

```
groups app (renders platform mces chart, ns gitops-<group>)
  → ApplicationSet <group>-in-cluster        (git dirs generator: in-cluster/* in team repo)
    → Application <group>-in-cluster-<chart>       (platform deploy chart, hub mode)
      → Application <group>-in-cluster-<chart>-deploy   (the actual helm chart,
        destination in-cluster = prod-hub, namespace = projectNamespace, releaseName <chart>)
```

---

## ⚠️ Apply order — none required

**Both orderings are independently no-ops** (contrast with in-cluster-defaults,
which had a hard exclude-first constraint):

- Nothing in prod scans a team repo's **top-level** directories — the only
  team-repo generators are the `mces/...` ones. Creating `sigs/<team>/in-cluster/`
  before the platform change is inert.
- Shipping the platform change first leaves each `<group>-in-cluster`
  ApplicationSet generating **zero** Applications until that team creates the
  folder.

Impact when the platform change lands:

- **Cross-group blast radius:** the `mces` chart renders for *every* team the
  groups appset discovers — each group's `gitops-<group>` namespace gains one new
  `<group>-in-cluster` ApplicationSet CR (additive resource in the already-synced
  `<repository>` Application; `prune: false`, selfHeal untouched). Zero generated
  Applications everywhere until a team opts in with the folder.
- **Every existing Application renders byte-identically** (verified below): the
  new deployApp entries render only with `hub: true`, which nothing existing
  passes, and the tightened defaults guard is truth-value-identical with `hub`
  unset.

**Precondition before the first real chart folder** (not before the plumbing):
verify the AppProject `<group>` on prod-hub permits destination `in-cluster` plus
the chart's target namespace. Deploy-type Applications under project `<group>`
have never existed on the prod-hub Argo — if `helm-charts/argo-appproject.git`
restricts destinations or namespaces, the first hub app is rejected by the
project. Check once, before onboarding the first tenant.

---

## Repo 1: `argocd-day2-platform`

### `mces/templates/inClusterAppset.yaml` — NEW FILE: hub charts ApplicationSet

Modeled on `operators/templates/operators.yaml` (plain templates, `path.basename`
only). The two team-repo `repoURL` lines and the platform `repoURL` line must
match whatever your prod `mcesAppset.yaml`/`operators.yaml` already use — copy
them from there.

```diff
--- /dev/null
+++ b/mces/templates/inClusterAppset.yaml
@@ -0,0 +1,43 @@
+apiVersion: argoproj.io/v1alpha1
+kind: ApplicationSet
+metadata:
+  name: {{ .Values.group }}-in-cluster
+  namespace: gitops-{{ .Values.group }}
+spec:
+  generators:
+    - git:
+        repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+        revision: main
+        directories:
+          - path: "in-cluster/*"
+  template:
+    metadata:
+      name: '{{ .Values.group }}-in-cluster-{{ "{{" }}path.basename{{ "}}" }}'
+    spec:
+      project: '{{ .Values.group }}'
+      sources:
+        - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/argocd-day2-platform.git'
+          targetRevision: main
+          path: deploy
+          helm:
+            ignoreMissingValueFiles: true
+            values: |
+              group: '{{ .Values.group }}'
+              cluster: in-cluster
+              hub: true
+              operator: {{ "{{" }}path.basename{{ "}}" }}
+            valueFiles:
+              - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              - '$values/in-cluster/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+        - ref: values
+          repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+          targetRevision: main
+      destination:
+        name: in-cluster
+        namespace: gitops-{{ .Values.group }}
+      syncPolicy:
+        automated:
+          selfHeal: true
+          prune: false
+        syncOptions:
+          - CreateNamespace=true
```

Notes:

- `hub: true` is what routes the deploy chart into hub mode (see next diff).
- `cluster: in-cluster` is the prod-hub local cluster's destination name; it also
  makes the generated names follow the existing `<group>-<cluster>-<op>`
  convention. Apps with similar names on the MCE Argos are a different API
  server — no collision, and the overlap is what the naming convention
  prescribes (same word, same meaning, different consuming Argo).
- No `mce` value is passed — the mces-based valueFiles in deployApp render with
  an empty segment (`$values/mces//values.yaml`, …), can never exist, and are
  tolerated by `ignoreMissingValueFiles: true`.
- No generator excludes: every directory under `in-cluster/*` is a chart by
  convention (README rule in the team repo).
- Deliberately uses `.Values.group` everywhere — do **not** copy the
  `namespace: gitops-{{ .Values.repository }}` line from `mcesAppset.yaml`'s
  template into new work (and do not "fix" it there either; out of scope).

### `deploy/templates/deployApp.yaml` — hub value layer + guard tightening

⚠️ Contains this refactor's **only modified line**: the defaults guard gains
`(not .Values.hub)`. Hub apps pass `cluster: in-cluster`, which would otherwise
pull the MCE-fleet defaults layers (`mces/in-cluster-defaults/<op>/values*.yaml`)
into a hub app whenever a chart name exists in both contexts. With `hub` unset,
`not .Values.hub` is true — every existing app renders byte-identically.

The appended hub entry is guarded by `hub: true` for the mirror-image reason:
once a chart exists both on the hub and in the fleet flows,
`in-cluster/<op>/values.yaml` exists in the team repo, and unguarded it would
leak the hub's values into every fleet app for that chart. Appended last =
highest precedence, matching the fleet flow where the most context-specific
file is last.

```diff
--- a/deploy/templates/deployApp.yaml
+++ b/deploy/templates/deployApp.yaml
@@ -24,11 +24,14 @@ spec:
           - '$values/operators/{{ .Values.operator }}/values.yaml'
           - '$values/mces/{{ .Values.mce }}/values.yaml'
           - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/values.yaml'
-          {{- if eq .Values.cluster "in-cluster" }}
+          {{- if and (eq .Values.cluster "in-cluster") (not .Values.hub) }}
           - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values.yaml'
           - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
           {{- end }}
           - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/{{ .Values.operator }}/values.yaml'
+          {{- if .Values.hub }}
+          - '$values/in-cluster/{{ .Values.operator }}/values.yaml'
+          {{- end }}
     - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
       targetRevision: main
       ref: values
```

Effective value stack for a hub app (lowest → highest):
`operators/<chart>/values.yaml` → `in-cluster/<chart>/values.yaml`. There is
deliberately **no** hub-wide `in-cluster/values.yaml` layer — `in-cluster/`
holds only chart folders. Deploy config precedence mirrors it:
`operators/<chart>/<chart>.yaml` → `in-cluster/<chart>/<chart>.yaml`.

---

## Repo 2: `sigs/redbull`

New folder plus one docs edit (the in-cluster-defaults README's "top level is
reserved" paragraph now points at the claimed reservation — copy the updated
paragraph from the mock).

```
sigs/redbull/
├── in-cluster/                       ← NEW
│   ├── README.md                      (conventions, precedence, rollout — copy verbatim from the mock)
│   └── example-chart/                 ⚠️ convention demo — do NOT ship to prod (placeholder repourl
│       │                                 would create a failing Application on prod-hub)
│       ├── example-chart.yaml
│       └── values.yaml                (empty)
└── mces/in-cluster-defaults/README.md (edited paragraph only)
```

```diff
--- /dev/null
+++ b/in-cluster/example-chart/example-chart.yaml
@@ -0,0 +1,10 @@
+# Example deploy config for a chart on the prod-hub mgmt cluster.
+projectNamespace: example-namespace
+# repourl, all lowercase — that is the key deployApp.yaml reads (`.Values.repourl`).
+# Several deploy configs in this repo write `repoUrl`; that spelling reaches the
+# template as nil and renders an empty repoURL, so do not copy it from them.
+repourl: ...helm-charts...
+targetRevision: main
+syncPolicy:
+  syncOptions:
+    - CreateNamespace=true
```

Team-repo rules (full detail in `sigs/redbull/in-cluster/README.md`): every
directory directly under `in-cluster/` becomes an Application on prod-hub —
plain files are ignored and safe, non-chart directories are forbidden; only
chart folders live here (no hub-wide values file); a chart may exist both here
and in the `mces/` flows (different destinations, no XOR — they share only the
`operators/<chart>/` layer); `repourl` is all-lowercase.

---

## What was verified

Helm-render verified in the mock (2026-08-12) — **not yet live-verified**;
`helm template` does not execute git generators, and the AppProject
precondition above can only be checked in prod:

| Render                                                     | Result                                                       |
|------------------------------------------------------------|--------------------------------------------------------------|
| deploy chart: hosted cluster                                | byte-identical                                               |
| deploy chart: MCE in-cluster (exercises tightened guard)    | byte-identical                                               |
| deploy chart: `oldConvention: true`                         | byte-identical                                               |
| deploy chart: `appname` override                            | byte-identical                                               |
| mces chart (`group=redbull`)                                | exactly one added document — the new ApplicationSet; `mcesAppset`/`appProjectAppset` byte-identical |
| deploy chart: hub mode (`hub: true`)                        | hub layer appended last, defaults layers absent, operators layer first; name `redbull-in-cluster-example-chart-deploy`, releaseName `example-chart`, destination `in-cluster` |

First tenant (planned, out of scope here): the DHCP scope manager API root chart
— one folder-add (`in-cluster/dhcp-scope-manager/`, `path: .`,
`projectNamespace: dhcp-scope-manager`) plus removing the app from the
redbull-platform repo. The service is pre-production, so the hand-off needs no
migration ceremony; its `dhcp-api-token` subchart stays per-MCE via
`mces/in-cluster-defaults/`.
