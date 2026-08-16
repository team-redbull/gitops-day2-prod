# The sites/ refactor — changes to apply in the air-gapped repos

This hand-off migrates the day2 repos to the architecture in
`REFACTOR-PLAN.md` (deep dive: `ARCHITECTURE.md`):

- `sites/<site>/<env>/mces/<mce>/<cluster>/` tree — env and site become path
  identity; fleet queries become greps and label selectors.
- `config.yaml` per MCE/cluster carrying **`ocpVersion`** — the only version
  key; cluster and MCE upgrades become one-line edits, never folder moves.
- `operators/<chart>/versions/ocp-<v>/` — per-OCP-stream chart pins and
  values; fleet chart upgrades become one-line pin edits.
- `defaults/{hub,mces,hosted-clusters}/` — the three deploy-once fleet
  layers (`hosted-clusters` is NEW: deploy a chart to every hosted cluster).
- `day2.gitops/*` labels on every generated Application — bulk operations by
  selector (`argocd app sync -l day2.gitops/env=prod,day2.gitops/chart=ako`).

**Everything below was implemented and render-verified in the mock repo**
(commit history mirrors the phase order — one commit per step below).
Helm-render verified, **not live-verified**: `helm template` does not execute
git generators; the offline harness (`tools/render-verify/render_chain.py`,
copy it across; it hardcodes `GROUP = "redbull"` near the top — set it to the
team whose repo you are verifying) simulates the documented generator params
and asserts, per phase, that all 35 generated apps keep identical names, destinations,
releaseNames, syncPolicies and identical *resolved value-file content
sequences*. Re-run it against your repos at every phase gate; re-verify
against live Argo behavior on the first phase you apply.

---

## Baseline assumption — read first

This hand-off assumes the two previous hand-offs are already applied:
flattened `mces/in-cluster-defaults/` (chart folders directly under it, static
`inClusterApp.yaml`) and the top-level `in-cluster/` hub flow
(`inClusterAppset.yaml` exists). **Check before starting**; if the top-level
`in-cluster/` flow was never applied, the collapsed variant is:

- Skip the `in-cluster/` → `defaults/hub/` rename in Phase C' — create
  `defaults/hub/` directly and ship `inClusterAppset.yaml` already pointing at
  `defaults/hub/*` (its Phase C'.4 form), together with the rest of Phase B.
- `mces/in-cluster-defaults/` exists in prod either way (it carries
  `dhcp-api-token`) — its rename to `defaults/mces/` cannot be skipped.

Two standing warnings carried forward from the previous hand-off:

- **AppProject precondition for hub apps:** before the first real chart lands
  in `defaults/hub/`, verify the AppProject `<group>` on prod-hub permits
  destination `in-cluster` plus the chart's target namespace. (The planned
  DHCP tenant lands at `defaults/hub/dhcp-scope-manager/`.)
- **Do not fix the `repoUrl` casing bug while in here.** Several deploy
  configs write `repoUrl` (renders an empty `repoURL`); fixing the spelling
  mid-migration would suddenly "un-break" those apps. Separate cleanup,
  separate MR, after the migration settles.

---

## THE ONE INVARIANT

> **At any commit, each MCE / cluster / chart is emitted by exactly one
> generator entry.**

Every ordering rule below (one-commit `git mv`, add-glob-before-remove, the
defaults XOR rule, Phase-A-before-Phase-B) exists to preserve this. What makes
mistakes survivable: app names are built from basenames only (folder moves are
in-place updates), and no Application carries a resources finalizer (a dropped
generator entry orphans workloads in place — cruft, never an outage).

Verification gate at **every** step: run the render harness before merging and
require IDENTITY OK. All platform-layer apps run `selfHeal: true`; there is no
post-merge inspection window.

---

## Phase A — sigs repos: add config.yaml (additive, zero effect)

