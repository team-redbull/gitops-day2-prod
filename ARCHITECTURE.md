# Day2 GitOps — Architecture Guide

*Everything the team needs to understand the sites/ architecture before
implementing it in the air-gapped environment. The guide is layered: Part I
is the plain-language version anyone can read in ten minutes; Part II is the
deep dive; Part III is the runbooks you'll use day to day; Part IV is
reference. Migration steps live in `CHANGES.md`; the original design review
in `REFACTOR-PLAN.md`.*

---

# Part I — The idea, in plain words

## What this system does

We manage many OpenShift clusters: one management cluster (**prod-hub**),
several **MCE hubs** under it, and many **hosted clusters** under those. Each
team has charts (helm packages) that need to run on some of these clusters.

The whole thing is driven by git folders. **There is no registration form and
no UI step: creating a folder in your team's repo is how you deploy
something, and a one-line file edit is how you upgrade something.** Argo CD
watches the repos and turns folders into running applications.

## The one sentence to remember

> **Folders say WHERE things run. Files say WHICH VERSION runs there.**

- Where = the `sites/` tree: `sites/<site>/<env>/mces/<mce>/<cluster>/`.
  A cluster's site and environment never change, so they live in the path.
- Which version = small files: a cluster's OCP version is one line in its
  `config.yaml`; a chart's pinned version is one line in a pin file.

That's the core design decision. Upgrading a cluster or a chart is a one-line
merge request — never moving folders around.

## What was wrong before

The old repo was a flat list of MCEs. It worked, but:

- **You couldn't see prod vs prep.** Environment and site were only hidden
  inside folder names like `ocp4-prep-mce-site1-a`. "Upgrade all prod" meant
  reading names and hoping.
- **Versions didn't exist.** Nothing recorded which OCP version a cluster
  runs, or which chart version is right for which OCP version. That
  knowledge lived in people's heads.
- **No way to act on a fleet.** The generated Argo apps had no labels, so
  there was no "sync everything prod" command. Ever.
- **Deploying a chart to every hosted cluster meant copy-pasting its folder
  into every cluster folder** — defaults existed only for MCE hubs.
- **Special folders needed special rules.** Folders like
  `in-cluster-defaults` sat inside scanned paths, so every scanner needed a
  hand-maintained "ignore this one" exclude. Forgetting one created garbage
  apps.

## What the new layout gives you

| You want to... | You do... |
|---|---|
| upgrade a cluster to OCP 4.20 | edit one line: `ocpVersion: "4.20"` in its `config.yaml` |
| upgrade a chart on all 4.20 clusters | edit one line in `operators/<chart>/versions/ocp-4.20/<chart>.yaml` |
| deploy a chart to ONE cluster | add a folder with 2 files under that cluster |
| deploy a chart to EVERY hosted cluster | add a folder with 2 files under `defaults/hosted-clusters/` |
| add a new cluster | add a folder with 1 file (`config.yaml`) |
| sync everything prod | `argocd app sync -l day2.gitops/env=prod` |
| see which clusters run 4.16 | one `grep` |

And the safety story stayed the same or got better: renders are verified
before merge, moves update apps in place, and even a bad mistake orphans
workloads (they keep running) rather than deleting them.

## The cast of characters

- **Argo CD** — watches git, makes clusters match it. Each MCE hub runs its
  own Argo; prod-hub runs the top one.
- **Application** — Argo's unit of "deploy this chart there". Our leaf apps
  (name ends in `-deploy`) are the actual workloads.
- **ApplicationSet ("appset")** — a template plus a **generator** that stamps
  out one Application per thing the generator finds in git. Generators are
  how folders become apps.
- **The platform repo** (`argocd-day2-platform`) — five small helm charts
  (`groups`→`mces`→`clusters`→`operators`→`deploy`) that render *only* Argo
  Applications/ApplicationSets. It's the machinery. Teams rarely touch it.
