# The sites/ refactor — changes to apply in the air-gapped repos

This hand-off migrates the day2 repos to the architecture in
`REFACTOR-PLAN.md` (deep dive: `ARCHITECTURE.md`):

- `sites/<site>/<env>/mces/<mce>/<cluster>/` tree — env and site become path
  identity; fleet queries become greps and label selectors.
- ~~a marker file per MCE/cluster (`mce.yaml` / `hc.yaml`, see §0) carrying
  **`ocpVersion`**~~ — **superseded by Phase E**: the version is read from the
  day1 repo's `mastertag`, the sigs repos declare no version at all, and the
  marker files are deleted. Discovery is by folder existence. An upgrade is one
  edit in day1 for the whole fleet, never a folder move.
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
team whose repo you are verifying, and from Phase E on it also needs a day1
checkout: `--day1 ROOT`, defaulting to `../gitops-day1/platform-config`)
simulates the documented generator params
and asserts, per phase, that all 35 generated apps keep identical names, destinations,
releaseNames, syncPolicies and identical *resolved value-file content
sequences*. Re-run it against your repos at every phase gate; re-verify
against live Argo behavior on the first phase you apply.

---

## §0 — ERRATA (2026-08-17): the marker file is `mce.yaml` / `hc.yaml`

**If you have already applied Phase B, read this section before doing
anything else — then read "Air-gap continuation" below, which trims this
section's fix to steps 1–2 and folds step 3 into Phase E.** The original
hand-off used one filename, `config.yaml`, at
both MCE and hosted-cluster depth. That is wrong and it fails in production.
Everything below in this document has been corrected to the two names; this
section explains the failure and how to get from the shipped state to the
corrected one without an outage.

### 0.1 What it looks like

Argo on prod-hub reports, once per hosted cluster:

> `there are no clusters with this name: <hosted-cluster-name>`

and `gitops-<group>` on prod-hub carries one extra Application per hosted
cluster, named `<group>-<hosted-cluster>`. The fingerprint is an **MCE-layer
app whose destination is a hosted cluster**:

```console
$ kubectl get application <group>-<hosted-cluster> -n gitops-<group> \
    -o jsonpath='{.spec.destination.name}{"  src="}{.spec.source.path}{"\n"}'
<hosted-cluster>  src=clusters      # destination should be an MCE; src=clusters means
                                    # this was emitted by mcesAppset, not clustersAppset
```

### 0.2 Why — a `files:` glob is not depth-exact

Phase B switched MCE and hosted-cluster discovery from a `directories:`
generator to a `files:` generator. **The two are matched by different
engines**, and only one of them stops at `/`:

| Generator | Matched by | Does `*` cross `/`? |
|---|---|---|
| `directories:` | Go `path.Match`, in the appset controller | **No** — exactly one path segment |
| `files:` | `git ls-files -- <pattern>` on the repo-server | **Yes** — matches at any depth |

A `files:` path is a **git pathspec**, and git matches pathspecs with
wildmatch *without* `WM_PATHNAME`, so `*` eats slashes. `mces/*/config.yaml`
therefore does not mean "a config.yaml one level under `mces/`" — it means
"any config.yaml at any depth under `mces/`", which is every hosted cluster
as well. Each extra hit renders an MCE-layer Application with
`destination.name: {{path.basename}}` = a hosted-cluster name, which prod-hub
cannot resolve.

Check any team repo yourself, with the same command the repo-server runs —
and note that **your shell disagrees with git here**, which is exactly why
this was missed:

```console
$ ls mces/*/config.yaml            # shell globs stop at '/' — looks correct
mces/ocp4-prod-mce-site1-a/config.yaml

$ git ls-files -- 'mces/*/config.yaml'                 # what Argo actually sees
mces/ocp4-prod-mce-site1-a/config.yaml                       # intended
mces/ocp4-prod-mce-site1-a/ocp4-prod-herzi-site1/config.yaml # phantom MCE
mces/ocp4-prod-mce-site1-a/ocp4-prod-karniol-site1/config.yaml
```

**Phase D does not fix this.** `sites/*/*/mces/*/config.yaml` over-matches
identically — same command, same result, one level deeper. Worse, `{{path[1]}}`
and `{{path[2]}}` shift by one segment on the over-matched hits, so the Phase D
env/site labels would be wrong on them too.