**Per team repo.** First, inventory the fleet: collect the real OCP version of
every MCE and every hosted cluster. The value is load-bearing, not
decorative — it selects the `operators/<chart>/versions/ocp-<v>/` layers once
Phase B lands. Then add:

`mces/<mce>/config.yaml` (every MCE):

```yaml
env: prod            # this MCE's env: prod | prep | test   ┐ needed only until
site: five           # this MCE's site                      ┘ Phase D
ocpVersion: "4.20"   # the MCE's OWN OCP version. ALWAYS quote — 4.20 unquoted is the float 4.2
```

`mces/<mce>/<cluster>/config.yaml` (every hosted cluster):

```yaml
ocpVersion: "4.20"   # the cluster's OWN version. NEVER env/site here — inherited from the MCE
```

Do **not** create a config.yaml in `mces/in-cluster-defaults/` or in any
`in-cluster/` or chart folder — presence of the file is what will make a
folder an MCE/cluster.

Plain files are invisible to the current directory generators — this phase
changes nothing anywhere (mock: verified zero diff, not even a spec change).

---

## Phase B — platform repo: ONE MR (generators + parametric paths + labels)

> ⚠️ **HARD PRECONDITION: every team repo has completed Phase A before this
> merges.** A team without config.yaml files at switch time gets its
> `<group>-<mce>` apps deleted (workloads orphaned in place, unmanaged until
> the files are added and the same-named apps recreate and re-adopt).

**Six** templates change, and they ship as **one MR / one commit** — this is
where the parameter chain is born: `mcesAppset` starts emitting `mcePath` →
`clustersAppset` / `inClusterApp` emit `clusterPath` + `ocpVersion` →
`operators` / `deployApp` consume them. Split across pushes and there is an
intermediate commit where a template reads a `{{ .Values.clusterPath }}` that
nobody passes yet — empty path segments in live app specs, with `selfHeal: true`
and no inspection window. `groups/templates/groupsAppset.yaml` and
`mces/templates/appProjectAppset.yaml` are **untouched**.

| # | File | What changes |
|---|---|---|
| 1 | `mces/templates/mcesAppset.yaml` | `directories` → `files` generator; emit mcePath/env/site/ocpVersion; labels |
| 2 | `clusters/templates/clustersAppset.yaml` | `directories` → `files`, parametric; emit clusterPath + the cluster's own ocpVersion; labels |
| 3 | `clusters/templates/inClusterApp.yaml` | parametric passthrough (no ocpVersion override); labels |
| 4 | `operators/templates/operators.yaml` | gen-1 parametric; version-pin layer in the config stack; labels |
| 5 | `deploy/templates/deployApp.yaml` | parametric paths + version/site layers; hub branch split out; labels |
| 6 | `mces/templates/inClusterAppset.yaml` | labels only (6 lines) |

Every hunk below is the mock's Phase B commit verbatim, with one substitution:
`repoURL:` values are shown as `<sigs repo URL — unchanged>`. Two transplant
rules:

- **`repoURL:` lines keep whatever your prod files already have.** They appear
  as context so you can find the hunk — never edit them.
- **The `namespace: gitops-{{ .Values.repository }}` line in `mcesAppset.yaml`
  is FROZEN.** It appears below as unchanged context. Keep it byte-identical
  (it renders `gitops-`; "fixing" it changes every generated app's namespace →
  app identity → fleet-wide delete/recreate).

Locate each hunk by its context lines — the mock's line numbers won't match
your files.

### 1. `mces/templates/mcesAppset.yaml`

**1a — generator + labels** (`spec.generators` through `spec.template.metadata`):