- **Your team repo** (`sigs/<team>`) — folders + small YAML files. This is
  where all day-to-day work happens.
- **Chart repos** (`helm-charts/<chart>`) — the real workload helm charts,
  one repo each, one **frozen branch per release**.

## The story of one chart (follow this once, slowly)

Say `sigs/redbull/sites/site1/prod/mces/ocp4-prod-mce-site1-a/ocp4-prod-herzi-site1/cluster-roles/`
exists, with `cluster-roles.yaml` and `values.yaml` inside. How does that
become a running chart on the herzi cluster?

1. **prod-hub** discovers the team: the `groups` appset scans GitLab, finds
   `sigs/redbull`, and creates one app that renders the platform's `mces`
   chart for redbull.
2. That chart contains an appset that scans the team repo for
   `sites/*/*/mces/*/config.yaml`. It finds the MCE's config.yaml, so it
   creates the app `redbull-ocp4-prod-mce-site1-a` — which renders the
   platform's `clusters` chart **onto the MCE's own Argo**, passing along:
   the MCE's path, site (`site1`), env (`prod`), and the MCE's `ocpVersion`.
3. On the MCE, that chart's appset scans `<mce-path>/*/config.yaml`, finds
   the herzi cluster's config.yaml, and creates `redbull-ocp4-prod-herzi-site1`
   — which renders the `operators` chart, now passing the *cluster's* own
   `ocpVersion`.
4. The `operators` appset lists the directories in the cluster's folder.
   It finds `cluster-roles/` and creates `redbull-ocp4-prod-herzi-site1-cluster-roles`
   — which renders the `deploy` chart, merging the chart's config files
   (which repo? which branch? which namespace?) from lowest to highest
   priority.