### 0.3 Blast radius — do not roll back

- **Real MCE apps are correct.** The glob over-matches; it never misses.
- **The phantoms never synced.** They fail at destination resolution, so
  nothing was deployed anywhere it shouldn't be, and there is nothing to
  clean up on any cluster.
- **They delete themselves** once the glob stops matching them (0.4).
- **The one genuine hazard:** a phantom is harmless only because its
  destination fails to resolve. A marker file dropped into an `in-cluster/`
  folder resolves to `in-cluster` — a real cluster — and prod-hub would then
  sync the `clusters` chart against itself with a hosted-cluster path. Treat
  "never a marker file in `in-cluster/` or a chart folder" as a hard rule,
  not a tidiness preference.

### 0.4 The fix, and the order to apply it

Depth cannot be expressed in a `files:` glob, so it is expressed in the
**filename**: `mce.yaml` in MCE folders, `hc.yaml` in hosted-cluster folders.
Neither name exists at any other depth, so neither glob can over-match no
matter how `*` behaves. Same schema, same keys — only the name changes.

> Rejected alternative: `applicationsetcontroller.enable.new.git.file.globbing:
> "true"` makes `files:` globs depth-exact and would need no repo changes. It
> defaults to off, and `clustersAppset` runs on **every MCE's** Argo — the
> whole fleet, including every future MCE, would have to carry the flag
> forever or silently regress to phantoms. Unique filenames need no
> cluster-side configuration.

**This is add-before-remove — the ONE INVARIANT applies.** Never rename the
marker in the sigs repo before the platform globs point at the new name: for
the window in between, the live glob would match nothing and every
`<group>-<mce>` app would be deleted (workloads orphaned).

**Step 1 — sigs repos, one commit per team: add the new markers *alongside*
the old ones.** `cp`, not `git mv`. Nothing globs the new names yet, so this
has zero effect. In the legacy layout (`sites/` not yet applied — shell globs
are depth-exact, so these are safe as written):

```console
for f in mces/*/config.yaml;   do cp "$f" "$(dirname "$f")/mce.yaml"; done
for f in mces/*/*/config.yaml; do cp "$f" "$(dirname "$f")/hc.yaml";  done
git add -A && git commit -m "add mce.yaml/hc.yaml markers alongside config.yaml"
```

For a repo already moved to `sites/` (post-Phase-C), the same two lines with
`sites/*/*/mces/*` and `sites/*/*/mces/*/*`. Keep the content byte-identical,
`env`/`site` fields included — the whole point is that nothing about the
generated apps changes.

> **The harness gate is red at this step, and that is correct.** With the new
> harness and the platform still on `config.yaml`, `render_chain.py` reports
> `DEPTH-AMBIGUOUS files: glob` and exits non-zero — it is detecting the live
> bug, not a mistake in your step 1. Expect it until step 2 merges; the
> standing "require IDENTITY OK before merging" gate applies from step 2 on.

**Step 2 — platform repo, ONE MR: point every `files:` glob at the new
names.** Two files, and both globs in `mcesAppset.yaml`:

```diff
  # mces/templates/mcesAppset.yaml
         files:
-          - path: "mces/*/config.yaml"
-          - path: "sites/*/*/mces/*/config.yaml"
+          - path: "mces/*/mce.yaml"
+          - path: "sites/*/*/mces/*/mce.yaml"

  # clusters/templates/clustersAppset.yaml
         files:
-          - path: "{{ .Values.mcePath }}/*/config.yaml"
+          - path: "{{ .Values.mcePath }}/*/hc.yaml"
```

Because the marker contents are identical, every real app keeps its name,
destination, params and value-file resolution — the only change is that the
phantoms stop being generated and the appset controller removes them.
**Gate:** harness IDENTITY OK, and `git ls-files -- '<each new glob>'` in a
team repo returns *only* the intended depth.

**Step 3 — sigs repos, one commit per team: delete the old markers.** Only
after step 2 has merged and the phantoms are gone.

```console
find . -name config.yaml -path '*mces/*' -delete   # or: git rm mces/*/config.yaml mces/*/*/config.yaml
```

**Verify** on prod-hub — the phantom apps are gone and every remaining
MCE-layer app targets an MCE:

```console
kubectl get applications -n gitops-<group> \
  -l day2.gitops/role=mce -o custom-columns=NAME:.metadata.name,DEST:.spec.destination.name
```

If any phantom Application survives (an appset configured with
`preserveResourcesOnDeletion`, or one that was adopted manually), delete the
Application CR directly — non-cascading, since it never synced anything.

**Where this leaves you:** step 3 completes a corrected Phase B. Resume the
main path at Phase C below, which is written against the corrected marker
names and needs no further adjustment.

### 0.5 Standing rule

> **Never use one marker filename at two depths, and never assume a `files:`
> glob is anchored.** Before merging any change to a `files:` generator, run
> `git ls-files -- '<the glob>'` in a real team repo and read the whole
> output. `render_chain.py` now models both engines and fails the pre-merge
> gate on any `files:` glob whose git-pathspec matches differ from its
> depth-exact matches, so this cannot reach an MR again.

---

## Air-gap continuation (2026-08-17) — you are after Phase B

**Read this if the air-gapped repos have Phase A and Phase B applied under the
original `config.yaml` marker name and the §0 rename never ran.** That is the
current air-gap state, and it means two things at once: the phantom MCE
Applications of §0.1 are live in your fleet right now, and the rest of this
document (C, C', D) is written against marker names you do not have.

**Phase E supersedes most of what is left.** It takes the OCP version out of
the sigs repos entirely — it comes from the day1 repo's `mastertag` — which
leaves the marker files with nothing to carry, so they are deleted and
discovery goes back to depth-exact `directories:` generators. The §0 rename and
all of Phase D become work you would throw away.

**The remaining sequence is `§0 (steps 1–2 only) → C → C' → E`. Phase D is
skipped.**

| Phase | Status for the air-gap | Why |
|---|---|---|
| §0 steps 1–2 | **do, trimmed** (below) | closes the live phantom window; the new markers are throwaway, the window is not |
| §0 step 3 (delete `config.yaml`) | **fold into E.3** | E.3 deletes every marker anyway — one pass over the sigs repos instead of two |
| Phase C (trees → `sites/`) | **required, unchanged** | E builds the day1 lookup from `path[1]` = site; the legacy `mces/<mce>/` layout has no site segment, and the harness now refuses that layout outright |
| Phase C' (defaults renames + hosted-clusters layer) | **required, unchanged** | independent of the version change |
| Phase D (drop legacy glob; env/site from path; strip marker fields) | **skip — subsumed by E** | E.2 replaces the generator wholesale with one `sites/` `directories:` entry, env/site already from `path[1]`/`path[2]`; E.3 deletes the markers instead of editing their fields; D.2's README refresh is E.4 |
| Phase E | **the new end state** | versions from day1, markers deleted |

### Optional: the delete guard rail

Phase C moves every team's tree one commit per MCE, and all platform-layer apps
run `selfHeal: true` — there is no post-merge inspection window. The safety model
already covers the *automated* failure modes: no Application carries a
`resources-finalizer`, so a dropped generator entry orphans workloads instead of
deleting them, and every platform appset is `prune: false`. What it does not
cover is a **human** cascade-deleting an app from the UI or CLI while the tree is
churning, and the single chart that opts into `prune: true` for itself
(`defaults/mces/dhcp-api-token`).

`tools/migration-guardrail/` closes that gap: a ClusterRole under which Argo can
delete `Application` and `ApplicationSet` CRs and nothing else. Apps and appsets
stay freely recreatable — which is exactly what C, C' and E do to them — while
the workloads underneath cannot be torn down.

- **Optional.** Skip it and the orphaning model above still holds. You are
  choosing whether to also guard against operator error.
- **On before the first Phase C `git mv` merges, off after E is verified.** It is
  a migration-window posture, not a permanent one.
- **It is not one cluster.** Applying it only to prod-hub's local ServiceAccount
  protects almost nothing: `mcesAppset` targets the MCE by name while
  `clustersAppset`/`operators.yaml` target `in-cluster` and `deployApp` targets
  the hosted cluster, so deletes flow through four separate identities. The role
  has to land on every MCE and on the credentials Argo uses to reach hosted
  clusters too. `tools/migration-guardrail/discover.sh` works out which objects
  those are on your fleet.
- **Known cost while it is on:** manual syncs of charts that ship RBAC
  (`operators/{cluster-roles,kyverno,bmhgen}`) fail by design — Kubernetes will
  not let Argo create a Role granting `delete` when Argo no longer holds it.
  All three are manual-sync, so nothing breaks on its own; just do not sync them
  during the window. There is a documented break-glass if you must.

Read `tools/migration-guardrail/README.md` before applying any of it. The
preconditions there are real — without OpenShift GitOps >= 1.11 the operator
reconciles its default role back and the guard rail silently does nothing.

### The §0 trim

Apply §0.4 **step 1** (add `mce.yaml`/`hc.yaml` alongside `config.yaml`) and
**step 2** (the platform MR pointing both globs at the new names) exactly as
written — in the legacy layout, since Phase C has not run yet. Then **stop**.
Do not run step 3: leave `config.yaml` in place, nothing globs it once step 2
merges, and E.3 removes both names in one commit per team.

Why bother, when E deletes these markers anyway: C and C' are per-team,
per-MCE tree moves and will take a while. §0.3 rates the phantoms harmless —
they never synced and nothing needs cleaning up — with **one genuine hazard**,
a marker file that lands in an `in-cluster/` or chart folder, where the
destination resolves to a real cluster instead of failing. Running the whole
tree-move migration with a live over-matching glob is how that hazard gets
created by accident.

**If you would rather skip §0 entirely** and go straight to C → C' → E,
that is defensible only after confirming the hazard is not already present,
in every team repo:

```console
$ git ls-files -- 'mces/*/config.yaml'      # what mcesAppset actually matches
```

Every hit must be at MCE depth (`mces/<mce>/config.yaml`) or hosted-cluster
depth (`mces/<mce>/<hc>/config.yaml`). A hit under `in-cluster/` or a chart
folder is the hazard — fix that before anything else. Re-run the check after
every commit of Phase C, because the glob keeps over-matching until E.2 lands.

### Do not try to shortcut C by going straight to E

E's generator is `sites/*/*/mces/*` and its day1 path is built from
`path[1]`/`path[2]`. There is no legacy-layout form of it: `mces/<mce>/` has no
site segment to read, so no day1 file can be located from it. `render_chain.py`
fails the gate on sight of a legacy marker for exactly this reason. Phase C is
a hard precondition for Phase E.

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

## Phase A — sigs repos: add the marker files (additive, zero effect)

> **Partly superseded by Phase E.** The marker files are deleted in E.3 and the
> version inventory below is no longer kept in the sigs repos at all — day1's
> `mastertag` is the source. If you have not applied Phase A yet, you still
> need it (Phase B's generators read the markers until E.2 lands); what you no
> longer need to get *right* is `ocpVersion`, since E stops reading it. The
> inventory is still worth doing once, as the E.0 parity check against day1.

**Per team repo.** First, inventory the fleet: collect the real OCP version of
every MCE and every hosted cluster. The value is load-bearing, not
decorative — it selects the `operators/<chart>/versions/ocp-<v>/` layers once
Phase B lands. Then add:

`mces/<mce>/mce.yaml` (every MCE):

```yaml
env: prod            # this MCE's env: prod | prep | test   ┐ needed only until
site: five           # this MCE's site                      ┘ Phase D
ocpVersion: "4.20"   # the MCE's OWN OCP version. ALWAYS quote — 4.20 unquoted is the float 4.2
```

`mces/<mce>/<cluster>/hc.yaml` (every hosted cluster):

```yaml
ocpVersion: "4.20"   # the cluster's OWN version. NEVER env/site here — inherited from the MCE
```

Do **not** create either marker in `mces/in-cluster-defaults/` or in any
`in-cluster/` or chart folder — presence of the file is what will make a
folder an MCE/cluster, and an `in-cluster/` marker resolves to a *real*
destination (§0.3). Do **not** use one name at both depths (§0).

Plain files are invisible to the current directory generators — this phase
changes nothing anywhere (mock: verified zero diff, not even a spec change).

---

## Phase B — platform repo: ONE MR (generators + parametric paths + labels)

> ⚠️ **HARD PRECONDITION: every team repo has completed Phase A before this
> merges.** A team without marker files at switch time gets its
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
+        # An MCE is a folder holding an mce.yaml (env, site, ocpVersion).
+        # Folders without one (in-cluster-defaults, docs, ...) are invisible —
+        # this replaces the old in-cluster-defaults exclude. The two globs
+        # serve the legacy layout and the sites/ tree during the migration
+        # window; the legacy one is removed in Phase D.
+        #
+        # '*' CROSSES '/' here (git pathspec — §0): what keeps this off the
+        # hosted clusters is that their marker is named hc.yaml, not the glob.
+        files:
+          - path: "mces/*/mce.yaml"
+          - path: "sites/*/*/mces/*/mce.yaml"
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
legacy `mces/*/mce.yaml` here instead of in Phase D deletes the apps of
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

`{{path.basename}}` of the directory containing `mce.yaml` equals the old
directory-generator basename, so **generated app names and destinations are
unchanged**. `env` / `site` / `ocpVersion` are appset placeholders resolved
from the marker's fields (Phase D switches env/site to path segments).

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
+        # A hosted cluster is a folder holding an hc.yaml (ocpVersion only;
+        # env/site are inherited from the MCE). in-cluster/ and chart folders
+        # have no hc.yaml and are invisible — this replaces the old
+        # in-cluster exclude. The MCE's own marker is mce.yaml, so this glob
+        # cannot climb back up to it (§0).
+        files:
+          - path: "{{ .Values.mcePath }}/*/hc.yaml"
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
(`{{ocpVersion}}`) read from the *cluster's own* `hc.yaml` — that is what lets
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
`clusterPath` is composed, not generated: there is no marker file in
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
  zero identity diffs; the two globs serve both layouts and the marker files
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

> **Superseded by Phase E — skip this phase.** E.2 replaces the generator
> wholesale (one `sites/` `directories:` entry, env/site already from
> `path[1]`/`path[2]`, no legacy glob left to drop), and E.3 deletes the marker
> files instead of editing their fields. D.2's README refresh is E.4. Kept here
> for repos that applied D before E existed.

### D.1 — platform: drop the legacy glob; env/site from path

`mcesAppset.yaml`: remove the `mces/*/mce.yaml` files entry; switch
env/site sourcing to path segments — `site: {{ "{{" }}path[1]{{ "}}" }}`,
`env: {{ "{{" }}path[2]{{ "}}" }}` (in both the labels and the values block).
The depth-exact glob makes path positions trustworthy.

**Order matters: this template change merges BEFORE D.2** — removing a
marker field the template still reads would leave literal `{{env}}`
placeholders in rendered specs (fasttemplate keeps unmatched placeholders).

### D.2 — sigs: strip env/site from every MCE marker file

End-state schema is `ocpVersion` only, identical at MCE and cluster level.
Refresh the READMEs from the mock: team-repo root README (tree contract,
naming rules, marker-file contract, precedence tables), `defaults/hub/`,
`defaults/mces/`, `defaults/hosted-clusters/`.

**Gate:** harness IDENTITY OK, and `grep -r "env:" sites/*/*/mces/*/mce.yaml`
returns nothing.

---

## Phase E — versions from day1, markers deleted (2026-08-17)

The air-gap runs **5 sig repos**. Every one of them declared `ocpVersion` for
the same physical clusters, so one cluster upgrade was five identical edits in
five repos, each able to drift from the others. The day1 repo
(`gitops-day1/platform-config`) provisioned those clusters and already records
their exact version as `mastertag`. Phase E makes that the single source: the
sigs repos declare no version at all, and an upgrade is **one edit in day1 for
the whole fleet**.

With `ocpVersion` gone, `mce.yaml`/`hc.yaml` have nothing left to carry — they
existed only to hold that key as generator data. So they are deleted, and
discovery goes back to `directories:` generators. That is a **safety upgrade,
not a regression**: `directories:` is matched by Go `path.Match` where `*` stops
at `/`, so depth-exactness comes from the engine instead of from a marker-naming
convention. The §0 hazard cannot recur — there is no `files:` glob left in the
discovery path.

**Where the version enters and where it is derived**

| Layer | How it gets `mastertag` | Day1 file |
|---|---|---|
| per-MCE app (mcesAppset) | `$day1` valueFile on the clusters-chart source | `sites/<site>/mces/<mce>/values.yaml` |
| per-hosted-cluster app (clustersAppset) | `$day1` valueFile on the operators-chart source | `sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml` |
| MCE in-cluster (`inClusterApp`) | passed inline from the clusters chart | — (the MCE's, above) |

**Mind the path mapping: the day1 tree has no `<env>` level.** day2
`sites/<site>/<env>/mces/<mce>` maps to day1 `sites/<site>/mces/<mce>` — env
lives only inside the resource name. A hosted cluster's day1 filename is its
day2 folder name plus `.yaml`.

Derivation happens in exactly two templates: strip the arch at the first `-`
and use the rest **verbatim** — `4.16.27-x86_64` → `ocpVersion: 4.16.27`. It is
the full patch version, not the stream, so `versions/ocp-<v>/` layers are now
per-exact-version (see the failure table: this sharpens the layer-before-flip
rule to *every* upgrade, z-streams included).

### E.0 — preconditions (verify all four before E.2)

1. **Phases C and C' are complete** in every team repo. Phase C is a hard
   precondition (see the continuation section above). Phase D is skipped.
2. **Day1 parity.** Every MCE and hosted-cluster folder in every sigs repo has
   a day1 file at the mapped path carrying a `mastertag` of the form
   `<major>.<minor>.<patch>[-<arch>]`, and that version agrees with what the
   cluster is actually running. `render_chain.py` proves the parity offline —
   it fails per folder with the exact day1 path it expected.
3. **Argo can read the day1 repo.** A credential for
   `gitops-day1/platform-config` must exist on **prod-hub's Argo and on every
   MCE's Argo** — the per-hosted-cluster apps resolve `$day1` on the MCE's
   repo-server, not on prod-hub. Also confirm the AppProject `<group>` permits
   that repoURL in `sourceRepos`; it is rendered from the separate
   `helm-charts/argo-appproject` repo, so a restrictive list needs a
   coordinated MR **first**.
4. **Key-collision audit of the real day1 files.** Only the keys named in each
   template's inline `values:` block are precedence-protected (Argo applies
   `helm.values` after `valueFiles`). Any *other* top-level key in a day1 file
   silently becomes a chart value. Grep every day1 `values.yaml` and
   `hostedClusters/*.yaml` for the platform's vocabulary:

```console
$ grep -rnE '^(group|mce|mcePath|cluster|clusterPath|env|site|hub|operator):' sites/
```

   Any hit needs handling before E.2. The dangerous one is `hub:` — a truthy
   value flips the `{{- else if not .Values.hub }}` branch in
   `operators.yaml` and silently drops the `defaults/hosted-clusters` generator
   for that cluster. (In the mock, day1 files carry only `dhcp_values` and
   `mastertag`, both inert.)

### E.1 — day1 repo: nothing to change, only to confirm

Phase E reads day1; it never writes to it. If precondition 2 turns up a cluster
day1 does not know about, add its file there **before** E.2 — after E.2 a
missing day1 entry is a hard render failure for that cluster's apps.

### E.2 — platform repo: ONE MR (4 files)

**`mces/templates/mcesAppset.yaml`** — folder discovery, day1 source, and the
label that can no longer be populated:

```diff
-        # An MCE is a folder holding an mce.yaml (ocpVersion). Folders without
-        # one are invisible to this generator. [...]
-        files:
-          - path: "sites/*/*/mces/*/mce.yaml"
+        directories:
+          - path: "sites/*/*/mces/*"
   template:
     [...]
         day2.gitops/mce: '{{ "{{" }}path.basename{{ "}}" }}'
-        day2.gitops/ocp-version: '{{ "{{" }}ocpVersion{{ "}}" }}'
         day2.gitops/role: mce
     spec:
       project: '{{ .Values.group }}'
-      source:
-        repoURL: '[...]/argocd-day2-platform.git'
-        targetRevision: main
-        path: clusters
-        helm:
-          ignoreMissingValueFiles: true
-          values: |
-            [...]
-            ocpVersion: '{{ "{{" }}ocpVersion{{ "}}" }}'
+      sources:
+        - repoURL: '[...]/argocd-day2-platform.git'
+          targetRevision: main
+          path: clusters
+          helm:
+            ignoreMissingValueFiles: true
+            valueFiles:
+              - '$day1/sites/{{ "{{" }}path[1]{{ "}}" }}/mces/{{ "{{" }}path.basename{{ "}}" }}/values.yaml'
+            values: |
+              [...]                       # unchanged, minus ocpVersion
+        - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day1/platform-config.git'
+          targetRevision: main
+          ref: day1
```

`source:` becomes `sources:` with the chart source **first** — the platform
recursion and the harness both key off `sources[0]`. The frozen
`namespace: gitops-{{ .Values.repository }}` line is untouched, as always.

**`clusters/templates/clustersAppset.yaml`** — the same shape, plus the
in-cluster exclude that the marker filename used to provide implicitly:

```diff
-        files:
-          - path: "{{ .Values.mcePath }}/*/hc.yaml"
+        directories:
+          - path: "{{ .Values.mcePath }}/*"
+          - path: "{{ .Values.mcePath }}/in-cluster"
+            exclude: true
     [...]
-        day2.gitops/ocp-version: '{{ "{{" }}ocpVersion{{ "}}" }}'
     [...]
+            valueFiles:
+              - '$day1/sites/{{ .Values.site }}/mces/{{ .Values.mce }}/hostedClusters/{{ "{{" }}path.basename{{ "}}" }}.yaml'
             values: |
-              [...]
-              ocpVersion: '{{ "{{" }}ocpVersion{{ "}}" }}'
+              [...]                       # unchanged, minus ocpVersion
+        - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day1/platform-config.git'
+          targetRevision: main
+          ref: day1
```

**`clusters/templates/inClusterApp.yaml`** — derive, label, and hand the raw
tag down:

```diff
+{{- $mastertag := required "mastertag missing: no day1 platform-config file at sites/<site>/mces/<mce>/values.yaml, or it lacks the key" .Values.mastertag | toString -}}
+{{- $ocpVersion := $mastertag | splitList "-" | first -}}
 apiVersion: argoproj.io/v1alpha1
     [...]
-    day2.gitops/ocp-version: '{{ .Values.ocpVersion }}'
+    day2.gitops/ocp-version: '{{ $ocpVersion }}'
     [...]
-          ocpVersion: '{{ .Values.ocpVersion }}'
+          mastertag: '{{ $mastertag }}'
```

**`operators/templates/operators.yaml`** — the same two derivation lines at the
top (message: `no day1 platform-config entry for this destination`), then
`.Values.ocpVersion` → `$ocpVersion` in all three places: the label, the inline
value passed to the deploy chart, and the `versions/ocp-<v>/` valueFile path.

`deploy/templates/deployApp.yaml` needs **no change** — it consumes
`.Values.ocpVersion`, which now arrives carrying the full version.

`required` is deliberate: with `ignoreMissingValueFiles: true`, a missing day1
file would otherwise render an empty version and silently resolve the wrong
(team-default) layer. A loud render failure leaves the existing children in
place — nothing is deleted.

**Expect a transient during rollout.** Every layer tracks `main` with
`selfHeal`, so a chart can sync the new revision before its parent has stamped
the new app spec, surfacing `mastertag missing` render errors for a few
minutes until the appset controller reconciles top-down. Self-resolving.

> **STAGE GATE — do not start E.3 until this passes.** On live Argo, confirm
> the app set is name-identical to before the MR: same count, nothing added,
> nothing removed. This is the one step that changes how clusters are
> *discovered*; while the markers still exist, rollback is a plain revert.
>
> ```console
> kubectl get applications -A -l day2.gitops/team=<group> --no-headers | wc -l
> kubectl get applications -n gitops-<group> -l day2.gitops/role=mce \
>   -o custom-columns=NAME:.metadata.name,DEST:.spec.destination.name
> ```

### E.3 — sigs repos: delete every marker (one commit per team)

Only after the E.2 gate. The markers are inert the moment E.2 is live — nothing
globs them — so this is pure cleanup, and it is also where the deferred §0
step 3 lands:

```console
find . \( -name mce.yaml -o -name hc.yaml -o -name config.yaml \) -path '*mces/*' -delete
git add -A && git commit -m "markers deleted: folder presence is the opt-in, version comes from day1"
```

**Check `git status` before committing: only deletions.** Every folder that
held a marker must still contain other tracked content (`in-cluster/`, a
hosted-cluster folder, a chart folder). If deleting the marker would empty a
folder, add a `.gitkeep` in the same commit — git cannot track an empty
directory, and the folder disappearing is the cluster disappearing.

### E.4 — docs

Refresh from the mock: `ARCHITECTURE.md` (discovery contract, version
management, labels, runbooks R1/R2/R6/R7/R9, invariants checklist), the
team-repo root README, and `defaults/mces/README.md`. Copy the updated
`render_chain.py` across — it takes a new `--day1 ROOT` (default
`../gitops-day1/platform-config`) and still hardcodes `GROUP`.

---

## Failure modes & controls

| Mistake | Consequence | Control |
|---|---|---|
| Team misses Phase A when B merges | its `<group>-<mce>` apps deleted; workloads orphaned, unmanaged | precondition gate; recovery = add the marker file — apps recreate and re-adopt (same names) |
| Folder copied, not moved | duplicate app name in one appset — undefined/flapping | one-commit `git mv` rule; harness duplicate check |
| Version unquoted (`4.20` → float `4.2`) | wrong `ocp-<v>` layer resolved, silently | *pre-E only.* After E nothing in sigs declares a version; the day1 `mastertag` is arch-suffixed so it cannot parse as a float, and the harness lints its format |
| marker env/site disagrees with path (window only) | humans misread the tree | *pre-E only* — harness path⇔config assertion; after E there is no marker to disagree |
| One marker filename reused at two depths | every hosted cluster becomes a phantom MCE; `no clusters with this name` (§0) | distinct `mce.yaml`/`hc.yaml`; harness fails any depth-ambiguous `files:` glob. **Phase E retires the whole class** — `directories:` is depth-exact in the engine |
| **(E)** day1 has no file for a cluster folder | that cluster's apps fail to render — loudly, nothing deleted | E.0 precondition 2; harness parity lint names the exact expected day1 path; `required` in the templates |
| **(E)** stray non-cluster folder under an MCE | becomes a phantom hosted-cluster Application | harness parity lint fails it (a stray folder has no day1 file) before merge |
| **(E)** marker deleted from a folder with no other content | the folder vanishes from git ⇒ the cluster vanishes from the fleet | E.3 rule: `.gitkeep` in the same commit; `git status` must show only deletions |
| **(E)** day1 file carries a platform key (`hub:`, `env:`, `site:`…) | silently becomes a chart value; a truthy `hub:` drops the `defaults/hosted-clusters` generator for that cluster | E.0 precondition 4 grep, before the platform MR |
| **(E)** day1 tag bumped before the `versions/ocp-<new>/` layer exists | pinned charts silently fall back to the team default | layers are per-**exact** version now: create the layer, then flip the tag (R1/R2) |
| Removing an old glob before the folder moved | that folder's apps deleted for a window | add-first ordering (C'), remove only after the move lands |
| Human cascade-deletes an app while the tree is churning | that app's workloads torn down — the one deletion path the no-finalizer model does not cover | optional delete guard rail (`tools/migration-guardrail/`), on before C and off after E |
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

### Phase E, verified in the mock (2026-08-17)

Both snapshots taken with the updated harness; day1 mock brought to parity
first (its `mastertag` streams match what the markers declared, so the change
is provably version-neutral).

| Check | Result |
|---|---|
| Phase E end-to-end (generator swap + day1 sourcing + marker deletion) | **35 → 35 apps, `IDENTITY OK`, exit 0, zero HARD failures, no apps added or removed** |
| Diffs, per the compare contract | INFO only: the 6 discovery apps (2 MCE + 4 hosted-cluster) gained the `ref: day1` source and its resolved file, lost the `ocp-version` label, changed their valueFiles list; 26 apps' `ocp-version` label went `4.16`→`4.16.27` / `4.20`→`4.20.9`; version slots became `versions/ocp-4.16.27` / `ocp-4.20.9` |
| Resolved **sigs** value-file content sequences | byte-identical on all 35 — no workload renders differently |
| Negative: day1 file removed | parity lint names the expected path **and** the `required` render error is reported as a CHECK FAILURE, not a traceback |
| Negative: day1 tag drifts from a still-present marker | lint fails with both values (migration-window guard) |
| Negative: stray folder under an MCE | parity lint fails it and says it would become a phantom app |

Operational runbooks (upgrade a cluster, upgrade a chart, add a chart, add a
cluster/MCE/site) and the full architecture rationale: **`ARCHITECTURE.md`**.