```diff
     - git:
         repoURL: <sigs repo URL — unchanged>
         revision: main
-        directories:
-          - path: "mces/*"
-          - path: "mces/in-cluster-defaults"
-            exclude: true
+        # An MCE is a folder holding a config.yaml (env, site, ocpVersion).
+        # Folders without one (in-cluster-defaults, docs, ...) are invisible —
+        # this replaces the old in-cluster-defaults exclude. The two globs
+        # serve the legacy layout and the sites/ tree during the migration
+        # window; the legacy one is removed in Phase D.
+        files:
+          - path: "mces/*/config.yaml"
+          - path: "sites/*/*/mces/*/config.yaml"
   template:
     metadata:
       name: '{{ .Values.group }}-{{ "{{" }}path.basename{{ "}}" }}'
       namespace: gitops-{{ .Values.repository }}
+      labels:
+        day2.gitops/team: '{{ .Values.group }}'
+        day2.gitops/env: '{{ "{{" }}env{{ "}}" }}'
+        day2.gitops/site: '{{ "{{" }}site{{ "}}" }}'
+        day2.gitops/mce: '{{ "{{" }}path.basename{{ "}}" }}'
+        day2.gitops/ocp-version: '{{ "{{" }}ocpVersion{{ "}}" }}'
+        day2.gitops/role: mce
     spec:
```

☝️ The `namespace:` line inside that hunk is the FROZEN one — it is context,
not a change. **Both** `files:` globs are required in Phase B: dropping the
legacy `mces/*/config.yaml` here instead of in Phase D deletes the apps of
every MCE that has not moved yet.

**1b — pass the new params down** (`spec.template.spec.source.helm.values`):

```diff
           values: |
             group: '{{ .Values.group }}'
             mce: '{{ "{{" }}path.basename{{ "}}" }}'
+            mcePath: '{{ "{{" }}path{{ "}}" }}'
+            env: '{{ "{{" }}env{{ "}}" }}'
+            site: '{{ "{{" }}site{{ "}}" }}'
+            ocpVersion: '{{ "{{" }}ocpVersion{{ "}}" }}'
       destination:
         name: '{{ "{{" }}path.basename{{ "}}" }}'
```

`{{path.basename}}` of the directory containing config.yaml equals the old
directory-generator basename, so **generated app names and destinations are
unchanged**. `env` / `site` / `ocpVersion` are appset placeholders resolved
from the config.yaml fields (Phase D switches env/site to path segments).

### 2. `clusters/templates/clustersAppset.yaml`

**2a — generator + labels:**

```diff
     - git:
         repoURL: <sigs repo URL — unchanged>
         revision: main
-        directories:
-          - path: "mces/{{ .Values.mce }}/*"
-          - path: "mces/{{ .Values.mce }}/in-cluster"
-            exclude: true
+        # A hosted cluster is a folder holding a config.yaml (ocpVersion only;
+        # env/site are inherited from the MCE). in-cluster/ and chart folders
+        # have no config.yaml and are invisible — this replaces the old
+        # in-cluster exclude.
+        files:
+          - path: "{{ .Values.mcePath }}/*/config.yaml"
   template:
     metadata:
       name: '{{ .Values.group }}-{{ "{{" }}path.basename{{ "}}" }}'
+      labels:
+        day2.gitops/team: '{{ .Values.group }}'
+        day2.gitops/env: '{{ .Values.env }}'
+        day2.gitops/site: '{{ .Values.site }}'
+        day2.gitops/mce: '{{ .Values.mce }}'
+        day2.gitops/cluster: '{{ "{{" }}path.basename{{ "}}" }}'
+        day2.gitops/ocp-version: '{{ "{{" }}ocpVersion{{ "}}" }}'
+        day2.gitops/role: hosted-cluster
     spec:
       project: '{{ .Values.group }}'
       sources:
```

**2b — pass clusterPath and the cluster's own version down:**

```diff
             values: |
               group: '{{ .Values.group }}'
               mce: {{ .Values.mce }}
+              mcePath: {{ .Values.mcePath }}
               cluster: '{{ "{{" }}path.basename{{ "}}" }}'
+              clusterPath: '{{ "{{" }}path{{ "}}" }}'
+              env: {{ .Values.env }}
+              site: {{ .Values.site }}
+              ocpVersion: '{{ "{{" }}ocpVersion{{ "}}" }}'
       destination:
         name: in-cluster
```

