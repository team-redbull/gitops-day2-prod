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
- `mces/in-cluster-defaults/` may or may not exist per team (see below).

> **The collapsed variant is a FLEET-WIDE option, not a per-repo one.** The
> platform repo is shared by every team, so shipping `inClusterAppset.yaml`
> straight in its C'.4 form is only valid if **no** team repo still has a
> top-level `in-cluster/`. If even one does, take the normal C'.1 → C'.2 →
> C'.4 dual-glob path; the repos that never had the folder simply satisfy
> C'.2 vacuously.

### Not every team repo has `in-cluster/` and `mces/in-cluster-defaults/`

Confirmed in the air-gapped fleet (2026-08-20): **only some** sigs repos carry
these two folders. That is fine — a team with neither is a *supported* state,
not a repo to fix. Nothing in the generated-app flow depends on their
existence:

- A `directories:` glob that matches nothing yields **zero generator params**
  (C'.1) — no app, no error, no degraded state. That applies to
  `in-cluster/*`, `defaults/hub/*`, `mces/in-cluster-defaults/*`,
  `defaults/mces/*` and `defaults/hosted-clusters/*` alike.
- Every `defaults/…` valueFile slot added in C'.1 sits under
  `ignoreMissingValueFiles: true` in all three templates, so an absent folder
  resolves to nothing.
- The XOR invariant of C'.2/C'.3 ("exactly one of the two folders exists") is
  satisfied vacuously when **neither** exists: both globs match nothing, so
  there is no app to duplicate and none to orphan.
- Phase B's deletion of the `mces/in-cluster-defaults` **exclude** entry is
  dead-code removal in a repo that never had the folder.
- Same for the *per-MCE* `mces/<mce>/in-cluster/` folder, if that is the one
  your repo is missing: `operators.yaml` gen-1 (`{{ .Values.clusterPath }}/*`)
  yields zero apps, gen-2 (`defaults/mces/*`) is a **separate generator in the
  same list** and still fires, the static `<group>-in-cluster` Application
  renders as always, and `clustersAppset`'s `exclude:` of a folder that is not
  there is a no-op. No step changes for it.

What DOES change for such a repo is three mechanical instructions — a bare
`git mv` of a folder that is not there fails with `fatal: bad source`. The
adjusted commands are inline at **C'.2** and **C'.3**; read them before
running either step. Everything else (Phases A, B, C, C'.1, C'.4, D, E) is
byte-for-byte the same.

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
remove an old glob while the old folder still exists. Four steps, in this
order, each its own MR/commit:

| Step | Repo | What |
|---|---|---|
| C'.1 | platform | 3 templates learn the `defaults/` layout **alongside** the old paths; NEW hosted-cluster defaults generator |
| C'.2 | sigs | `git mv in-cluster defaults/hub` + create `defaults/hosted-clusters/` |
| C'.3 | sigs | `git mv mces/in-cluster-defaults defaults/mces` |
| C'.4 | platform | remove the now-dead old globs and paths |

The **XOR invariant** for C'.2/C'.3: at every commit exactly one of the two
folders exists. That is why each move is a single `git mv` commit — a
copy-then-delete pair would put both folders in the tree at once, and both
globs are live during the window, so every chart in there would generate two
apps with the same name.

### C'.1 — platform: add-first (one MR)

> **`defaults/` does not exist in any sigs repo yet, and that is correct — do
> not create it here.** This step points globs at folders that arrive in C'.2
> and C'.3. A git `directories:` glob that matches nothing yields **zero
> generator params**; it is not an error and not a degraded state. The old
> `in-cluster/*` and `mces/in-cluster-defaults/*` globs are still in the same
> `directories:` lists — multiple paths there are a **union** — so every
> existing app keeps generating from the old location, untouched.
>
> Doing it the other way round is the outage: move the folder first and the
> live glob matches nothing for the length of the window, which deletes every
> `<group>-in-cluster-<chart>` app and orphans its workloads. Add the glob,
> *then* move the folder. (Verified in the mock: at the C'.1 commit the sigs
> tree still had only `in-cluster/`, `mces/`, `operators/`, `sites/` — and the
> render gate was 35/35 unchanged.)

Three templates. `mcesAppset.yaml`, `clustersAppset.yaml` and
`inClusterApp.yaml` are **untouched** in this step.

| # | File | What changes |
|---|---|---|
| 1 | `mces/templates/inClusterAppset.yaml` | generator scans `defaults/hub/*` too; config stack gains the `defaults/hub` layer |
| 2 | `operators/templates/operators.yaml` | gen-2 scans `defaults/mces/*` too; **NEW gen-3** for hosted-cluster defaults; config stack gains both layers |
| 3 | `deploy/templates/deployApp.yaml` | hub branch gains `defaults/hub`; in-cluster branch gains the three `defaults/mces` slots; **NEW** hosted-cluster branch |

Everything added here is either a glob over a folder that does not exist yet
(⇒ zero generator entries ⇒ zero new apps) or a valueFile under
`ignoreMissingValueFiles: true` (⇒ resolves to nothing). This MR is a no-op on
a live fleet by construction — the only thing that changes is what the
platform is *willing* to see once C'.2/C'.3 put it there.

#### 1. `mces/templates/inClusterAppset.yaml`

**1a — generator scans both locations** (`spec.generators`):

```diff
     - git:
         repoURL: <sigs repo URL — unchanged>
         revision: main
         directories:
+          # Migration window: the old top-level in-cluster/ location and its
+          # defaults/hub/ replacement. Only one folder exists at any commit
+          # (XOR); the old glob is removed once the sigs move lands.
           - path: "in-cluster/*"
+          - path: "defaults/hub/*"
   template:
     metadata:
       name: '{{ .Values.group }}-in-cluster-{{ "{{" }}path.basename{{ "}}" }}'
```

**1b — config stack gains the new path** (`spec.template.spec.sources[0].helm.valueFiles`):

```diff
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               - '$values/in-cluster/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              - '$values/defaults/hub/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
         - ref: values
           repoURL: <sigs repo URL — unchanged>
           targetRevision: main
```

#### 2. `operators/templates/operators.yaml`

**2a — gen-2 dual glob + the NEW gen-3.** Both live in the same
`{{- if eq .Values.cluster "in-cluster" }}` block that follows gen-1, so this
is one contiguous hunk. gen-1 (`{{ .Values.clusterPath }}/*`, from Phase B) is
above it and unchanged:

```diff
     {{- if eq .Values.cluster "in-cluster" }}
     - git:
         repoURL: <sigs repo URL — unchanged>
         revision: main
         directories:
+          # Migration window: old and new location of the every-MCE defaults.
+          # Only one folder exists at any commit (XOR); the old glob is
+          # removed once the sigs move lands.
           - path: "mces/in-cluster-defaults/*"
+          - path: "defaults/mces/*"
+    {{- else if not .Values.hub }}
+    # Fleet defaults for hosted clusters: every chart folder here is deployed
+    # to every hosted cluster of the team (mirror of the defaults/mces
+    # generator above).
+    - git:
+        repoURL: <sigs repo URL — unchanged>
+        revision: main
+        directories:
+          - path: "defaults/hosted-clusters/*"
     {{- end }}
   template:
     metadata:
```

☝️ Two things to get right when you paste this:

- The `{{- else if not .Values.hub }}` **converts the existing `if` into an
  if/else-if**. The trailing `{{- end }}` in the context now closes that
  chain — do not add a second one.
- The `not .Values.hub` guard is what keeps this generator off the prod-hub's
  `in-cluster` chart flow. `hub` is only ever set by `inClusterAppset.yaml`;
  precondition E.0.4 exists because a stray `hub:` key in a day1 file would
  flip this branch and silently drop the generator.

**2b — config stack gains both defaults layers** (`sources[0].helm.valueFiles`):

```diff
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/versions/ocp-{{ .Values.ocpVersion }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- if eq .Values.cluster "in-cluster" }}
               - '$values/mces/in-cluster-defaults/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              - '$values/defaults/mces/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              {{- else }}
+              - '$values/defaults/hosted-clusters/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- end }}
               - '$values/{{ .Values.clusterPath }}/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
```

Same shape as 2a: the added `{{- else }}` turns the existing `if` into an
if/else, and the `{{- end }}` in the context closes it.

#### 3. `deploy/templates/deployApp.yaml`

**3a — hub branch** (`spec.sources[0].helm.valueFiles`, top of the list):

```diff
         valueFiles:
           {{- if .Values.hub }}
           - '$values/operators/{{ .Values.operator }}/values.yaml'
           - '$values/in-cluster/{{ .Values.operator }}/values.yaml'
+          - '$values/defaults/hub/{{ .Values.operator }}/values.yaml'
           {{- else }}
           - '$values/operators/{{ .Values.operator }}/values.yaml'
```

**3b — in-cluster branch + the NEW hosted-cluster branch**, a few lines below
in the same list:

```diff
           {{- if eq .Values.cluster "in-cluster" }}
           - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values.yaml'
           - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
+          - '$values/defaults/mces/{{ .Values.operator }}/values.yaml'
+          - '$values/defaults/mces/{{ .Values.operator }}/values-{{ .Values.env }}.yaml'
+          - '$values/defaults/mces/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
+          {{- else }}
+          - '$values/defaults/hosted-clusters/{{ .Values.operator }}/values.yaml'
+          - '$values/defaults/hosted-clusters/{{ .Values.operator }}/values-{{ .Values.env }}.yaml'
+          - '$values/defaults/hosted-clusters/{{ .Values.operator }}/values-{{ .Values.cluster }}.yaml'
           {{- end }}
           - '$values/{{ .Values.mcePath }}/values.yaml'
           - '$values/{{ .Values.clusterPath }}/values.yaml'
```

Three notes:

- Again the added `{{- else }}` reuses the existing `{{- end }}`. This is the
  *inner* if inside the Phase-B `{{- if .Values.hub }}` / `{{- else }}` block —
  make sure you are editing the one that tests `eq .Values.cluster "in-cluster"`,
  not the hub one.
- `values-{{ .Values.env }}.yaml` is a **new slot** with no equivalent in the
  old layout: one file per env under a defaults chart (`values-prod.yaml`)
  now overrides the fleet default for every MCE — or every hosted cluster — in
  that env.
- The hosted-cluster branch is where the whole phase pays off: before it,
  there was no way to say "this chart, on every hosted cluster of the team".

**Gate:** harness IDENTITY OK. (Mock: 35/35 — spec-only `valueFiles`
additions, zero new apps.)

### C'.2 — sigs: `git mv in-cluster defaults/hub` (one commit)

Per team repo, and it must be **one commit** (XOR invariant):

```console
$ mkdir -p defaults
$ git mv in-cluster defaults/hub
$ mkdir -p defaults/hosted-clusters      # + its README.md, copied from the mock
$ git status                             # expect: only R (renames) + the new README
$ git add -A && git commit -m "in-cluster -> defaults/hub; add defaults/hosted-clusters"
```

- `defaults/hosted-clusters/` must exist in git before anyone can use it, and
  git cannot track an empty directory — the README is what makes the folder
  real. Plain files are ignored by `directories:` generators, so the folder
  generates **zero apps** until someone adds a chart folder inside it.
- Every chart keeps its basename ⇒ `path.basename` is unchanged ⇒ the
  generated app names (`<group>-in-cluster-<chart>`) are unchanged ⇒ the appset
  controller updates each app **in place**. Nothing is deleted or recreated.
- The mock's file list for this commit, for reference:
  `in-cluster/README.md`, `in-cluster/example-chart/example-chart.yaml`,
  `in-cluster/example-chart/values.yaml` → the same three under
  `defaults/hub/`, plus the new `defaults/hosted-clusters/README.md`.

> **Repo with no top-level `in-cluster/`** (some teams in the air-gapped
> fleet — see "Baseline assumption"): there is nothing to rename, and a bare
> `git mv` fails with `fatal: bad source`. Create the folder instead, with the
> same README trick that makes `defaults/hosted-clusters/` real:
>
> ```console
> $ mkdir -p defaults/hub defaults/hosted-clusters
> $ cp <mock>/defaults/hub/README.md defaults/hub/
> $ cp <mock>/defaults/hosted-clusters/README.md defaults/hosted-clusters/
> $ git add -A && git commit -m "add defaults/hub + defaults/hosted-clusters"
> ```
>
> Both folders then hold only plain files, which `directories:` generators
> ignore ⇒ **zero apps generated, zero apps deleted** — the commit is inert on
> the fleet. Creating them is optional (a missing folder is equally fine); do
> it anyway so every team repo has the same shape and the next chart has a
> place to land. The XOR invariant is satisfied vacuously here, so this step
> does **not** have to be a single commit for such a repo.

### C'.3 — sigs: `git mv mces/in-cluster-defaults defaults/mces` (one commit)

```console
$ git mv mces/in-cluster-defaults defaults/mces
$ git status                             # expect: only R (renames)
$ ls mces/                               # expect: nothing — the legacy dir is gone
$ git add -A && git commit -m "mces/in-cluster-defaults -> defaults/mces"
```

`dhcp-api-token` moves with it: same basename ⇒ same app names on every MCE
⇒ in-place update; its deploy config resolves from the new path with
identical content. The legacy `mces/` directory is now empty and disappears
from git.

> **Repo with no `mces/in-cluster-defaults/`:** same story as C'.2 — the
> `git mv` would fail, so create the target instead and skip the `ls mces/`
> check (that repo's `mces/` is already gone, removed by Phase C):
>
> ```console
> $ mkdir -p defaults/mces
> $ cp <mock>/defaults/mces/README.md defaults/mces/
> $ git add -A && git commit -m "add defaults/mces"
> ```
>
> The `prune: true` caveat below is about `dhcp-api-token` specifically — it
> does not apply to a repo that never carried the chart.

> This is the one commit in the whole refactor that touches a chart with
> `prune: true` on itself (`dhcp-api-token`). The app is updated in place, not
> deleted, so prune never fires — but it is the reason the delete guard rail
> above is worth having on during the window.

**Gate after each of C'.2 and C'.3:** harness IDENTITY OK.

### C'.4 — platform: remove the old globs/paths (one MR)

Pure removal, mirroring C'.1. Same three files, and the old folders no longer
exist anywhere — so every line below is already dead when you delete it.

**1. `mces/templates/inClusterAppset.yaml`** — generator, then valueFiles:

```diff
         directories:
-          # Migration window: the old top-level in-cluster/ location and its
-          # defaults/hub/ replacement. Only one folder exists at any commit
-          # (XOR); the old glob is removed once the sigs move lands.
-          - path: "in-cluster/*"
           - path: "defaults/hub/*"
```

```diff
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
-              - '$values/in-cluster/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               - '$values/defaults/hub/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
```

**2. `operators/templates/operators.yaml`** — gen-2, then the config stack:

```diff
         directories:
-          # Migration window: old and new location of the every-MCE defaults.
-          # Only one folder exists at any commit (XOR); the old glob is
-          # removed once the sigs move lands.
-          - path: "mces/in-cluster-defaults/*"
           - path: "defaults/mces/*"
     {{- else if not .Values.hub }}
```

```diff
               {{- if eq .Values.cluster "in-cluster" }}
-              - '$values/mces/in-cluster-defaults/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               - '$values/defaults/mces/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- else }}
```

**3. `deploy/templates/deployApp.yaml`** — hub branch, then in-cluster branch:

```diff
           {{- if .Values.hub }}
           - '$values/operators/{{ .Values.operator }}/values.yaml'
-          - '$values/in-cluster/{{ .Values.operator }}/values.yaml'
           - '$values/defaults/hub/{{ .Values.operator }}/values.yaml'
           {{- else }}
```

```diff
           {{- if eq .Values.cluster "in-cluster" }}
-          - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values.yaml'
-          - '$values/mces/in-cluster-defaults/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
           - '$values/defaults/mces/{{ .Values.operator }}/values.yaml'
           - '$values/defaults/mces/{{ .Values.operator }}/values-{{ .Values.env }}.yaml'
           - '$values/defaults/mces/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
           {{- else }}
```

**Gate per step:** harness IDENTITY OK. (Mock: 35/35 at each of the four.)

---

## Phase D — cleanup (platform first, then sigs)

> ⚠️ **Superseded by Phase E — skip this phase.** E.2 replaces the generator
> wholesale (one `sites/` `directories:` entry, env/site already from
> `path[1]`/`path[2]`, no legacy glob left to drop), and E.3 deletes the marker
> files instead of editing their fields. D.2's README refresh is E.4. The
> hunks below are kept **only** for repos that applied D before E existed —
> if you are following the air-gap continuation path, go straight from C' to E
> and read E.2's note about which pre-state your `mcesAppset.yaml` is in.

Two steps, in this order. **Only `mces/templates/mcesAppset.yaml` changes on
the platform side** — `clustersAppset.yaml`, `inClusterApp.yaml`,
`operators.yaml`, `deployApp.yaml` and `inClusterAppset.yaml` are untouched by
this whole phase.

### D.1 — platform: drop the legacy glob; env/site from path

One file, three hunks. Sourcing env/site from path segments is only safe
because the remaining glob is depth-exact-by-marker-name (§0): every match is
at `sites/<site>/<env>/mces/<mce>/mce.yaml`, so `path[1]`/`path[2]` always
mean site/env.

**D.1a — drop the legacy glob** (`spec.generators`). The comment rewrite is
cosmetic; the one line that matters is the deleted `mces/*/mce.yaml`:

```diff
     - git:
         repoURL: <sigs repo URL — unchanged>
         revision: main
-        # An MCE is a folder holding an mce.yaml (env, site, ocpVersion).
-        # Folders without one (in-cluster-defaults, docs, ...) are invisible —
-        # this replaces the old in-cluster-defaults exclude. The two globs
-        # serve the legacy layout and the sites/ tree during the migration
-        # window; the legacy one is removed in Phase D.
-        #
-        # '*' CROSSES '/' here (git pathspec — §0): what keeps this off the
-        # hosted clusters is that their marker is named hc.yaml, not the glob.
+        # An MCE is a folder holding an mce.yaml (ocpVersion). Folders
+        # without one are invisible to this generator.
+        #
+        # '*' CROSSES '/' here (git pathspec — §0): depth comes from the
+        # marker filename, not from the glob. Depth being fixed, the path
+        # segments are trustworthy: path[1] = site, path[2] = env.
         files:
-          - path: "mces/*/mce.yaml"
           - path: "sites/*/*/mces/*/mce.yaml"
   template:
     metadata:
```

> **HARD PRECONDITION for this hunk: every MCE in every team repo has already
> moved to `sites/` (Phase C complete).** Dropping the legacy glob while one
> MCE is still at `mces/<mce>/` deletes that MCE's app and every app beneath
> it. Verify per repo first: `git ls-files -- 'mces/*/mce.yaml'` → nothing.

**D.1b — labels read the path** (`spec.template.metadata.labels`):

```diff
       labels:
         day2.gitops/team: '{{ .Values.group }}'
-        day2.gitops/env: '{{ "{{" }}env{{ "}}" }}'
-        day2.gitops/site: '{{ "{{" }}site{{ "}}" }}'
+        day2.gitops/env: '{{ "{{" }}path[2]{{ "}}" }}'
+        day2.gitops/site: '{{ "{{" }}path[1]{{ "}}" }}'
         day2.gitops/mce: '{{ "{{" }}path.basename{{ "}}" }}'
         day2.gitops/ocp-version: '{{ "{{" }}ocpVersion{{ "}}" }}'
         day2.gitops/role: mce
```

**D.1c — the params read the path** (`spec.template.spec.source.helm.values`):

```diff
           values: |
             group: '{{ .Values.group }}'
             mce: '{{ "{{" }}path.basename{{ "}}" }}'
             mcePath: '{{ "{{" }}path{{ "}}" }}'
-            env: '{{ "{{" }}env{{ "}}" }}'
-            site: '{{ "{{" }}site{{ "}}" }}'
+            env: '{{ "{{" }}path[2]{{ "}}" }}'
+            site: '{{ "{{" }}path[1]{{ "}}" }}'
             ocpVersion: '{{ "{{" }}ocpVersion{{ "}}" }}'
       destination:
         name: '{{ "{{" }}path.basename{{ "}}" }}'
```

**Both** b and c are required in the same MR. b alone leaves the *params*
still reading marker fields; c alone leaves the *labels* reading them. D.2
strips those fields, and anything still reading them then renders a literal
`{{env}}` into a live spec (fasttemplate leaves unmatched placeholders
in place — it does not error).

**Order matters: this MR merges BEFORE D.2**, for exactly that reason.

**Gate:** harness IDENTITY OK — env/site values must come out identical from
the new source.

### D.2 — sigs: strip env/site from every MCE marker file

One commit per team repo, after D.1 is merged. End-state schema is
`ocpVersion` only, identical at MCE and cluster level.

> The comment wording shown below is the mock's. In your repos the markers were
> created by §0 step 1 as **byte-identical copies** of `config.yaml`, so their
> comments still say "config.yaml". Only the two deleted `env:`/`site:` lines
> matter; treat the comment rewrite as optional.

**Every `sites/<site>/<env>/mces/<mce>/mce.yaml`** — delete the two fields:

```diff
 # Cluster registry entry for this MCE. Its presence is what makes this folder
 # an MCE to the platform's files generator; a folder without an mce.yaml is
-# invisible. env/site are needed only while this MCE still lives in the legacy
-# mces/ location (the target sites/<site>/<env>/ tree carries them in the path;
-# both fields are dropped in Phase D of the refactor).
-env: prod
-site: site1
+# invisible. env and site come from the folder's position in the sites/ tree
+# (sites/<site>/<env>/mces/<mce>/) — never from this file.
 # The MCE's OWN OCP version — selects the operators/<chart>/versions/ocp-<v>/
 # layers for every chart deployed on this MCE hub (in-cluster).
 # ALWAYS quote: YAML parses an unquoted 4.20 as the float 4.2.
 ocpVersion: "4.20"
```

**Every `.../mces/<mce>/<cluster>/hc.yaml`** — comment text only, no field
changes (these never carried env/site):

```diff
 # Cluster registry entry. Presence of this file is what makes the folder a
 # hosted cluster to the platform's files generator. env/site are NEVER set
-# here — the cluster inherits them from its MCE level.
+# here — they come from the sites/<site>/<env>/ position of the MCE above.
 # The cluster's OWN OCP version — selects the operators/<chart>/versions/ocp-<v>/
 # layers for every chart on this cluster. ALWAYS quote (4.20 would parse as 4.2).
 ocpVersion: "4.20"
```

**READMEs** — refresh from the mock, in the same commit:

| File | What it becomes |
|---|---|
| `README.md` (team-repo root) | the tree contract: `sites/<site>/<env>/mces/<mce>/<cluster>/`, naming rules (incl. the cluster naming convention), the marker-file contract, both value stacks with precedence tables, the XOR + one-commit-move rules |
| `defaults/hub/README.md` | rewritten for the new path; what lands on prod-hub |
| `defaults/mces/README.md` | rewritten for the new path; the `values-<env>` / `values-<mce>` slots; the defaults-over-stream-pin `targetRevision` footgun |
| `defaults/hosted-clusters/README.md` | already created in C'.2 — leave as is |

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
| per-MCE app (mcesAppset) | `$day1` valueFile on the clusters-chart source | `sites/<site>/mces/<mce>/version.yaml` |
| per-hosted-cluster app (clustersAppset) | `$day1` valueFile on the operators-chart source | `sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml` |
| MCE in-cluster (`inClusterApp`) | passed inline from the clusters chart | — (the MCE's, above) |

**The two day1 files are not the same kind of thing** — this is why the MCE
row does *not* point at the MCE's `values.yaml`, which is where the version
first lived:

- `hostedClusters/<hc>.yaml` is **day1's own provisioning input**. Day2 reads
  the tag day1 actually installed, so the value cannot drift from reality. That
  is the coupling Phase E was built to get.
- `version.yaml` is **day2-owned**: day1's charts never consume it. It has to be
  a file of its own because `mastertag` in the MCE's `values.yaml` already means
  something else to day1 — *the default version for the hosted clusters under
  this MCE*, overridden by each HC's own file. Same key, different fact, in a
  file day1 writes. Parking the hub's version there is inert only for as long as
  every HC keeps overriding it, and it fails silently in both directions: an HC
  added without its own `mastertag` gets **provisioned** at what day2 believes is
  the hub's version, and anyone editing that default silently re-versions the
  hub's in-cluster apps in every sig — with nothing in day1's CI to catch it,
  because day1's chart never reads the key.

Two rules travel with `version.yaml`: it carries **`mastertag` and nothing
else** (it is a value file — any other key lands as a day2 chart value), and it
is **hand-maintained**. Nothing provisions or verifies an MCE hub's version, so
Phase E's "the value is the tag day1 provisioned, not a human's copy of it"
holds for hosted clusters but **not** for MCEs: whoever upgrades a hub must edit
this file. It is the one version in the fleet no offline check can compare
against reality.

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
   it fails per folder with the exact day1 path it expected. For MCEs that file
   is `version.yaml` and it does not exist yet: **E.1 creates it**, and E.1 must
   merge before E.2. The arch suffix is optional (`4.16.27` is as valid as
   `4.16.27-x86_64`); the derivation strips at the first `-` either way.
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
   silently becomes a chart value. The audit covers only the files day2
   actually reads — `hostedClusters/*.yaml`, plus the `version.yaml` files E.1
   creates. The MCEs' `values.yaml` is **not** in scope: day2 stopped reading it
   when the version moved to `version.yaml`, which is half the reason for the
   separate file. Grep them for the platform's vocabulary:

```console
$ grep -rnE '^(group|mce|mcePath|cluster|clusterPath|env|site|hub|operator):' sites/
```

   Any hit needs handling before E.2. The dangerous one is `hub:` — a truthy
   value flips the `{{- else if not .Values.hub }}` branch in
   `operators.yaml` and silently drops the `defaults/hosted-clusters` generator
   for that cluster. (In the mock, hosted-cluster files carry only `dhcp_values`
   and `mastertag`, both inert.) A `version.yaml` should never trip this grep —
   if one does, someone put more than `mastertag` in it.

### E.1 — day1 repo: one new file per MCE, then confirm the rest

For hosted clusters Phase E only *reads* day1 — their versions are already
there, in the files day1 provisions from. MCEs are the exception: day1 records
no version for a hub, so one file per MCE has to be created. Add
`sites/<site>/mces/<mce>/version.yaml`:

```yaml
# The OCP version of the MCE hub ITSELF, read at render time by gitops-day2-prod
# (mcesAppset -> clusters chart -> inClusterApp). day1's charts do not consume
# this file, and it is deliberately NOT the values.yaml beside it, whose
# `mastertag` is day1's default version for the hosted clusters under this MCE.
#
# THIS FILE MUST CARRY `mastertag` AND NOTHING ELSE — it is loaded as a day2
# helm value file, so any other top-level key silently becomes a chart value.
#
# Hand-maintained: nothing provisions or verifies a hub's version, so this must
# be updated by whoever upgrades the MCE. The arch suffix is optional.
mastertag: 4.16.27-x86_64
```

**Order, and why it is three MRs, not one.** The templates and this file must
never disagree, and the two ways they can disagree are not symmetric:

1. **day1 MR — add.** Create every `version.yaml`. Leave any `mastertag`
   already in the MCEs' `values.yaml` exactly where it is. Nothing reads the new
   files yet, so this MR is inert on both sides.
2. **E.2 — the platform MR.** The `mcesAppset` valueFile flips to
   `version.yaml`. Merging this before step 1 renders `mastertag missing`
   for every MCE's in-cluster apps, fleet-wide — the same split-brain hazard the
   E.2 file ordering warns about below.
3. **day1 MR — remove** (only if a `mastertag` was ever added to the MCEs'
   `values.yaml` for day2's benefit; skip it if that key is genuinely day1's own
   HC default). **Before merging, confirm every hosted cluster carries its own
   tag**, including clusters with no day2 folder — day2's parity lint only
   proves it for the ones day2 knows about:

   ```console
   $ grep -rL '^mastertag:' sites/*/mces/*/hostedClusters/*.yaml   # must print nothing
   ```

   Removing a default that some HC still relies on changes what day1
   *provisions* — the same silent-versioning hazard, pointed the other way.

Also confirm, before step 1 merges, that nothing in day1 globs the new file:
check day1's own generators and `valueFiles`/`-f` lists for patterns like
`sites/*/mces/*/*.yaml`. If day1 names `values.yaml` explicitly, adding a
sibling is inert there.

If precondition 2 turns up a hosted cluster day1 does not know about, add its
file too, **before** E.2 — after E.2 a missing day1 entry is a hard render
failure for that cluster's apps.

### E.2 — platform repo: ONE MR (4 files)

| # | File | What changes |
|---|---|---|
| 1 | `mces/templates/mcesAppset.yaml` | `files:` → `directories:`; env/site from `path[1]`/`path[2]`; `source:` → `sources:` + the day1 source; ocp-version label dropped |
| 2 | `clusters/templates/clustersAppset.yaml` | `files:` → `directories:` + in-cluster exclude; day1 valueFile + day1 source; ocp-version label dropped |
| 3 | `clusters/templates/inClusterApp.yaml` | derive `$ocpVersion` from `mastertag`; label from it; pass the raw tag down |
| 4 | `operators/templates/operators.yaml` | same derivation; `.Values.ocpVersion` → `$ocpVersion` in three places |

`deploy/templates/deployApp.yaml`, `mces/templates/inClusterAppset.yaml`,
`mces/templates/appProjectAppset.yaml` and `groups/templates/groupsAppset.yaml`
are **untouched**. All four files ship as **one MR / one commit**: file 1 stops
emitting `ocpVersion` while files 3 and 4 start requiring `mastertag` — split
them and the intermediate commit renders `mastertag missing` fleet-wide.

> **Which pre-state are your files in?** The hunks below are written against
> the state you are in after Phase C' **with Phase D skipped** — that is the
> air-gap path. If you applied Phase D before E existed, `mcesAppset.yaml`
> differs from what is shown in three places: hunk **1a**'s `files:` list
> already has only the `sites/` glob, hunk **1b**'s env/site labels already
> read `path[2]`/`path[1]`, and inside hunk **1c**'s removed block the `env:` /
> `site:` **values** already read `path[2]`/`path[1]` as well. Apply only what
> is actually different — every `+` side is the same either way. Hunks 2, 3
> and 4 are unaffected: Phase D touched no file but `mcesAppset.yaml`.

Two transplant rules, same as Phase B:

- **`repoURL:` lines for the sigs and platform repos keep whatever your files
  already have.** They appear as context. The **day1** `repoURL` is the one
  genuinely new URL — it is shown literally below and must be typed.
- **The `namespace: gitops-{{ .Values.repository }}` line in `mcesAppset.yaml`
  is FROZEN**, as always. It is context in hunk 1b.

#### 1. `mces/templates/mcesAppset.yaml`

**1a — folder discovery replaces the marker glob** (`spec.generators`):

```diff
     - git:
         repoURL: <sigs repo URL — unchanged>
         revision: main
-        # An MCE is a folder holding an mce.yaml (env, site, ocpVersion).
-        # Folders without one (in-cluster-defaults, docs, ...) are invisible —
-        # this replaces the old in-cluster-defaults exclude. The two globs
-        # serve the legacy layout and the sites/ tree during the migration
-        # window; the legacy one is removed in Phase D.
+        # An MCE is a FOLDER under sites/<site>/<env>/mces/. Its existence is
+        # the opt-in — there is no marker file to carry, because there is no
+        # per-MCE data left to carry: the OCP version comes from day1 (below).
         #
-        # '*' CROSSES '/' here (git pathspec — §0): what keeps this off the
-        # hosted clusters is that their marker is named hc.yaml, not the glob.
-        files:
-          - path: "mces/*/mce.yaml"
-          - path: "sites/*/*/mces/*/mce.yaml"
+        # directories: globs are matched with Go path.Match, where '*' matches
+        # exactly ONE path segment. That makes this depth-exact by the engine
+        # itself — unlike a files: glob, whose git pathspec lets '*' cross '/'
+        # and match at any depth (the phantom-MCE bug, CHANGES.md §0).
+        #
+        # Depth being fixed, path segments are trustworthy:
+        # path[1] = site, path[2] = env.
+        #
+        # git cannot track an empty folder: an MCE onboarded before it has any
+        # content of its own needs a .gitkeep to exist here at all.
+        directories:
+          - path: "sites/*/*/mces/*"
   template:
     metadata:
```

Both old globs go. The legacy `mces/*/mce.yaml` entry has nothing left to
match — Phase C is a hard precondition (E.0.1), and there is no legacy-layout
form of the new glob. Confirm per repo before merging:
`git ls-files -- 'mces/*'` → nothing.

**1b — labels: env/site from the path, ocp-version dropped**
(`spec.template.metadata`):

```diff
       name: '{{ .Values.group }}-{{ "{{" }}path.basename{{ "}}" }}'
       namespace: gitops-{{ .Values.repository }}
       labels:
         day2.gitops/team: '{{ .Values.group }}'
-        day2.gitops/env: '{{ "{{" }}env{{ "}}" }}'
-        day2.gitops/site: '{{ "{{" }}site{{ "}}" }}'
+        day2.gitops/env: '{{ "{{" }}path[2]{{ "}}" }}'
+        day2.gitops/site: '{{ "{{" }}path[1]{{ "}}" }}'
         day2.gitops/mce: '{{ "{{" }}path.basename{{ "}}" }}'
-        day2.gitops/ocp-version: '{{ "{{" }}ocpVersion{{ "}}" }}'
+        # No ocp-version label here: this layer never learns the version. It
+        # only points the clusters chart at the day1 file that holds it.
         day2.gitops/role: mce
     spec:
```

☝️ The `namespace:` line is the FROZEN one — context, not a change.

**1c — `source:` becomes `sources:`, and day1 joins the app.** Replace this
as a block; the indentation of the whole helm section shifts by two:

```diff
     spec:
       project: '{{ .Values.group }}'
-      source:
-        repoURL: <platform repo URL — unchanged>
-        targetRevision: main
-        path: clusters
-        helm:
-          ignoreMissingValueFiles: true
-          values: |
-            group: '{{ .Values.group }}'
-            mce: '{{ "{{" }}path.basename{{ "}}" }}'
-            mcePath: '{{ "{{" }}path{{ "}}" }}'
-            env: '{{ "{{" }}env{{ "}}" }}'
-            site: '{{ "{{" }}site{{ "}}" }}'
-            ocpVersion: '{{ "{{" }}ocpVersion{{ "}}" }}'
+      sources:
+        - repoURL: <platform repo URL — unchanged>
+          targetRevision: main
+          path: clusters
+          helm:
+            ignoreMissingValueFiles: true
+            # The MCE hub's own OCP version enters the chain HERE. It lives
+            # in version.yaml — a day1 file day1's own charts never consume,
+            # deliberately NOT the MCE's values.yaml, whose `mastertag` is
+            # day1's *default HC version* and would collide with this one.
+            # Every sig renders from that one file, so an upgrade is one day1
+            # edit instead of one edit per sig. Two rules travel with it:
+            # it must carry `mastertag` and nothing else (any other key here
+            # lands as a chart value), and unlike a hosted cluster's tag it is
+            # hand-maintained — nothing provisions or verifies an MCE hub's
+            # version. NOTE the day1 tree has no <env> level — env lives only
+            # inside the MCE name.
+            valueFiles:
+              - '$day1/sites/{{ "{{" }}path[1]{{ "}}" }}/mces/{{ "{{" }}path.basename{{ "}}" }}/version.yaml'
+            values: |
+              group: '{{ .Values.group }}'
+              mce: '{{ "{{" }}path.basename{{ "}}" }}'
+              mcePath: '{{ "{{" }}path{{ "}}" }}'
+              env: '{{ "{{" }}path[2]{{ "}}" }}'
+              site: '{{ "{{" }}path[1]{{ "}}" }}'
+        - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day1/platform-config.git'
+          targetRevision: main
+          ref: day1
       destination:
         name: '{{ "{{" }}path.basename{{ "}}" }}'
         namespace: gitops-{{ .Values.group }}
```

**The chart source must stay first in the list.** The platform's recursion and
the render harness both key off `sources[0]`; a `ref`-only source in slot 0
renders nothing. Note also `$day1` resolves against the *`ref: day1`* source —
the `$` prefix is a source ref, not a path.

#### 2. `clusters/templates/clustersAppset.yaml`

**2a — folder discovery + the exclude the marker name used to provide**
(`spec.generators`):

```diff
     - git:
         repoURL: <sigs repo URL — unchanged>
         revision: main
-        # A hosted cluster is a folder holding an hc.yaml (ocpVersion only;
-        # env/site are inherited from the MCE). in-cluster/ and chart folders
-        # have no hc.yaml and are invisible — this replaces the old
-        # in-cluster exclude. The MCE's own marker is mce.yaml, so this glob
-        # cannot climb back up to it (§0).
-        files:
-          - path: "{{ .Values.mcePath }}/*/hc.yaml"
+        # A hosted cluster is any FOLDER in the MCE dir except in-cluster/.
+        # Folder existence is the opt-in — no marker file, because there is no
+        # per-cluster data left to carry: env/site are inherited from the MCE
+        # and the OCP version comes from day1 (below).
+        #
+        # Depth-exact by the engine: directories: globs use Go path.Match,
+        # where '*' stops at '/' (see mcesAppset for why that matters).
+        #
+        # Two consequences worth knowing: a cluster onboarded with no content
+        # of its own needs a .gitkeep (git cannot track an empty folder), and
+        # a stray folder here that is NOT a cluster becomes a phantom app —
+        # render-verify's day1 parity lint catches that before merge, since a
+        # stray folder has no day1 version file.
+        directories:
+          - path: "{{ .Values.mcePath }}/*"
+          - path: "{{ .Values.mcePath }}/in-cluster"
+            exclude: true
   template:
     metadata:
```

The `exclude: true` entry is **not optional** — with no marker file, nothing
else distinguishes `in-cluster/` from a hosted-cluster folder, and
`inClusterApp.yaml` already owns that destination. Without it you get two apps
racing on the same target.

**2b — ocp-version label dropped** (`spec.template.metadata.labels`):

```diff
         day2.gitops/mce: '{{ .Values.mce }}'
         day2.gitops/cluster: '{{ "{{" }}path.basename{{ "}}" }}'
-        day2.gitops/ocp-version: '{{ "{{" }}ocpVersion{{ "}}" }}'
+        # No ocp-version label here: this layer never learns the version. It
+        # only points the operators chart at the day1 file that holds it.
         day2.gitops/role: hosted-cluster
```

**2c — the day1 valueFile** (`spec.template.spec.sources[0].helm`). This file
already uses `sources:` from Phase B, so only the helm block changes:

```diff
           path: operators
           helm:
             ignoreMissingValueFiles: true
+            # The hosted cluster's OCP version enters the chain HERE: its day1
+            # file, named exactly after this folder, carries `mastertag`. The
+            # file's other keys (dhcp_values) are inert — nothing downstream
+            # reads them, and the inline values below outrank them anyway
+            # (Argo applies helm.values after valueFiles).
+            valueFiles:
+              - '$day1/sites/{{ .Values.site }}/mces/{{ .Values.mce }}/hostedClusters/{{ "{{" }}path.basename{{ "}}" }}.yaml'
             values: |
               group: '{{ .Values.group }}'
               mce: {{ .Values.mce }}
```

**2d — drop `ocpVersion`, append the day1 source** (end of the same block):

```diff
               clusterPath: '{{ "{{" }}path{{ "}}" }}'
               env: {{ .Values.env }}
               site: {{ .Values.site }}
-              ocpVersion: '{{ "{{" }}ocpVersion{{ "}}" }}'
+        - repoURL: 'https://8200gitlab[REDACTED]/redbull/gitops-day1/platform-config.git'
+          targetRevision: main
+          ref: day1
       destination:
         name: in-cluster
```

Mind the indentation: `site:` is inside the `values: |` literal block; the new
`- repoURL:` is a sibling of the existing `- repoURL:` in `sources:`, six
spaces shallower.

#### 3. `clusters/templates/inClusterApp.yaml`

**3a — the derivation, at the very top of the file** (before `apiVersion:`):

```diff
+{{- /* The MCE's OCP version arrives as .Values.mastertag, resolved by this
+     Application's own $day1 value file (see mcesAppset). Strip the arch at
+     the first '-': 4.16.27-x86_64 -> 4.16.27, used verbatim as ocpVersion.
+     `required` fails the render loudly if day1 has no entry — an MCE must
+     never deploy with a silently empty version. */ -}}
+{{- $mastertag := required "mastertag missing: no day1 platform-config file at sites/<site>/mces/<mce>/version.yaml, or it lacks the key" .Values.mastertag | toString -}}
+{{- $ocpVersion := $mastertag | splitList "-" | first -}}
 apiVersion: argoproj.io/v1alpha1
 kind: Application
 metadata:
```

`| toString` is load-bearing: an unquoted `mastertag: 4.16` in a day1 file
parses as a float, and `splitList` on a float errors out.

**3b — the label uses the derived version** (`metadata.labels`):

```diff
     day2.gitops/cluster: in-cluster
     # The MCE's own OCP version — in-cluster charts resolve version layers by it.
-    day2.gitops/ocp-version: '{{ .Values.ocpVersion }}'
+    day2.gitops/ocp-version: '{{ $ocpVersion }}'
     day2.gitops/role: mce
```

**3c — hand the raw tag down, not the derived version**
(`spec.sources[0].helm.values`):

```diff
           clusterPath: {{ .Values.mcePath }}/in-cluster
           env: {{ .Values.env }}
           site: {{ .Values.site }}
-          ocpVersion: '{{ .Values.ocpVersion }}'
+          # Pass the raw tag, not the derived version: the operators chart
+          # derives it the same way for hosted clusters, so there is exactly
+          # one derivation rule in the chain.
+          mastertag: '{{ $mastertag }}'
   destination:
     name: in-cluster
```

This app is the MCE's only in-cluster path, and it never reads `$day1`
itself — the MCE's `mastertag` was already resolved one layer up, by
`mcesAppset`'s day1 valueFile, and arrives here as a plain Helm value.

#### 4. `operators/templates/operators.yaml`

**4a — the derivation, at the very top of the file** (before `apiVersion:`) —
same two statements as 3a, different `required` message because this template
serves both cluster kinds:

```diff
+{{- /* The destination's OCP version arrives as .Values.mastertag:
+       hosted clusters  -> from this Application's own $day1 value file
+                           (sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml)
+       the MCE itself   -> passed inline by inClusterApp, from the MCE's day1
+                           version.yaml (day2-owned; day1 never reads it)
+     One derivation either way: strip the arch at the first '-' and use the
+     rest verbatim (4.16.27-x86_64 -> 4.16.27). Version-pin layers are keyed
+     by that exact version, so EVERY upgrade — z-streams included — needs its
+     operators/<chart>/versions/ocp-<v>/ folder created BEFORE day1 flips the
+     tag, or a pinned chart silently falls back to the team default. */ -}}
+{{- $mastertag := required "mastertag missing: no day1 platform-config entry for this destination" .Values.mastertag | toString -}}
+{{- $ocpVersion := $mastertag | splitList "-" | first -}}
 apiVersion: argoproj.io/v1alpha1
 kind: ApplicationSet
 metadata:
```

**4b — the label** (`spec.template.metadata.labels`):

```diff
         day2.gitops/chart: '{{ "{{" }}path.basename{{ "}}" }}'
-        day2.gitops/ocp-version: '{{ .Values.ocpVersion }}'
+        day2.gitops/ocp-version: '{{ $ocpVersion }}'
         day2.gitops/role: {{ eq .Values.cluster "in-cluster" | ternary "mce" "hosted-cluster" }}
```

**4c — the value passed to the deploy chart, and the version-pin path**
(`spec.template.spec.sources[0].helm`). The comment rewrite is cosmetic; the
two `$ocpVersion` substitutions are not:

```diff
               env: {{ .Values.env }}
               site: {{ .Values.site }}
-              ocpVersion: '{{ .Values.ocpVersion }}'
+              ocpVersion: '{{ $ocpVersion }}'
               operator: {{ "{{" }}path.basename{{ "}}" }}
-            # Deploy-config stack, lowest -> highest: team default, per-OCP-stream
-            # pin (selected by the destination's own ocpVersion), fleet defaults,
-            # the cluster's own folder. All optional (ignoreMissingValueFiles).
+            # Deploy-config stack, lowest -> highest: team default, per-OCP-version
+            # pin (selected by the destination's own version, from day1), fleet
+            # defaults, the cluster's own folder. All optional
+            # (ignoreMissingValueFiles).
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
-              - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/versions/ocp-{{ .Values.ocpVersion }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/versions/ocp-{{ $ocpVersion }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- if eq .Values.cluster "in-cluster" }}
               - '$values/defaults/mces/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
```

`ocpVersion:` in the inline values is what keeps `deployApp.yaml` unchanged —
it still consumes `.Values.ocpVersion`, which now arrives carrying the full
patch version instead of the stream.

Note this template does **not** gain a `ref: day1` source of its own: for a
hosted cluster the day1 file was resolved by `clustersAppset` (hunk 2c) and
arrives as `.Values.mastertag`; for an MCE it arrives from `inClusterApp`
(hunk 3c). Nothing below this layer touches day1.

---

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

Refresh from the mock: `ARCHITECTURE.md` (discovery contract — including the
`version.yaml` vs `hostedClusters/<hc>.yaml` distinction and the hand-maintained
caveat — version management, labels, runbooks R1/R2/R6/R7/R9, invariants
checklist), the team-repo root README, and `defaults/mces/README.md`. Copy the updated
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
| **(E)** day1 file carries a platform key (`hub:`, `env:`, `site:`…) | silently becomes a chart value; a truthy `hub:` drops the `defaults/hosted-clusters` generator for that cluster | E.0 precondition 4 grep, before the platform MR — and `version.yaml` is `mastertag`-only by rule, so only `hostedClusters/*.yaml` carries the risk |
| **(E)** an MCE hub is upgraded and nobody edits its `version.yaml` | its in-cluster charts stay pinned to the old `ocp-<v>` layer — silently, and in every sig | none offline: no day1 field records a hub's version, so this is the one value no check can compare against reality. Make it part of the hub-upgrade runbook (R2) |
| **(E)** the hub's version put in the MCE's `values.yaml` instead | day1 reads that key as its *default HC version*: an HC without its own tag gets provisioned at the hub's version, and editing it re-versions the hub's apps | separate `version.yaml` (E.1); before removing any such key, verify every `hostedClusters/*.yaml` carries its own `mastertag` |
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