5. The `deploy` chart renders the final leaf:
   `redbull-ocp4-prod-herzi-site1-cluster-roles-deploy` — an Application
   pointing at the actual `helm-charts/cluster-roles` repo, destination
   `ocp4-prod-herzi-site1`, with the merged values. An operator syncs it
   (leaf apps don't auto-sync), and the chart runs.

Notice what did the work: **a config.yaml made a folder count as a cluster;
a directory made a chart exist there.** No exclude lists, no registries. A
folder without config.yaml (like `in-cluster/`, `defaults/`, or a chart
folder) is simply invisible to the cluster-discovery steps — that's the
trick that removed all the special-case rules.

---

# Part II — The deep dive

## 1. The team repo, fully annotated

```
sigs/redbull/
├── sites/                              # WHERE things run — immutable identity
│   └── site1/
│       ├── values.yaml                 # optional site-wide values (a "slot" — see §3)
│       ├── prep/
│       │   ├── values.yaml             # optional site+env values (slot)
│       │   └── mces/
│       │       └── ocp4-prep-mce-site1-a/
│       │           ├── config.yaml     # ocpVersion: "4.20"  ← the MCE itself
│       │           ├── in-cluster/     # charts on the MCE hub itself
│       │           │   ├── bmhgen/{bmhgen.yaml, values.yaml}
│       │           │   └── kyverno/{kyverno.yaml, values.yaml}
│       │           ├── ocp4-prep-eyal-site1/
│       │           │   ├── config.yaml # ocpVersion: "4.20"  ← this cluster
│       │           │   └── cluster-roles/{cluster-roles.yaml, values.yaml}
│       │           └── ocp4-prep-itay-site1/...
│       └── prod/mces/ocp4-prod-mce-site1-a/...
├── operators/                          # WHAT can run — per-chart, team-wide defaults
│   ├── cluster-roles/{cluster-roles.yaml, values.yaml}
│   ├── kyverno/...
│   └── <chart>/versions/ocp-<v>/{<chart>.yaml, values.yaml}  # only version-sensitive charts
└── defaults/                           # deploy-once-to-a-whole-fleet
    ├── hub/                            # → prod-hub itself
    ├── mces/                           # → every MCE hub (dhcp-api-token lives here)
    └── hosted-clusters/                # → every hosted cluster (NEW in this refactor)
```

Rules worth internalizing:

- **Folder basename == Argo cluster name.** Argo destinations go by cluster
  *name*, and cluster names are flat and global — the tree nesting is for
  humans and for globs; the basename is the contract. Naming convention:
  `ocp4-<env>-<name>-<site>`, and the env/site in the name must agree with
  the folder's position.
- **`in-cluster` means "this Argo's own cluster".** Under an MCE folder it's
  the MCE hub (as seen by the MCE's Argo). In the hub flow it's prod-hub (as
  seen by prod-hub's Argo). Same word, per-Argo meaning.
- **Why `mces/` exists but there's no `envs/` wrapper:** a container folder
  must earn its place. The literal `mces` segment in the glob
  `sites/*/*/mces/*/config.yaml` stops a stray config.yaml elsewhere from
  fabricating a phantom MCE, and keeps the env level free for future
  siblings. Envs are a closed set (`prod|prep|test`) and the only children
  of a site — a wrapper would only add depth.
- **`example-chart` folders are convention demos.** Never ship them to prod.

### 1.1 `config.yaml` — the cluster registry entry

```yaml
ocpVersion: "4.20"    # ALWAYS quoted — YAML parses bare 4.20 as the float 4.2
```

One key, three jobs:

1. **Discovery marker.** The generators anchor on it: folder with config.yaml
   at MCE depth = an MCE; one level deeper = a hosted cluster; no file = not
   a cluster, invisible. One canonical filename also guarantees at most one
   generator entry per folder — by construction, not by discipline.
2. **The version.** `ocpVersion` is the OCP version of the folder's **own**
   cluster, and it is the *only* version key in the system. There is no
   separate "MCE version": an MCE hub is versioned by its own OCP version
   exactly like a hosted cluster. This value selects every
   `operators/<chart>/versions/ocp-<v>/` layer for charts going to that
   destination.
3. **Extension point.** Future per-cluster metadata (maintenance windows,
   canary flags, pause switches) gets a key here — no restructuring.

env/site are **never** written in the file — the platform reads them from the
path (`path[1]` = site, `path[2]` = env). (During the migration window only,
MCE-level files temporarily carry env/site because the legacy layout has no
path to read them from — Phase D removes them.)

### 1.2 Chart folders — the two files

A chart folder anywhere means "deploy this chart to this context" and holds:

- **`<chart>.yaml` — deploy config.** Read by the platform itself:
  `repourl` (**all-lowercase**! `repoUrl` reaches the template as nil and
  renders an empty repoURL — several old configs have this bug; don't copy
  them), `targetRevision` (default `HEAD`), `path` (default `.`),
  `projectNamespace`, `syncPolicy`, `ignoreDifferences`, `appname`,
  `oldConvention`.
- **`values.yaml` — workload values.** Passed to the actual helm chart.

## 2. Discovery mechanics — how folders become Applications

Two generator types do all the work:

- **git files generator** — "one Application per *matching file*". Gives the
  template `{{path}}` (the directory containing the file),
  `{{path.basename}}`, `{{path[n]}}` segments, **plus every key inside the
  file** as a parameter. That last part is how `ocpVersion` travels from
  config.yaml into the chain. Used to discover MCEs and hosted clusters.
- **git directories generator** — "one Application per *matching directory*".
  Path parameters only. Used for chart folders (their name is all we need).

`*` in a glob matches exactly one path segment. Parameters are substituted
into the appset's template text; the result is an Application.

The full chain (each row renders the next):

| Layer | Template | Generator | Emits | Runs on |
|---|---|---|---|---|
| groups | `groups/templates/groupsAppset.yaml` | scmProvider (GitLab group) | App `<team>` → platform `mces` chart | prod-hub |
| mces | `mces/templates/mcesAppset.yaml` | **files**: `sites/*/*/mces/*/config.yaml` | App `<team>-<mce>` → `clusters` chart, destination = the MCE; passes `mce`, `mcePath`, `env`, `site`, `ocpVersion` | prod-hub |
| app-projects | `mces/templates/appProjectAppset.yaml` | clusters (all) | AppProject `<team>` on every cluster (sync-wave −1) | prod-hub |
| hub charts | `mces/templates/inClusterAppset.yaml` | dirs: `defaults/hub/*` | App `<team>-in-cluster-<chart>` → `deploy` chart in hub mode | prod-hub |
| clusters | `clusters/templates/clustersAppset.yaml` | **files**: `<mcePath>/*/config.yaml` | App `<team>-<cluster>` → `operators` chart; `ocpVersion` **overridden** with the cluster's own | the MCE |
| — static | `clusters/templates/inClusterApp.yaml` | none (always rendered) | App `<team>-in-cluster` → `operators` chart with `cluster: in-cluster`; `ocpVersion` **inherited** from the MCE | the MCE |
| operators | `operators/templates/operators.yaml` | dirs ×3: `<clusterPath>/*`; `defaults/mces/*` (in-cluster only); `defaults/hosted-clusters/*` (hosted only) | App `<team>-<cluster>-<chart>` → `deploy` chart | the MCE |
| deploy | `deploy/templates/deployApp.yaml` | — | App `<team>-<cluster>-<chart>-deploy` = **the workload**, destination `name: <cluster>` | the MCE |

Two details carry the whole design:

- **`ocpVersion` flows down with override semantics.** The mces layer sends
  the MCE's version → the clusters layer replaces it with each hosted
  cluster's own → the static in-cluster app deliberately does *not* replace
  it. Net effect: MCE-hub charts version by the MCE's OCP version,
  hosted-cluster charts by their own — one key, no special cases.
- **Only `mcesAppset.yaml` knows the tree layout.** Every other template
  receives the generator's `{{path}}` as `mcePath`/`clusterPath` values and
  builds all file paths from them. A future layout change touches one file.

**The frozen line.** The template line
`namespace: gitops-{{ .Values.repository }}` in `mcesAppset.yaml` and
`appProjectAppset.yaml` renders as `gitops-` (the value is never set). It is
wrong, known, and **deliberately frozen**: a generated app's namespace is
part of its identity — "fixing" it would delete and recreate every app in
the fleet. Leave it byte-identical, always.

## 3. The two value stacks (how a chart gets its configuration)

Argo merges a list of value files in order — later files win per key — and
then applies the inline values last. Every file layer in our stacks is
declared with `ignoreMissingValueFiles: true`, so think of each layer as a
**slot, not a file**: a missing file quietly contributes nothing, and
creating it later is always a deliberate, scoped opt-in. Most slots are empty
today. That is the normal, intended state.

**Stack 1 — deploy config** (`<chart>.yaml` files; decides repo, branch,
namespace, sync policy), lowest → highest:

| # | Hosted cluster | MCE in-cluster | prod-hub |
|---|---|---|---|
| 1 | `operators/<c>/<c>.yaml` | same | same |
| 2 | `operators/<c>/versions/ocp-<v>/<c>.yaml` — `<v>` is the destination's own version | same (`<v>` = the MCE's) | — (hub is version-less) |
| 3 | `defaults/hosted-clusters/<c>/<c>.yaml` | `defaults/mces/<c>/<c>.yaml` | `defaults/hub/<c>/<c>.yaml` |
| 4 | `<clusterPath>/<c>/<c>.yaml` | `<mcePath>/in-cluster/<c>/<c>.yaml` | — |

**Stack 2 — workload values** (`values.yaml` files; what the chart itself
sees), lowest → highest, hosted-cluster column in full:

| # | Layer | Scope |
|---|---|---|
| 1 | `operators/<c>/values.yaml` | chart, team-wide |
| 2 | `operators/<c>/versions/ocp-<v>/values.yaml` | chart, per OCP stream |
| 3 | `sites/<site>/values.yaml` | site-wide, chart-agnostic (use sparingly) |
| 4 | `sites/<site>/<env>/values.yaml` | site + env |
| 5 | `defaults/hosted-clusters/<c>/values.yaml` | chart, whole fleet |
| 6 | `defaults/hosted-clusters/<c>/values-<env>.yaml` | chart + env |
| 7 | `defaults/hosted-clusters/<c>/values-<cluster>.yaml` | chart + one cluster |
| 8 | `<mcePath>/values.yaml` | MCE-wide |
| 9 | `<clusterPath>/values.yaml` | cluster-wide |
| 10 | `<clusterPath>/<c>/values.yaml` | chart @ cluster — always wins |

MCE in-cluster mirrors it (`defaults/mces/<c>/{values,values-<env>,values-<mce>}.yaml`
at 5–7). The hub stays minimal: `operators/<c>/values.yaml` →
`defaults/hub/<c>/values.yaml`; hub values never leak into fleet apps and
vice versa (guarded by the `hub: true` flag).

Mnemonic: **generic → versioned → geographic → fleet-default → specific.**
The most context-specific file always wins.

## 4. Version management

### 4.1 One key: `ocpVersion`

A destination's `ocpVersion` selects layer 2 of both stacks. Upgrading a
cluster's OCP = one-line diff in its config.yaml; every chart app on it
re-renders against the new `ocp-<v>` layers. Nothing moves, nothing renames,
nothing syncs by itself.

### 4.2 Chart versions: frozen branches + pin files

Each chart repo cuts a **branch per release** (`2.1.2`, `2.1.4`, …); Argo's
`targetRevision` resolves branch names like tags. The discipline that makes
this safe: **a version branch is frozen at creation**. A fix is a *new*
branch (`2.1.5-hotfix`) cut from the old one — never a push to an existing
version branch, because a moved branch silently changes what every pinned
cluster deploys, with no MR in the day2 repo. The day2 pin files must remain
the single audit trail.

Three pin levels, lowest → highest (each is one line in one file):

```yaml
# operators/ako/ako.yaml                      — team default
targetRevision: "2.1.2"
# operators/ako/versions/ocp-4.20/ako.yaml    — the per-stream matrix (the fleet op)
targetRevision: "2.1.4"
# sites/<site>/<env>/mces/<mce>/<cluster>/ako/ako.yaml — per-cluster emergency pin
targetRevision: "2.1.5-hotfix"
```

`git log` on the stream file *is* the version history of that chart on that
stream.

### 4.3 Version-agnostic charts (the majority) cost nothing

`kyverno` and `cluster-roles` track `main`; `bmhgen` pins nothing at all.
For charts like these you never create a `versions/` folder: the `ocp-<v>`
slots are emitted for every chart on every render, and an absent folder
resolves to nothing. A cluster OCP upgrade produces **zero diff** for them.

The two axes — branch pinning and per-OCP values — are independent per chart:

| Chart branch | Per-OCP values | What exists in `versions/ocp-<v>/` |
|---|---|---|
| tracks `main` | none | nothing — no folder at all |
| tracks `main` | needed | `values.yaml` only |
| pinned per stream | none | `<chart>.yaml` only |
| pinned per stream | needed | both files |

Escalating later is additive: a chart breaks on 4.22 → add
`versions/ocp-4.22/<chart>.yaml` with a pin; only 4.22 destinations pick it
up. Reverting = deleting that file.

Trade-off of `main`-tracking: for those charts the chart repo's `main` is
the audit trail, not a day2 pin — any push makes every leaf app OutOfSync,
and the next sync ships whatever `main` holds. Where that matters, cutting a
branch and pinning costs one line.

### 4.4 ⚠️ Two precedence footguns

1. **Defaults configs override stream pins.** `defaults/*/<c>/<c>.yaml` is
   layer 3; `versions/` is layer 2. A `targetRevision` in a defaults config
   (like `dhcp-api-token`'s `main` today) silently wins over every stream
   pin. Rule: defaults configs carry `repourl`/`projectNamespace`/
   `syncPolicy`; pins live in `operators/`.
2. **Add the layer before flipping the version.** If `versions/ocp-4.20/`
   doesn't exist for a *pinned* chart when a cluster flips to `"4.20"`, the
   slot resolves to nothing and the cluster silently falls back to the team
   default. Ignore-missing can't tell "no layer needed" from "layer
   forgotten" — that's the price of §4.3 being free. Add the stream files
   first, then flip; confirm with the render check.

## 5. Labels — the fleet-operations enabler

Every generated Application carries:

```yaml
day2.gitops/team: redbull
day2.gitops/env: prod              # ┐ from the sites/ path
day2.gitops/site: site1            # ┘
day2.gitops/mce: ocp4-prod-mce-site1-a
day2.gitops/cluster: ocp4-prod-herzi-site1
day2.gitops/chart: cluster-roles   # chart-level apps and below
day2.gitops/ocp-version: "4.16"    # the DESTINATION's version (in-cluster apps: the MCE's)
day2.gitops/role: hosted-cluster   # hub | mce | hosted-cluster
```

Hub apps carry only team/chart/`role: hub` (prod-hub is version-less and
outside the sites tree). Fleet operations become one selector:

```bash
argocd app list -l day2.gitops/env=prod,day2.gitops/chart=ako
argocd app sync -l day2.gitops/chart=ako,day2.gitops/ocp-version=4.20
argocd app sync -l day2.gitops/cluster=ocp4-prod-herzi-site1
```

Labels are per-Argo: MCE-scoped selectors run against that MCE's Argo,
hub-scoped against prod-hub. A bare `ocp-version=4.20` sweeps MCE hubs *and*
hosted clusters together — add `day2.gitops/role` to hit only one kind.

## 6. The safety model — why changes are survivable

1. **App names are built from folder basenames only.** No path level above
   the basename ever appears in a name. Moving a folder (in one commit)
   presents the same app name with new parameters → the controller updates
   the app **in place**. Nothing is deleted or recreated. This is why the
   whole migration was possible with zero impact.
2. **No resources finalizers.** If a generator entry does disappear, only
   the Application CR is deleted — the deployed workloads are **orphaned in
   place, still running**, not torn down. When a same-named app reappears it
   re-adopts them cleanly. Worst case is cruft, never an outage.
3. **Leaf apps are manual-sync by default.** Platform layers self-heal (spec
   changes propagate alone), but workloads move only when an operator syncs
   — per app, or in bulk by label. (Exception: a chart's own config can opt
   into auto-sync; today only `dhcp-api-token` does.)
4. **THE ONE INVARIANT:** at any commit, each MCE / cluster / chart is
   emitted by exactly one generator entry. All the working rules derive from
   it: one-commit `git mv`, never copy-then-delete, the defaults XOR rule (a
   chart lives in a defaults folder OR a specific folder, never both),
   add-glob-before-remove ordering during migrations.
5. **Verify before merge — there is no after.** Platform apps self-heal, so
   a wrong render syncs immediately. The offline harness
   (`tools/render-verify/render_chain.py`) simulates the entire chain:

   ```bash
   python3 tools/render-verify/render_chain.py snapshot --out /tmp/before   # on main
   # ...apply your change...
   python3 tools/render-verify/render_chain.py snapshot --out /tmp/after
   python3 tools/render-verify/render_chain.py compare /tmp/before /tmp/after
   ```

   `compare` fails hard if any app's identity (name, destination,
   releaseName, syncPolicy, repo/branch) or its *resolved value-file
   contents* changed. It also lints: quoted versions, env ∈
   {prod,prep,test}, duplicate app names, leftover `{{...}}` placeholders,
   the frozen namespace line. Structural changes must end `IDENTITY OK`;
   deliberate changes (pins, values) must show **only** the diffs you
   intended, on the apps you intended.

---

# Part III — Runbooks

### R1. Upgrade a hosted cluster (OCP)

```diff
  # sites/site1/prod/mces/ocp4-prod-mce-site1-a/ocp4-prod-herzi-site1/config.yaml
- ocpVersion: "4.16"
+ ocpVersion: "4.20"
```

1. **Before flipping:** for every *pinned* chart on that cluster, make sure
   `operators/<chart>/versions/ocp-4.20/` exists (footgun §4.4-2).
   `main`-tracking charts need nothing.
2. Merge the one-line MR. Every chart app of that cluster re-renders with
   the `ocp-4.20` layers and its `ocp-version` label flips. **Nothing syncs
   by itself** — apps go OutOfSync and wait for you.
3. Roll out: `argocd app sync -l day2.gitops/cluster=ocp4-prod-herzi-site1`
   (or chart by chart).
4. Rollback: revert the commit.

Blast radius: that one cluster. (Verified by dry-run in the mock: 3 apps
touched, zero workload diff for `main`-tracking charts.)

### R2. Upgrade an MCE (OCP)

The same one-line edit, one level up:
`sites/<site>/<env>/mces/<mce>/config.yaml`. The MCE's in-cluster charts
re-pin to the new stream; **hosted clusters under it do not change** — they
carry their own `ocpVersion`. (Both properties verified by dry-run.)

### R3. Upgrade a chart

| Scope | Edit | Roll out with |
|---|---|---|
| One OCP stream — the normal fleet op | `operators/<c>/versions/ocp-4.20/<c>.yaml` → `targetRevision: "2.1.5"` | `argocd app sync -l day2.gitops/chart=<c>,day2.gitops/ocp-version=4.20` |
| Team default (everything without a higher pin) | `operators/<c>/<c>.yaml` | by label, as broad or narrow as you want |
| One cluster (emergency) | `sites/.../<cluster>/<c>/<c>.yaml` | `argocd app sync <team>-<cluster>-<c>-deploy` |

- The pin value is a **frozen branch name** in the chart's repo (§4.2). Ship
  a fix as a new branch + new pin, never a force-push.
- Before a stream upgrade, find clusters with their own emergency pin — they
  will *not* move with the stream:
  `grep -rl targetRevision sites/*/*/mces/*/*/<c>/`
- Rollback: revert the pin file.

### R4. Add a new chart to one cluster

```
sites/<site>/<env>/mces/<mce>/<cluster>/<chart>/
├── <chart>.yaml     # repourl (lowercase!), targetRevision, projectNamespace, syncPolicy...
└── values.yaml
```

Optionally create the team-wide base `operators/<chart>/` first — then the
cluster file holds only overrides. The new folder becomes
`<team>-<cluster>-<chart>` + its `-deploy` leaf; nothing else changes.
Chart on an MCE hub: same, under `<mce>/in-cluster/<chart>/` — **unless** it
already exists in `defaults/mces/` (XOR rule).

### R5. Add a chart to a whole fleet

Pick the audience — `defaults/hub/` (prod-hub), `defaults/mces/` (every MCE
hub), or `defaults/hosted-clusters/` (every hosted cluster). One folder, two
files; optional `values-<env>.yaml` / `values-<mce|cluster>.yaml` siblings
for per-scope tuning. Rules: XOR with specific folders; no `targetRevision`
here if the chart should follow stream pins (§4.4-1); before the first-ever
hub chart, check the AppProject permits destination `in-cluster` + the
target namespace.

Migrating an already-duplicated chart into defaults: **move** all its
per-cluster copies into the defaults folder in one commit (common values in
`values.yaml`, per-scope diffs in `values-<x>.yaml`). Same template + same
basename ⇒ byte-identical app, updated in place. Render-verify it.

### R6. Add a new hosted cluster

Precondition: the cluster is registered in the MCE's Argo under the exact
name the folder will have (basename == Argo cluster name, convention
`ocp4-<env>-<name>-<site>`).

```
sites/<site>/<env>/mces/<mce>/<new-cluster>/
├── config.yaml          # ocpVersion: "4.20"  (quoted!)
└── <chart>/...          # its charts — or nothing: defaults/hosted-clusters apply automatically
```

The moment config.yaml merges, the cluster exists: `<team>-<new-cluster>`
appears, plus one chart app per folder **plus** one per
`defaults/hosted-clusters/` chart. The team's AppProject already exists on
every cluster.

### R7. Add a new MCE / env / site

The tree is uniform — same shape, one level up:

```
sites/<site>/<env>/mces/<new-mce>/
├── config.yaml          # ocpVersion of the MCE itself
└── in-cluster/          # optional; defaults/mces charts apply automatically
```

A new env is a new folder under the site — it **must** be `prod`, `prep` or
`test` (the render check enforces this). A new site is a new folder under
`sites/`. Nothing to register in the platform; the globs match any
site/env.

### R8. Decommission / temporary removal

Deleting a chart folder (or a cluster's config.yaml) deletes the generated
Application CRs but **orphans the workloads in place** — they keep running,
unmanaged. Re-adding the same-named folder re-adopts them. For a true
teardown, delete the Applications with cascade first, then remove the
folders. Exception: `dhcp-api-token` sets `prune: true` itself — deleting
its folder removes the Secret on every MCE.

### R9. Find things

```bash
# which clusters run 4.16
grep -rl 'ocpVersion: "4.16"' sites/
# everything prod on site1 running ako
argocd app list -l day2.gitops/env=prod,day2.gitops/site=site1,day2.gitops/chart=ako
# the full version history of a chart on a stream
git log --oneline -- operators/ako/versions/ocp-4.20/
```

---

# Part IV — Reference

## Invariants checklist (print this)

- Folder basename == Argo cluster name. Always.
- `ocpVersion` always quoted. `config.yaml` = ocpVersion only.
- One `git mv` per move, one commit. Never copy-then-delete.
- XOR: a chart lives in a defaults folder OR a specific folder. Never both.
- `repourl` all-lowercase in deploy configs.
- Version branches are frozen; a fix is a new branch.
- Pins live in `operators/`; defaults configs never carry `targetRevision`
  (unless deliberately, like dhcp-api-token).
- Add `versions/ocp-<v>/` files **before** flipping a cluster to `<v>`.
- The `namespace: gitops-{{ .Values.repository }}` line is frozen.
- Render-verify before every merge: `IDENTITY OK` or it doesn't ship.

## Glossary

| Term | Meaning |
|---|---|
| prod-hub | the top management cluster; runs the `groups` appset |
| MCE | a hub cluster managing hosted clusters; runs its own Argo |
| hosted cluster / spoke | a leaf cluster where workloads run |
| `in-cluster` | every Argo's name for the cluster it runs on |
| Application | Argo's "deploy this chart there" object |
| ApplicationSet / appset | template + generator that stamps out Applications from git content |
| files / directories generator | "one app per matching file" / "per matching directory" |
| leaf app | `<team>-<cluster>-<chart>-deploy` — the app that deploys the actual workload |
| deploy config | `<chart>.yaml` — repo/branch/namespace/sync settings for a chart |
| slot | a value-file path that is always listed but may not exist (`ignoreMissingValueFiles`) |
| stream | an OCP minor version line (4.16, 4.20, ...) as a fleet-management unit |
| pin | a `targetRevision` line selecting a frozen chart branch |
| XOR rule | defaults folder OR specific folder — never both |
| THE ONE INVARIANT | each MCE/cluster/chart emitted by exactly one generator entry, at every commit |
| frozen line | the `gitops-{{ .Values.repository }}` namespace line — never touch |