Note the two sources: `env` / `site` are **Helm values inherited from the MCE**
(`{{ .Values.* }}`), while `ocpVersion` is the **appset placeholder**
(`{{ocpVersion}}`) read from the *cluster's own* config.yaml — that is what lets
a hosted cluster sit on a different OCP stream than its MCE.

### 3. `clusters/templates/inClusterApp.yaml`

**3a — labels** (`metadata`, static Application — no generator here):

```diff
 metadata:
   name: {{ .Values.group }}-in-cluster
   namespace: gitops-{{ .Values.group }}
+  labels:
+    day2.gitops/team: '{{ .Values.group }}'
+    day2.gitops/env: '{{ .Values.env }}'
+    day2.gitops/site: '{{ .Values.site }}'
+    day2.gitops/mce: '{{ .Values.mce }}'
+    day2.gitops/cluster: in-cluster
+    # The MCE's own OCP version — in-cluster charts resolve version layers by it.
+    day2.gitops/ocp-version: '{{ .Values.ocpVersion }}'
+    day2.gitops/role: mce
 spec:
   project: '{{ .Values.group }}'
   sources:
```

**3b — parametric passthrough:**

```diff
         values: |
           group: '{{ .Values.group }}'
           mce: {{ .Values.mce }}
+          mcePath: {{ .Values.mcePath }}
           cluster: 'in-cluster'
+          clusterPath: {{ .Values.mcePath }}/in-cluster
+          env: {{ .Values.env }}
+          site: {{ .Values.site }}
+          ocpVersion: '{{ .Values.ocpVersion }}'
   destination:
     name: in-cluster
```

`ocpVersion` is passed through **unchanged from the MCE** — deliberately no
override, since in-cluster charts version by the MCE's own OCP version.
`clusterPath` is composed, not generated: there is no config.yaml in
`in-cluster/`.

### 4. `operators/templates/operators.yaml`

**4a — gen-1 becomes parametric.** gen-2 (the in-cluster defaults generator,
just below) is **unchanged in this phase** — it moves in Phase C'.1:

```diff
         directories:
-          - path: "mces/{{ .Values.mce }}/{{ .Values.cluster }}/*"
+          - path: "{{ .Values.clusterPath }}/*"
     {{- if eq .Values.cluster "in-cluster" }}
     - git:
```

While folders are still in the legacy tree, `{{ .Values.clusterPath }}` renders
`mces/<mce>/<cluster>` — byte-identical to the line it replaces.

**4b — labels:**

```diff
   template:
     metadata:
       name: '{{ .Values.group }}-{{ .Values.cluster }}-{{ "{{" }}path.basename{{ "}}" }}'
+      labels:
+        day2.gitops/team: '{{ .Values.group }}'
+        day2.gitops/env: '{{ .Values.env }}'
+        day2.gitops/site: '{{ .Values.site }}'
+        day2.gitops/mce: '{{ .Values.mce }}'
+        day2.gitops/cluster: '{{ .Values.cluster }}'
+        day2.gitops/chart: '{{ "{{" }}path.basename{{ "}}" }}'
+        day2.gitops/ocp-version: '{{ .Values.ocpVersion }}'
+        day2.gitops/role: {{ eq .Values.cluster "in-cluster" | ternary "mce" "hosted-cluster" }}
     spec:
       project: '{{ .Values.group }}'
```

**4c — passthrough + the config stack's new version layer:**

```diff
             values: |
               group: '{{ .Values.group }}'
               mce: {{ .Values.mce }}
+              mcePath: {{ .Values.mcePath }}
               cluster: {{ .Values.cluster }}
+              clusterPath: {{ .Values.clusterPath }}
+              env: {{ .Values.env }}
+              site: {{ .Values.site }}
+              ocpVersion: '{{ .Values.ocpVersion }}'
               operator: {{ "{{" }}path.basename{{ "}}" }}
+            # Deploy-config stack, lowest -> highest: team default, per-OCP-stream
+            # pin (selected by the destination's own ocpVersion), fleet defaults,
+            # the cluster's own folder. All optional (ignoreMissingValueFiles).
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/versions/ocp-{{ .Values.ocpVersion }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- if eq .Values.cluster "in-cluster" }}
               - '$values/mces/in-cluster-defaults/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- end }}
-              - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              - '$values/{{ .Values.clusterPath }}/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
```

### 5. `deploy/templates/deployApp.yaml`

**5a — labels.** Hub apps get team/chart/role only — no env/site/mce/ocp-version
(the prod-hub is version-less and outside the `sites/` tree):

```diff
   name: {{ .Values.group }}-{{ .Values.cluster }}-{{ .Values.operator }}-deploy
   {{- end }}
   namespace: gitops-{{ .Values.group }}
+  labels:
+    day2.gitops/team: '{{ .Values.group }}'
+    day2.gitops/chart: '{{ .Values.operator }}'
+    {{- if .Values.hub }}
+    day2.gitops/role: hub
+    {{- else }}
+    day2.gitops/env: '{{ .Values.env }}'
+    day2.gitops/site: '{{ .Values.site }}'
+    day2.gitops/mce: '{{ .Values.mce }}'
+    day2.gitops/cluster: '{{ .Values.cluster }}'
+    day2.gitops/ocp-version: '{{ .Values.ocpVersion }}'
+    day2.gitops/role: {{ eq .Values.cluster "in-cluster" | ternary "mce" "hosted-cluster" }}
+    {{- end }}
 spec:
   project: '{{ .Values.group }}'
```

**5b — the workload stack splits into a hub branch and a fleet branch.** This is
the largest hunk; replace it as a block rather than line by line:

```diff
         ignoreMissingValueFiles: true
+        # Workload-values stack, lowest -> highest. Every layer is optional.
         valueFiles:
+          {{- if .Values.hub }}
+          - '$values/operators/{{ .Values.operator }}/values.yaml'
+          - '$values/in-cluster/{{ .Values.operator }}/values.yaml'
+          {{- else }}
           - '$values/operators/{{ .Values.operator }}/values.yaml'
-          - '$values/mces/{{ .Values.mce }}/values.yaml'
-          - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/values.yaml'
-          {{- if and (eq .Values.cluster "in-cluster") (not .Values.hub) }}
+          - '$values/operators/{{ .Values.operator }}/versions/ocp-{{ .Values.ocpVersion }}/values.yaml'
+          - '$values/sites/{{ .Values.site }}/values.yaml'
+          - '$values/sites/{{ .Values.site }}/{{ .Values.env }}/values.yaml'
+          {{- if eq .Values.cluster "in-cluster" }}
           - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values.yaml'
           - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
           {{- end }}
-          - '$values/mces/{{ .Values.mce }}/{{ .Values.cluster }}/{{ .Values.operator }}/values.yaml'
-          {{- if .Values.hub }}
-          - '$values/in-cluster/{{ .Values.operator }}/values.yaml'
+          - '$values/{{ .Values.mcePath }}/values.yaml'
+          - '$values/{{ .Values.clusterPath }}/values.yaml'
+          - '$values/{{ .Values.clusterPath }}/{{ .Values.operator }}/values.yaml'
           {{- end }}
```

Three things worth understanding before you paste it:

- The inner `{{- if ... }}` loses its `(not .Values.hub)` guard because it now
  lives inside the `{{- else }}` (non-hub) branch. The trailing `{{- end }}`
  in the context closes that new `if/else`, not the inner one.
- The hub branch drops the junk `$values/mces//...` empty-mce paths
  (spec-only cleanup — they never resolved).
- The `in-cluster-defaults` layers now sit *before* the MCE-wide and
  cluster-wide slots. No behavior change, because **no MCE-wide or
  cluster-wide values.yaml exists anywhere today** — verify in your repos with
  `ls mces/*/values.yaml mces/*/*/values.yaml` → nothing. Everything new
  resolves to nothing until someone creates a file.

Name, releaseName, destination and syncPolicy logic: untouched.

### 6. `mces/templates/inClusterAppset.yaml`

Labels only — six lines. The glob changes come in Phase C'.1:

```diff
   template:
     metadata:
       name: '{{ .Values.group }}-in-cluster-{{ "{{" }}path.basename{{ "}}" }}'
+      labels:
+        day2.gitops/team: '{{ .Values.group }}'
+        day2.gitops/chart: '{{ "{{" }}path.basename{{ "}}" }}'
+        # No env/site/mce/ocp-version labels: the prod-hub is version-less and
+        # outside the sites/ tree.
+        day2.gitops/role: hub
     spec:
       project: '{{ .Values.group }}'
       sources:
```

**Gate:** render harness IDENTITY OK — all existing apps byte-identical in
identity and resolution; only labels + valueFiles-list strings differ.
(Mock result: exactly that, 35/35.)

---

## Phase C — sigs repos: move the trees (per team, per MCE, ONE commit each)

```
git mv mces/<mce> sites/<site>/<env>/mces/<mce>
```

- One MCE per commit; each commit is atomic (never copy-then-delete across
  commits — transient duplicate generator entries are undefined behavior).
- Mixed states are fine: the mock verified one MCE migrated + one legacy with
  zero identity diffs; the two globs serve both layouts and config.yaml
  env/site stay authoritative during the window.
- App names contain no path segments → the appset controller updates every
  app **in place**; the only spec diffs are valueFiles path strings
  (resolution verified identical).

**Gate per commit:** harness IDENTITY OK.

---

## Phase C' — defaults renames + the NEW hosted-clusters layer

Ordering is the inverse of exclude-first — **add the new glob first**; never
remove an old glob while the old folder still exists. Four steps:

### C'.1 — platform: add-first (one MR)

- `mces/templates/inClusterAppset.yaml`: generator scans **both**
  `in-cluster/*` and `defaults/hub/*`; valueFiles gain
  `$values/defaults/hub/<chart>/<chart>.yaml` (config) alongside the old
  path; `deployApp.yaml` hub branch gains
  `$values/defaults/hub/<op>/values.yaml`.
- `operators/templates/operators.yaml`: gen-2 scans **both**
  `mces/in-cluster-defaults/*` and `defaults/mces/*`; config stack gains
  `$values/defaults/mces/<chart>/<chart>.yaml`. **NEW gen-3** (the
  hosted-cluster defaults — the whole point of this phase):

```yaml
{{- else if not .Values.hub }}
- git:
    repoURL: <sigs repo>
    revision: main
    directories:
      - path: "defaults/hosted-clusters/*"
{{- end }}
```

  with its config layer `$values/defaults/hosted-clusters/<chart>/<chart>.yaml`
  in the non-in-cluster branch.
- `deploy/templates/deployApp.yaml`: in-cluster branch gains
  `$values/defaults/mces/<op>/{values,values-<env>,values-<mce>}.yaml`
  (the `values-<env>` slot is new); the hosted-cluster branch gains
  `$values/defaults/hosted-clusters/<op>/{values,values-<env>,values-<cluster>}.yaml`.

Empty/absent folders ⇒ zero new apps, all new paths ignore-missing ⇒ no-op.

### C'.2 — sigs: `git mv in-cluster defaults/hub` (one commit)

Also create `defaults/hosted-clusters/README.md` (copy from mock — plain
files are ignored by generators; the folder must exist in git anyway).

### C'.3 — sigs: `git mv mces/in-cluster-defaults defaults/mces` (one commit)

`dhcp-api-token` moves with it: same basename ⇒ same app names on every MCE
⇒ in-place update; its deploy config resolves from the new path with
identical content. The legacy `mces/` directory is now empty and disappears.

### C'.4 — platform: remove the old globs/paths (one MR)

Remove `in-cluster/*` and `mces/in-cluster-defaults/*` globs and the three
legacy valueFiles paths. Spec-only cleanup.

**Gate per step:** harness IDENTITY OK. (Mock: 35/35 at each of the four.)

---

## Phase D — cleanup (platform first, then sigs)

### D.1 — platform: drop the legacy glob; env/site from path

`mcesAppset.yaml`: remove the `mces/*/config.yaml` files entry; switch
env/site sourcing to path segments — `site: {{ "{{" }}path[1]{{ "}}" }}`,
`env: {{ "{{" }}path[2]{{ "}}" }}` (in both the labels and the values block).
The depth-exact glob makes path positions trustworthy.

**Order matters: this template change merges BEFORE D.2** — removing a
config.yaml field the template still reads would leave literal `{{env}}`
placeholders in rendered specs (fasttemplate keeps unmatched placeholders).

### D.2 — sigs: strip env/site from every MCE config.yaml

End-state schema is `ocpVersion` only, identical at MCE and cluster level.
Refresh the READMEs from the mock: team-repo root README (tree contract,
naming rules, config.yaml contract, precedence tables), `defaults/hub/`,
`defaults/mces/`, `defaults/hosted-clusters/`.

**Gate:** harness IDENTITY OK, and `grep -r "env:" sites/*/*/mces/*/config.yaml`
returns nothing.

---

## Failure modes & controls

| Mistake | Consequence | Control |
|---|---|---|
| Team misses Phase A when B merges | its `<group>-<mce>` apps deleted; workloads orphaned, unmanaged | precondition gate; recovery = add config.yaml — apps recreate and re-adopt (same names) |
| Folder copied, not moved | duplicate app name in one appset — undefined/flapping | one-commit `git mv` rule; harness duplicate check |
| Version unquoted (`4.20` → float `4.2`) | wrong `ocp-<v>` layer resolved, silently | quoting rule; harness lints every config.yaml |
| config.yaml env/site disagrees with path (window only) | humans misread the tree | harness path⇔config assertion |
| Removing an old glob before the folder moved | that folder's apps deleted for a window | add-first ordering (C'), remove only after the move lands |
| "Fixing" the frozen `namespace:` line while in there | fleet-wide app identity change → delete/recreate | explicitly frozen |
| `targetRevision` in a `defaults/*` config | silently overrides every stream pin for that chart | README rule: defaults configs carry repourl/namespace/syncPolicy; pins live in `operators/` |

---

## What was verified in the mock (2026-08-13)

| Check | Result |
|---|---|
| Phase A | zero diff (not even spec) across 35 apps |
| Phase B | 35/35 identities + resolved contents unchanged; diffs = labels + valueFiles strings only; frozen line byte-identical |
| Phase C, per-MCE commits incl. mixed state | 35/35 unchanged |
| Phase C'.1–C'.4, each step | 35/35 unchanged; `defaults/hosted-clusters/` generates zero apps while empty |
| Phase D.1, D.2 | 35/35 unchanged; env/site values identical from path segments |
| Baseline → final end-to-end | IDENTITY OK |
| Dry-run: hosted-cluster upgrade (`ocpVersion` 4.20→4.22) | blast radius = that cluster only; label + version-layer paths flip; zero workload diff for `main`-tracking charts |
| Dry-run: MCE upgrade | MCE's in-cluster charts re-pin; hosted clusters under it untouched |
| Dry-run: stream pin (`versions/ocp-4.20/cluster-roles.yaml` → `2.1.4`) | leaf `targetRevision` flips on the two 4.20 clusters only; 4.16 untouched |

Operational runbooks (upgrade a cluster, upgrade a chart, add a chart, add a
cluster/MCE/site) and the full architecture rationale: **`ARCHITECTURE.md`**.
