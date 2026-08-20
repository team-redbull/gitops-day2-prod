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
something, and a one-line file edit is how you upgrade something** — a chart
version here, a cluster's OCP version in the day1 repo. Argo CD watches the
repos and turns folders into running applications.

## The one sentence to remember

> **Folders say WHERE things run. The day1 repo says WHICH VERSION runs
> there.**

- Where = the `sites/` tree: `sites/<site>/<env>/mces/<mce>/<cluster>/`.
  A cluster's site and environment never change, so they live in the path.
  The folder's *existence* is the entire opt-in — there is no file to add.
- Which OCP version = the **day1** repo (`gitops-day1/platform-config`) —
  the repo that provisioned the cluster and owns its version as one line,
  `mastertag`. Argo resolves it at render time; no sig repo declares it.
- Which *chart* version = one line in a pin file, in your team repo (§4.2).

That's the core design decision. Upgrading a cluster or a chart is a one-line
merge request — never moving folders around. And because every sig renders
the OCP version from that same day1 file, one edit upgrades a cluster for all
of them at once.

## What was wrong before

The old repo was a flat list of MCEs. It worked, but:

- **You couldn't see prod vs prep.** Environment and site were only hidden
  inside folder names like `ocp4-prep-mce-site1-a`. "Upgrade all prod" meant
  reading names and hoping.
- **Versions didn't exist.** Nothing connected a cluster to the OCP version
  it runs, or told you which chart version is right for which OCP version.
  That knowledge lived in people's heads. (Today the cluster half is answered
  by the day1 repo, the chart half by `versions/ocp-<v>/`.)
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
| upgrade a cluster to OCP 4.20.9 | edit one line in the **day1** repo: `mastertag: 4.20.9-x86_64` — one edit, every sig |
| upgrade a chart on all 4.20.9 clusters | edit one line in `operators/<chart>/versions/ocp-4.20.9/<chart>.yaml` |
| deploy a chart to ONE cluster | add a folder with 2 files under that cluster |
| deploy a chart to EVERY hosted cluster | add a folder with 2 files under `defaults/hosted-clusters/` |
| add a new cluster | create its folder — that's all (day1 already knows its version) |
| sync everything prod | `argocd app sync -l day2.gitops/env=prod` |
| see which clusters run 4.16.27 | one `grep` in the day1 repo |

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
- **The day1 repo** (`gitops-day1/platform-config`) — the repo that
  *provisions* the clusters, and therefore owns their OCP versions
  (`mastertag`). Day2 reads it at render time and never writes to it. It is
  the one place a cluster's version is written for all five sig repos.
- **Chart repos** (`helm-charts/<chart>`) — the real workload helm charts,
  one repo each, one **frozen branch per release**.

## The story of one chart (follow this once, slowly)

Say `sigs/redbull/sites/site1/prod/mces/ocp4-prod-mce-site1-a/ocp4-prod-herzi-site1/cluster-roles/`
exists, with `cluster-roles.yaml` and `values.yaml` inside. How does that
become a running chart on the herzi cluster?

1. **prod-hub** discovers the team: the `groups` appset scans GitLab, finds
   `sigs/redbull`, and creates one app that renders the platform's `mces`
   chart for redbull.
2. That chart contains an appset that lists the **directories** matching
   `sites/*/*/mces/*` in the team repo. The MCE's folder is one, so it
   creates the app `redbull-ocp4-prod-mce-site1-a` — which renders the
   platform's `clusters` chart **onto the MCE's own Argo**, passing along the
   MCE's path, site (`site1`) and env (`prod`), plus a second, value-only
   source pointing at the **day1** repo, so that the MCE's `mastertag`
   arrives with it.
3. On the MCE, that chart's appset lists the directories inside the MCE
   folder (everything but `in-cluster/`), finds `ocp4-prod-herzi-site1/`, and
   creates `redbull-ocp4-prod-herzi-site1` — which renders the `operators`
   chart, now with the day1 pointer aimed at the *cluster's* own version
   file.
4. The `operators` appset derives `ocpVersion: 4.16.27` from that
   `mastertag`, then lists the directories in the cluster's folder. It finds
   `cluster-roles/` and creates `redbull-ocp4-prod-herzi-site1-cluster-roles`
   — which renders the `deploy` chart, merging the chart's config files
   (which repo? which branch? which namespace?) from lowest to highest
   priority.
5. The `deploy` chart renders the final leaf:
   `redbull-ocp4-prod-herzi-site1-cluster-roles-deploy` — an Application
   pointing at the actual `helm-charts/cluster-roles` repo, destination
   `ocp4-prod-herzi-site1`, with the merged values. An operator syncs it
   (leaf apps don't auto-sync), and the chart runs.

Notice what did the work: **a folder made a cluster count as a cluster; a
directory made a chart exist there; the day1 repo said which OCP version to
build the value paths from.** No exclude lists, no registries, no
registration files. Files are never scanned by the cluster-discovery steps,
only directories — so a `values.yaml` next to a cluster folder is invisible
to them, and the one directory that must not count (`in-cluster/`) is
excluded by name in one place.

And notice that nothing in step 2 or 3 could have matched at the wrong depth:
a `directories:` glob is matched one path segment at a time, so
`sites/*/*/mces/*` cannot reach down to the herzi cluster. That guarantee used
to be carried by a naming convention — two marker files that had to be named
differently — and is now carried by the matching engine itself. §2.1 explains
why the difference was worth a production incident.

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
│       │       └── ocp4-prep-mce-site1-a/    # ← this FOLDER is the MCE (version: day1)
│       │           ├── values.yaml     # optional MCE-wide values (slot) — not a marker
│       │           ├── in-cluster/     # charts on the MCE hub itself
│       │           │   ├── bmhgen/{bmhgen.yaml, values.yaml}
│       │           │   └── kyverno/{kyverno.yaml, values.yaml}
│       │           ├── ocp4-prep-eyal-site1/ # ← this FOLDER is a hosted cluster
│       │           │   └── cluster-roles/{cluster-roles.yaml, values.yaml}
│       │           └── ocp4-prep-itay-site1/...
│       └── prod/mces/ocp4-prod-mce-site1-a/...
├── operators/                          # WHAT can run — per-chart, team-wide defaults
│   ├── cluster-roles/{cluster-roles.yaml, values.yaml}
│   ├── kyverno/...
│   └── <chart>/versions/ocp-<v>/{<chart>.yaml, values.yaml}  # only version-sensitive charts
│                                       # <v> = the FULL version, e.g. ocp-4.16.27
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
  `sites/*/*/mces/*` confines MCE discovery to that subtree, and keeps the
  env level free for future siblings. Envs are a closed set
  (`prod|prep|test`) and the only children of a site — a wrapper would only
  add depth. (The literal segment bounds the *subtree*; the `*`s bound the
  *depth*, because a `directories:` glob is matched segment by segment.
  That used to take a naming convention instead — §2.1.)
- **A folder that would otherwise be empty needs a `.gitkeep`.** git tracks
  files, not directories: an MCE or cluster onboarded before it has any
  charts or values of its own does not exist in git at all, and therefore
  produces no app. §1.1.
- **`example-chart` folders are convention demos.** Never ship them to prod.

### 1.1 The folder IS the registration — and day1 owns the version

```
sites/<site>/<env>/mces/<mce>/             ← this folder existing makes it an MCE
sites/<site>/<env>/mces/<mce>/<cluster>/   ← this folder existing makes it a hosted cluster
```

There is no registration file, no marker, and no key to fill in. Every
directory under `sites/*/*/mces/` is an MCE; every directory inside one is a
hosted cluster, except `in-cluster/`, which is excluded by name (it is the
MCE hub itself, and it is reached by a different template). Both discovery
generators are `directories:` generators, whose `*` matches exactly one path
segment — so the depth of each level is enforced by the matching engine, not
by a naming convention (§2.1).

**Where the OCP version comes from.** It is not declared in this repo at all.
Argo resolves it at render time from the **day1** repo
`gitops-day1/platform-config` — the repo that provisioned the cluster, and
therefore the one that knows what it runs:

| the day2 folder | the day1 file that owns its version |
|---|---|
| `sites/<site>/<env>/mces/<mce>` | `sites/<site>/mces/<mce>/version.yaml` |
| `sites/<site>/<env>/mces/<mce>/<cluster>` | `sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml` |

```yaml
# gitops-day1/platform-config/sites/site1/mces/ocp4-prod-mce-site1-a/version.yaml
mastertag: 4.16.27-x86_64
```

Three things to internalise about that mapping:

- **The day1 tree has no `<env>` level.** Environment lives only inside the
  cluster's name (the `prod` in `ocp4-prod-mce-site1-a`), so translating a
  day2 path into a day1 path means dropping the `<env>` segment. Site and MCE
  names match exactly.
- **A hosted cluster's folder name equals its day1 file name minus `.yaml`.**
  That equality is the join key — and it is the same basename that is already
  the Argo cluster name, so there is nothing new to keep in sync.
- **The two files are not the same kind of thing.** `hostedClusters/<hc>.yaml`
  is day1's own provisioning input: day2 reads the tag day1 actually installed,
  so the value cannot drift from reality. `version.yaml` is day2-owned — day1's
  charts never consume it — and describes the MCE hub itself. Nothing
  provisions or verifies a hub's version, so that one is a hand-maintained
  assertion: whoever upgrades an MCE must edit it. It exists as its own file
  precisely so it does not sit in the MCE's `values.yaml`, where `mastertag`
  already means *day1's default version for the hosted clusters under this
  MCE* — the same key, a different fact. It must carry `mastertag` and nothing
  else; any other key in it lands as a day2 chart value.

Why day1 rather than here: the air-gap runs **five sig repos**, and the same
physical cluster appears in all five. Its version used to be written five
times, and drifted. Now a cluster is upgraded once, in the repo that actually
upgrades it, and every sig re-renders against the new value.

**Two caveats that come with folder-existence discovery:**

1. **git cannot track an empty folder.** A cluster or MCE onboarded before it
   has any content of its own — no chart folders, no `values.yaml` — will not
   exist in git, and so produces no Application. Drop a `.gitkeep` in it and
   it is real.
2. **A stray folder becomes a phantom Application.** Anything you put under
   an MCE folder that is not a cluster gets an app whose `destination.name`
   is a cluster that does not exist — and the same applies one level up, to a
   stray folder directly under `sites/<site>/<env>/mces/`. This is caught
   offline before merge: a stray folder has no day1 version file, so the
   render check's day1-parity lint names the folder and says exactly that
   (§6-5), at both levels. Files are safe — only directories are scanned.

The marker files `mce.yaml` / `hc.yaml` that used to sit in these folders are
**gone**. They existed only to carry `ocpVersion`; once the version moved to
day1 there was nothing left for them to carry, so they were deleted rather
than emptied. If per-cluster *platform* metadata is ever needed (maintenance
windows, canary flags, pause switches), it comes back as a value-file **slot**
that the templates list explicitly — not as a discovery marker. Discovery
stays on directories.

env/site are **never** written in a file — the platform reads them from the
path (`path[1]` = site, `path[2]` = env) and passes them down as values.

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

Argo offers two git generator types; the platform uses **only one of them**:

- **git directories generator** — "one Application per *matching directory*".
  Path parameters only: `{{path}}`, `{{path.basename}}`, `{{path[n]}}`.
  Every discovery step in the chain is one of these — MCEs, hosted clusters,
  chart folders, defaults folders.
- **git files generator** — "one Application per *matching file*". Same path
  parameters **plus every key inside the file**. The platform no longer uses
  it anywhere: the only thing it was ever used for was carrying `ocpVersion`
  out of a marker file, and that value now comes from the day1 repo through a
  value file instead. Read §2.1 before you reach for one.

Parameters are substituted into the appset's template text; the result is an
Application. The two generators do **not** interpret `*` the same way — read
§2.1 before you write or edit a glob.

The full chain (each row renders the next):

| Layer | Template | Generator | Emits | Runs on |
|---|---|---|---|---|
| groups | `groups/templates/groupsAppset.yaml` | scmProvider (GitLab group) | App `<team>` → platform `mces` chart | prod-hub |
| mces | `mces/templates/mcesAppset.yaml` | **dirs**: `sites/*/*/mces/*` | App `<team>-<mce>` → `clusters` chart, destination = the MCE; passes `mce`, `mcePath`, `env`, `site` + a `$day1` value file = the MCE's `mastertag` | prod-hub |
| app-projects | `mces/templates/appProjectAppset.yaml` | clusters (all) | AppProject `<team>` on every cluster (sync-wave −1) | prod-hub |
| hub charts | `mces/templates/inClusterAppset.yaml` | dirs: `defaults/hub/*` | App `<team>-in-cluster-<chart>` → `deploy` chart in hub mode | prod-hub |
| clusters | `clusters/templates/clustersAppset.yaml` | **dirs**: `<mcePath>/*`, minus `<mcePath>/in-cluster` | App `<team>-<cluster>` → `operators` chart + a `$day1` value file = **this cluster's** `mastertag`, and a `$values` one = `defaults/hosted-clusters/exclusions.yaml` (§2.2) | the MCE |
| — static | `clusters/templates/inClusterApp.yaml` | none (always rendered) | App `<team>-in-cluster` → `operators` chart with `cluster: in-cluster`; passes the **MCE's** `mastertag` down inline, plus a `$values` value file = `defaults/mces/exclusions.yaml` (§2.2) | the MCE |
| operators | `operators/templates/operators.yaml` | dirs ×3: `<clusterPath>/*`; `defaults/mces/*` (in-cluster only); `defaults/hosted-clusters/*` (hosted only). Each defaults generator also carries `exclude:` entries built from `.Values.exclusions` — the structural opt-out (§2.2) | App `<team>-<cluster>-<chart>` → `deploy` chart | the MCE |
| deploy | `deploy/templates/deployApp.yaml` | — | App `<team>-<cluster>-<chart>-deploy` = **the workload**, destination `name: <cluster>` | the MCE |

Three details carry the whole design:

- **The version enters through a second source, twice.** The per-MCE and
  per-hosted-cluster Applications are **multi-source** apps: alongside the
  platform chart they declare a value-only source for the day1 repo, and add
  one `$day1/...` entry to the chart source's `valueFiles`.

  ```yaml
  sources:
    - repoURL: '.../argocd-day2-platform.git'
      path: operators
      helm:
        ignoreMissingValueFiles: true
        valueFiles:                      # <site>/<mce> are chart values here
          - '$day1/sites/<site>/mces/<mce>/hostedClusters/{{path.basename}}.yaml'
    - repoURL: '.../gitops-day1/platform-config.git'
      targetRevision: main
      ref: day1
  ```

  That is the `clusters` layer; the `mces` layer above it points at
  `$day1/sites/<site>/mces/<mce>/version.yaml` the same way. Either way the
  next chart in the chain renders with `.Values.mastertag` set. (Whatever
  else the day1 file holds —
  `dhcp_values`, for instance — is inert: nothing downstream reads it, and
  the inline `values:` block outranks it anyway, since Argo applies
  `helm.values` after `valueFiles`.)
- **The version is derived once, in exactly two templates.**
  `clusters/templates/inClusterApp.yaml` (for the MCE hub) and
  `operators/templates/operators.yaml` (for everything else) both open with:

  ```gotemplate
  {{- $mastertag := required "mastertag missing: ..." .Values.mastertag | toString -}}
  {{- $ocpVersion := $mastertag | splitList "-" | first -}}
  ```

  Strip the architecture at the first `-` and use the rest **verbatim**:
  `4.16.27-x86_64` → `4.16.27`. Nothing is truncated to a minor line. The
  static in-cluster app deliberately passes the **raw `mastertag`** down to
  the operators chart rather than its derived value, so there is exactly one
  derivation rule in the chain. And `required` means a missing day1 entry is
  a loud render failure, not a silently version-less deploy. Net effect is
  what it always was: MCE-hub charts version by the MCE's OCP version,
  hosted-cluster charts by their own — one rule, no special cases.
- **Only `mcesAppset.yaml` knows the tree layout.** Every other template
  receives the generator's `{{path}}` as `mcePath`/`clusterPath` values and
  builds all file paths from them. A future layout change touches one file.
  Knowledge of day1 is just as narrow: two templates reach into its tree
  (`mcesAppset`, `clustersAppset`) and two derive a version from what they
  resolve (`inClusterApp`, `operators`). Nothing else in the chain knows the
  day1 repo exists.

**The frozen line.** The template line
`namespace: gitops-{{ .Values.repository }}` in `mcesAppset.yaml` and
`appProjectAppset.yaml` renders as `gitops-` (the value is never set). It is
wrong, known, and **deliberately frozen**: a generated app's namespace is
part of its identity — "fixing" it would delete and recreate every app in
the fleet. Leave it byte-identical, always.

### 2.1 `*` means two different things (read before touching a glob)

The two generators are matched by two different engines, and only one of them
is depth-exact:

| Generator | Matched by | Does `*` cross `/`? |
|---|---|---|
| `directories:` | Go `path.Match`, in the appset controller | **No** — exactly one path segment |
| `files:` | `git ls-files -- <pattern>` on the repo-server | **Yes** — matches at any depth |

A `files:` glob is a **git pathspec**, and git matches pathspecs with
wildmatch *without* `WM_PATHNAME`, so `*` happily eats slashes. Verify any
glob yourself, with the same command Argo runs — here against the marker-file
layout that used to be in the repo:

```console
$ git ls-files -- 'sites/*/config.yaml'      # in a clone of the team repo
sites/site1/prod/mces/ocp4-prod-mce-site1-a/config.yaml                        # meant this
sites/site1/prod/mces/ocp4-prod-mce-site1-a/ocp4-prod-herzi-site1/config.yaml  # got this too
```

**This is why cluster discovery is a `directories:` generator.** Depth cannot
be expressed in a `files:` glob at all, so `sites/*/*/mces/*` as a
`directories:` pattern is depth-exact for free: `*` stops at `/`, therefore it
matches an MCE folder and can never reach a hosted cluster one level below.
The property comes from the **engine**, and an engine cannot be forgotten
during a review.

That was not always so, and the difference cost an outage:

> **The Phase B production incident.** Discovery used to be a `files:`
> generator anchored on a marker file, and both levels used the same filename,
> `config.yaml`. Because `*` crosses `/` in a git pathspec, `mcesAppset`
> matched every hosted cluster's file too and emitted an Application whose
> `destination.name` was a hosted cluster — Argo answered *"there are no
> clusters with this name"* for each one. The first fix was to make depth a
> property of the *filename*: `mce.yaml` for MCEs, `hc.yaml` for hosted
> clusters, never the same name at two depths. CHANGES.md §0 has the full
> write-up.

Those marker files are gone now, and with them the discipline they required.
The hazard is **avoided by construction rather than managed by convention**:
there is no discovery glob left whose correctness depends on what a file is
called. The teaching survives its own fix, because it applies to any `files:`
generator anyone adds later, for any purpose.

Argo *can* be told to match `files:` globs with depth-exact doublestar instead
(`applicationsetcontroller.enable.new.git.file.globbing: "true"`). We
deliberately never relied on it: it defaults to off, and `clustersAppset` runs
on **every MCE's** Argo, so the whole fleet — including every MCE onboarded in
the future — would have had to carry the flag forever. `directories:` needs no
cluster-side configuration and cannot silently regress.

`render_chain.py` models both engines and fails the pre-merge check on any
`files:` glob whose two readings differ, so this class of bug cannot reach a
merge request again. That guard is kept even though nothing matches it today.

### 2.2 The structural opt-out (`exclusions.yaml`)

A fleet default is absolute by construction: every chart folder in
`defaults/mces/` becomes an Application on **every** MCE hub, every folder in
`defaults/hosted-clusters/` on **every** hosted cluster. `exclusions.yaml` is
the one way to carve out a named set of exceptions.

One plain file per scope, keyed by chart, directly under the defaults folder —
where a `directories:` generator, which lists directories only, cannot see it:

```yaml
# sigs/<team>/defaults/mces/exclusions.yaml
exclusions:
  dhcp-api-token:
    - ocp4-prep-mce-site1-a
```

**Absent is the normal state.** Most teams never write either file; a repo
without one renders byte-for-byte what it rendered before the feature existed.

**Why it cannot live per chart.** The decision *"does this chart become an
Application here?"* is made by the `directories:` generator that
`operators.yaml` renders, and chart folder names are discovered from git at
**generator** time. `operators.yaml` is Helm, rendered by the repo-server
*before* any chart name exists: it sees Helm values plus `valueFiles` at
statically known paths, and has no git-listing primitive. (`goTemplate` is off
repo-wide, so the appset `template:` block is flat fasttemplate — no
conditionals there either.) So the data has to arrive as a value from **one
fixed path per scope**, resolved by the parent Application:
`clustersAppset.yaml` for hosted clusters, `inClusterApp.yaml` for MCE hubs —
which is why both now carry a `$values` ref source. A per-chart file is only
readable one layer lower, at `deploy`, where the app already exists.

The Helm layer turns each matching pair into an `exclude: true` entry in that
scope's generator — the same idiom `clustersAppset` already uses to drop
`in-cluster`. Three constraints on those entries, and they are why the code
looks the way it does:

1. They sit in the **same `git:` generator block** as the include glob. Argo
   computes `include && !exclude` **per generator**; an exclude in the sibling
   `<clusterPath>/*` generator is a silent no-op.
2. They match the include glob's output **byte-for-byte**.
   `defaults/mces/*` yields `defaults/mces/dhcp-api-token`; a deeper path
   removes nothing, silently.
3. The two defaults generators are an `if/else` pair, so an MCE never
   evaluates hosted-cluster exclusions and vice versa. No cross-scope leakage.

**Malformed input fails the render on purpose.** A frozen render deletes
nothing (§6-2), whereas silently ignoring a bad file would deploy a chart
somewhere someone asked it not to. But a *well-formed* file naming a chart or
a cluster that does not exist is **inert and completely silent** — that is what
`render_chain.py`'s exclusion lint catches before merge, in CI. Both name axes
need a rule because they fail differently: a wrong chart name emits an exclude
matching no folder, so the chart still deploys; a wrong cluster name matches no
destination, so no exclude entry is emitted at all.

**Exclusion is prevention, not teardown** — see runbook **R10**.

## 3. The two value stacks (how a chart gets its configuration)

Argo merges a list of value files in order — later files win per key — and
then applies the inline values last. Every file layer in our stacks is
declared with `ignoreMissingValueFiles: true`, so think of each layer as a
**slot, not a file**: a missing file quietly contributes nothing, and
creating it later is always a deliberate, scoped opt-in. Most slots are empty
today. That is the normal, intended state.

Every slot in both stacks lives in your **team** repo (`$values`). The one
day1 file in the chain is not part of them: it is resolved further up the
chain, by the per-MCE and per-cluster Applications, purely to supply `<v>`
(§2).

**Stack 1 — deploy config** (`<chart>.yaml` files; decides repo, branch,
namespace, sync policy), lowest → highest:

| # | Hosted cluster | MCE in-cluster | prod-hub |
|---|---|---|---|
| 1 | `operators/<c>/<c>.yaml` | same | same |
| 2 | `operators/<c>/versions/ocp-<v>/<c>.yaml` — `<v>` is the destination's own **full** version, from day1 (e.g. `ocp-4.16.27`) | same (`<v>` = the MCE's) | — (hub is version-less) |
| 3 | `defaults/hosted-clusters/<c>/<c>.yaml` | `defaults/mces/<c>/<c>.yaml` | `defaults/hub/<c>/<c>.yaml` |
| 4 | `<clusterPath>/<c>/<c>.yaml` | `<mcePath>/in-cluster/<c>/<c>.yaml` | — |

**Stack 2 — workload values** (`values.yaml` files; what the chart itself
sees), lowest → highest, hosted-cluster column in full:

| # | Layer | Scope |
|---|---|---|
| 1 | `operators/<c>/values.yaml` | chart, team-wide |
| 2 | `operators/<c>/versions/ocp-<v>/values.yaml` | chart, per exact OCP version |
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

### 4.1 One source: the day1 `mastertag`

A destination's OCP version is not declared in this repo. It is read at
render time from the day1 repo and derived by stripping the architecture:

```yaml
# gitops-day1/platform-config/sites/site1/mces/ocp4-prod-mce-site1-a/hostedClusters/ocp4-prod-herzi-site1.yaml
mastertag: 4.16.27-x86_64      # → ocpVersion 4.16.27
```

`ocpVersion` is that derived value, and it is the **full patch version** —
nothing is rounded to `4.16`. It selects layer 2 of both stacks
(`versions/ocp-4.16.27/`) and becomes the `day2.gitops/ocp-version` label.
There is still no separate "MCE version": an MCE hub is versioned by its own
day1 `mastertag` exactly like a hosted cluster (§1.1 maps folder → file) — but
from `version.yaml`, a day2-owned file, and that one value is hand-maintained
rather than provisioned (§1.1, third bullet).

Upgrading a cluster's OCP is a one-line diff in the **day1** repo; every chart
app on that cluster — in every sig repo — re-renders against the new `ocp-<v>`
layers. Nothing moves, nothing renames, nothing syncs by itself.

Because the key is a full patch version, the version layer changes on **every**
upgrade, z-stream bumps included. That is the sharp edge — §4.4-2.

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
# operators/ako/ako.yaml                        — team default
targetRevision: "2.1.2"
# operators/ako/versions/ocp-4.20.9/ako.yaml    — the per-version matrix (the fleet op)
targetRevision: "2.1.4"
# sites/<site>/<env>/mces/<mce>/<cluster>/ako/ako.yaml — per-cluster emergency pin
targetRevision: "2.1.5-hotfix"
```

`git log` on the version-layer file *is* the history of that chart on that
OCP version.

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
| pinned per version | none | `<chart>.yaml` only |
| pinned per version | needed | both files |

Escalating later is additive: a chart breaks on 4.22.3 → add
`versions/ocp-4.22.3/<chart>.yaml` with a pin; only destinations on exactly
that version pick it up. Reverting = deleting that file.

Trade-off of `main`-tracking: for those charts the chart repo's `main` is
the audit trail, not a day2 pin — any push makes every leaf app OutOfSync,
and the next sync ships whatever `main` holds. Where that matters, cutting a
branch and pinning costs one line.

### 4.4 ⚠️ Two precedence footguns

1. **Defaults configs override version pins.** `defaults/*/<c>/<c>.yaml` is
   layer 3; `versions/` is layer 2. A `targetRevision` in a defaults config
   (like `dhcp-api-token`'s `main` today) silently wins over every version
   pin. Rule: defaults configs carry `repourl`/`projectNamespace`/
   `syncPolicy`; pins live in `operators/`.
2. **Add the layer before day1 flips the tag — on EVERY upgrade.** Version
   layers are keyed by the full patch version, so `4.16.27 → 4.16.29` moves a
   destination off `versions/ocp-4.16.27/` exactly as surely as `4.16 → 4.20`
   once did. If the new folder doesn't exist for a *pinned* chart, the slot
   resolves to nothing and that cluster silently falls back to the team
   default. `ignoreMissingValueFiles` can't tell "no layer needed" from
   "layer forgotten" — that's the price of §4.3 being free.

   This got sharper with the move to day1, in two ways. **z-stream bumps are
   no longer exempt**: under the old `ocp-4.20` keying they changed nothing,
   and under full-version keying every one of them needs a new folder.
   And **the flip is not your merge request** — it lands in the day1 repo, and
   may be merged by someone who has never opened your sig. Create
   `versions/ocp-<new>/` first, in every sig that pins the chart, confirm with
   the render check against the new tag, and only then let day1 move.

## 5. Labels — the fleet-operations enabler

Every generated Application carries:

```yaml
day2.gitops/team: redbull
day2.gitops/env: prod              # ┐ from the sites/ path
day2.gitops/site: site1            # ┘
day2.gitops/mce: ocp4-prod-mce-site1-a
day2.gitops/cluster: ocp4-prod-herzi-site1
day2.gitops/chart: cluster-roles   # chart-level apps and below
day2.gitops/ocp-version: "4.16.27" # the DESTINATION's FULL version (in-cluster apps: the MCE's)
day2.gitops/role: hosted-cluster   # hub | mce | hosted-cluster
```

**Two layers deliberately have no `ocp-version`:** the per-MCE app
(`<team>-<mce>`) and the per-hosted-cluster app (`<team>-<cluster>`). Those
are the discovery layers, and they never learn the version — they only point
the next chart at the day1 file that holds it. Everything below them carries
it: the static `<team>-in-cluster` app, every chart-level app, and every
`-deploy` leaf. In practice that is the right split: a version selector picks
out the apps that actually deploy something on that version, and skips the two
plumbing layers, which is what you want when syncing.

Hub apps carry only team/chart/`role: hub` (prod-hub is version-less and
outside the sites tree). Fleet operations become one selector:

```bash
argocd app list -l day2.gitops/env=prod,day2.gitops/chart=ako
argocd app sync -l day2.gitops/chart=ako,day2.gitops/ocp-version=4.20.9
argocd app sync -l day2.gitops/cluster=ocp4-prod-herzi-site1
```

The version value is the **full** version — `ocp-version=4.20` matches
nothing. Labels are per-Argo: MCE-scoped selectors run against that MCE's
Argo, hub-scoped against prod-hub. A bare `ocp-version=4.20.9` sweeps MCE hubs
*and* hosted clusters together — add `day2.gitops/role` to hit only one kind.

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
   add-glob-before-remove ordering during migrations. The XOR rule has exactly
   one carve-out, and it does not weaken the invariant: a chart may sit in a
   defaults folder *and* in a specific cluster's folder **iff** that cluster
   is listed under it in `exclusions.yaml` (§2.2), which removes the fleet
   entry — so the name is still emitted once. Without the entry it is still a
   duplicate, and `render_chain.py` still fails on it.
5. **Verify before merge — there is no after.** Platform apps self-heal, so
   a wrong render syncs immediately. The offline harness
   (`tools/render-verify/render_chain.py`) simulates the entire chain:

   ```bash
   python3 tools/render-verify/render_chain.py snapshot --out /tmp/before   # on main
   # ...apply your change...
   python3 tools/render-verify/render_chain.py snapshot --out /tmp/after
   python3 tools/render-verify/render_chain.py compare /tmp/before /tmp/after
   ```

   `snapshot` needs a checkout of the **day1** repo — every destination's
   version is read from it. It defaults to `../gitops-day1/platform-config`
   next to this repo; override with `--day1 ROOT`. Without one it refuses to
   run rather than guess.

   `compare` splits every app's resolved value files by repo, because the two
   have opposite expectations:

   - the **sigs** sequence is **HARD** — a change there changes what a
     workload renders;
   - the **day1** sequence is **INFO** — that is precisely where versions are
     supposed to change;
   - the **control** sequence is **INFO** — the `defaults/<scope>/
     exclusions.yaml` matrices (§2.2), which decide whether an Application
     *exists* rather than what it renders. Their real effect lands as
     `APPS DISAPPEARED` on the two or three apps actually excluded; hashing
     them into the sigs sequence would instead raise a HARD diff on **every**
     app in the team for that same two-line change.

   Identity (name, destination, releaseName, syncPolicy, repo/branch) stays
   HARD, as do disappearing apps. A value-only `ref:` source is **not**
   identity — adding one (the day1 repo) must not read as an app being
   recreated — but *losing* one is HARD, because it breaks resolution.

   It also lints: env ∈ {prod,prep,test}, duplicate app names, leftover
   `{{...}}` placeholders, the frozen namespace line, depth-ambiguous `files:`
   globs, the four **exclusion rules** (§2.2 — schema, chart names, cluster
   names, no hub file), and — the new one — **day1 parity**: every MCE and hosted-cluster
   folder must have a day1 file carrying a `mastertag` matching
   `<major>.<minor>.<patch>[-<arch>]`. That lint is what turns a stray folder
   under an MCE into a pre-merge failure instead of a phantom Application
   (§1.1). A chart that refuses to render at all — `required` firing because
   day1 has no entry for a destination — is reported as a check failure like
   any other, not as a traceback.

   Structural changes must end `IDENTITY OK`; deliberate changes (pins,
   values) must show **only** the diffs you intended, on the apps you
   intended.

   The day1-version change itself was verified this way, and its shape is a
   good model of what "only the diffs you intended" looks like: **35 apps → 35
   apps, `IDENTITY OK`, zero HARD failures, nothing added or removed.** The
   INFO diffs were exactly three groups — the 6 discovery apps (2 MCE + 4
   hosted-cluster) gained the day1 ref source and its resolved file, lost
   their `ocp-version` label and changed their `valueFiles` list; 26 apps'
   `ocp-version` went `4.16` → `4.16.27` and `4.20` → `4.20.9`; and the
   version-pin slots became `versions/ocp-4.16.27` / `versions/ocp-4.20.9`.

---

# Part III — Runbooks

### R1. Upgrade a hosted cluster (OCP)

The edit is **in the day1 repo**, not here — nothing changes in `sites/`:

```diff
  # gitops-day1/platform-config/sites/site1/mces/ocp4-prod-mce-site1-a/hostedClusters/ocp4-prod-herzi-site1.yaml
- mastertag: 4.16.27-x86_64
+ mastertag: 4.20.9-x86_64
```

1. **Before day1 flips it:** for every *pinned* chart on that cluster, create
   `operators/<chart>/versions/ocp-4.20.9/` — in **every sig repo** that
   deploys that chart there (footgun §4.4-2; z-stream bumps too, since the
   key is the full version). `main`-tracking charts need nothing. Render-verify
   against the new tag before day1 moves.
2. Merge the one-line day1 MR. Every chart app of that cluster — again, in
   every sig — re-renders with the `ocp-4.20.9` layers and its `ocp-version`
   label flips. **Nothing syncs by itself** — apps go OutOfSync and wait for
   you.
3. Roll out: `argocd app sync -l day2.gitops/cluster=ocp4-prod-herzi-site1`
   (or chart by chart).
4. Rollback: revert the day1 commit.

Blast radius: that one cluster — but across every sig that deploys to it. The
coordination now happens *before* the merge, in the day1 MR, not after. (The
shape was verified by dry-run in the mock: only that cluster's own apps
re-render, and `main`-tracking charts show zero workload diff.)

### R2. Upgrade an MCE (OCP)

The same one-line edit, one file up in the day1 tree:
`sites/<site>/mces/<mce>/version.yaml` — note there is no `<env>` segment on
the day1 side (§1.1), and note this is *not* the MCE's `values.yaml` beside it.
Unlike a hosted cluster's, this value is not written by whatever upgraded the
hub, so it is the one version in the fleet a human must remember to bump. The MCE's in-cluster charts re-pin to the new version;
**hosted clusters under it do not change** — each resolves its own day1 file,
so the isolation is structural, not a convention. Nothing moves in `sites/`
either way. (Both properties verified by dry-run.)

### R3. Upgrade a chart

| Scope | Edit | Roll out with |
|---|---|---|
| One OCP version — the normal fleet op | `operators/<c>/versions/ocp-4.20.9/<c>.yaml` → `targetRevision: "2.1.5"` | `argocd app sync -l day2.gitops/chart=<c>,day2.gitops/ocp-version=4.20.9` |
| Team default (everything without a higher pin) | `operators/<c>/<c>.yaml` | by label, as broad or narrow as you want |
| One cluster (emergency) | `sites/.../<cluster>/<c>/<c>.yaml` | `argocd app sync <team>-<cluster>-<c>-deploy` |

- The pin value is a **frozen branch name** in the chart's repo (§4.2). Ship
  a fix as a new branch + new pin, never a force-push.
- Before a version-layer upgrade, find clusters with their own emergency pin
  — they will *not* move with the layer:
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
here if the chart should follow version pins (§4.4-1); before the first-ever
hub chart, check the AppProject permits destination `in-cluster` + the
target namespace.

Migrating an already-duplicated chart into defaults: **move** all its
per-cluster copies into the defaults folder in one commit (common values in
`values.yaml`, per-scope diffs in `values-<x>.yaml`). Same template + same
basename ⇒ byte-identical app, updated in place. Render-verify it.

### R6. Add a new hosted cluster

Two preconditions:

1. The cluster is registered in the MCE's Argo under the exact name the
   folder will have (basename == Argo cluster name, convention
   `ocp4-<env>-<name>-<site>`).
2. day1 has a version file for it, at
   `sites/<site>/mces/<mce>/hostedClusters/<new-cluster>.yaml`, carrying
   `mastertag`. It normally does — day1 is what provisioned the cluster in
   the first place. If it doesn't, the render fails loudly (`required`)
   rather than deploying a version-less app, and the render check names the
   folder before you merge.

```
sites/<site>/<env>/mces/<mce>/<new-cluster>/
├── <chart>/...          # its charts — or nothing: defaults/hosted-clusters apply automatically
└── .gitkeep             # ONLY if the folder would otherwise be empty — git can't track an empty dir
```

There is no file to write: the folder *is* the registration. The moment it
merges, the cluster exists: `<team>-<new-cluster>` appears, plus one chart app
per folder **plus** one per `defaults/hosted-clusters/` chart. The team's
AppProject already exists on every cluster.

### R7. Add a new MCE / env / site

The tree is uniform — same shape, one level up, same precondition (day1
carries `sites/<site>/mces/<new-mce>/version.yaml` with a `mastertag`):

```
sites/<site>/<env>/mces/<new-mce>/
├── in-cluster/          # optional; defaults/mces charts apply automatically
└── .gitkeep             # ONLY if the folder would otherwise be empty
```

A new env is a new folder under the site — it **must** be `prod`, `prep` or
`test` (the render check enforces this), and it needs nothing at all on the
day1 side, whose tree has no env level. A new site is a new folder under
`sites/` here *and* a `sites/<site>/` in day1. Nothing to register in the
platform; the globs match any site/env.

### R8. Decommission / temporary removal

Deleting a chart folder (or a whole cluster folder) deletes the generated
Application CRs but **orphans the workloads in place** — they keep running,
unmanaged. Re-adding the same-named folder re-adopts them. For a true
teardown, delete the Applications with cascade first, then remove the
folders. Exception: `dhcp-api-token` sets `prune: true` itself — deleting
its folder removes the Secret on every MCE.

Note the day1 side is independent: removing a cluster folder here stops day2
from deploying to it, and leaves day1 (and the cluster) untouched.

### R10. Exclude a fleet-default chart from one cluster

The structural opt-out (§2.2). Use it when a chart must not exist on a named
cluster at all; if it only needs to *behave* differently there, write
`values-<cluster>.yaml` / `values-<mce>.yaml` instead.

1. Edit `defaults/mces/exclusions.yaml` (MCE hubs) or
   `defaults/hosted-clusters/exclusions.yaml` (hosted clusters). Create the
   file if it is absent — absent is the normal state.

   ```yaml
   exclusions:
     dhcp-api-token:
       - ocp4-prep-mce-site1-a
   ```

2. CI runs the four rules plus `compare`. Until the pipeline exists in the
   air-gapped env, run it by hand — `snapshot` exits 1 on any rule failure:

   ```bash
   python3 tools/render-verify/render_chain.py snapshot --out /tmp/after
   python3 tools/render-verify/render_chain.py compare /tmp/before /tmp/after
   ```

   Expect `APPS DISAPPEARED` naming **two** apps per exclusion — the wrapper
   and its `-deploy` leaf — and nothing else. **A typo on either axis is
   silent everywhere else**: Helm renders, Argo generates, and the chart keeps
   deploying. The lint is the enforcement, not hygiene.

3. Merge. The wrapper Application is deleted. Per §6-2 there is no
   `resources-finalizer`, so `<team>-<cluster>-<chart>-deploy` **and the
   running workload are orphaned in place, not removed.**

4. Only if you want the workload gone, and only **after** step 3 has
   reconciled:

   ```bash
   argocd app delete <team>-<cluster>-<chart>-deploy --cascade
   ```

   **Order matters** — deleting it while the wrapper still exists gets it
   recreated within a minute by the wrapper's `selfHeal: true`.

**Undo:** delete the entry. The same-named wrapper reappears and re-adopts the
orphaned `-deploy` app in place (§6-1/§6-2). Nothing is recreated.

**Excluded everywhere?** Then it is not a fleet default — delete the chart
folder instead (R8).

**Full override** (one cluster needs a different `repourl` / `targetRevision`,
not just different values): exclude the chart *and* create
`<clusterPath>/<chart>/`. That pair is legal **only** with the exclusion —
without it the two generators emit the same app name and CI fails on the
duplicate.

**Not for `defaults/hub/`.** One cluster, and it never flows through the
operators chart; delete the chart folder. Rule 3 fails if the file exists.

### R9. Find things

```bash
# which clusters run 4.16.27 — the version lives in the day1 repo
grep -rl 'mastertag: 4.16.27' sites/           # in gitops-day1/platform-config
# every cluster's version at a glance
grep -r mastertag sites/                       # in gitops-day1/platform-config
# ...or from Argo — matches the workload-carrying apps, not the two discovery layers
argocd app list -l day2.gitops/ocp-version=4.16.27
# everything prod on site1 running ako
argocd app list -l day2.gitops/env=prod,day2.gitops/site=site1,day2.gitops/chart=ako
# the full history of a chart on one OCP version
git log --oneline -- operators/ako/versions/ocp-4.20.9/
```

---

# Part IV — Reference

## Invariants checklist (print this)

- Folder basename == Argo cluster name. Always — and, for a hosted cluster,
  == its day1 file name minus `.yaml`.
- A folder's **existence** registers a cluster: an MCE is a directory under
  `sites/*/*/mces/`, a hosted cluster is any directory inside one except
  `in-cluster/`. There are no marker files.
- `.gitkeep` any cluster or MCE folder that would otherwise be empty — git
  cannot track an empty directory, so without it the cluster does not exist.
- Nothing but MCEs directly under `mces/`, nothing but clusters directly
  under an MCE folder: a stray directory at either level becomes a phantom
  Application (the day1-parity lint catches it).
- Every MCE and hosted-cluster folder has a day1 file carrying
  `mastertag: <major>.<minor>.<patch>[-<arch>]`. **day1 is the only place an
  OCP version is ever written** — never in a sig repo.
- Discovery generators are `directories:`, never `files:` — a `directories:`
  glob is depth-exact, a `files:` glob is a git pathspec and is not (§2.1).
- One `git mv` per move, one commit. Never copy-then-delete.
- XOR: a chart lives in a defaults folder OR a specific folder. Never both —
  unless that cluster is named under it in `defaults/<scope>/exclusions.yaml`,
  which removes the fleet entry and makes the pair a deliberate full override
  (§2.2).
- An `exclusions.yaml` key must name a real chart folder in its own defaults
  directory, and every listed name a real MCE / hosted cluster. Both typos are
  silent at runtime; CI is the only thing that catches them.
- `repourl` all-lowercase in deploy configs.
- Version branches are frozen; a fix is a new branch.
- Pins live in `operators/`; defaults configs never carry `targetRevision`
  (unless deliberately, like dhcp-api-token).
- Add `versions/ocp-<v>/` files **before** day1 flips the tag to `<v>` — on
  every upgrade, z-streams included, in every sig that pins the chart.
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
| files / directories generator | "one app per matching file" / "per matching directory". Discovery uses **only** `directories:` (§2.1) |
| multi-source app | an Application with several `sources:`; the extra `ref:` ones supply value files only — that is how `$day1` reaches the chain |
| day1 / `platform-config` | `gitops-day1/platform-config` — the repo that provisions clusters and owns their OCP versions. Day2 reads it, never writes it |
| `mastertag` | day1's version key: `<major>.<minor>.<patch>[-<arch>]`, e.g. `4.16.27-x86_64` |
| `ocpVersion` | the derived value the platform uses: `mastertag` with the architecture stripped at the first `-` (`4.16.27`). Never declared in a sig repo |
| version layer | `operators/<chart>/versions/ocp-<v>/` — the slot keyed by a destination's **exact** OCP version |
| stream | older name for a version layer, from when it was keyed by the minor line (`ocp-4.20`). Layers are keyed by the full version now, so every upgrade moves off one |
| leaf app | `<team>-<cluster>-<chart>-deploy` — the app that deploys the actual workload |
| deploy config | `<chart>.yaml` — repo/branch/namespace/sync settings for a chart |
| slot | a value-file path that is always listed but may not exist (`ignoreMissingValueFiles`) |
| pin | a `targetRevision` line selecting a frozen chart branch |
| XOR rule | defaults folder OR specific folder — never both |
| THE ONE INVARIANT | each MCE/cluster/chart emitted by exactly one generator entry, at every commit |
| frozen line | the `gitops-{{ .Values.repository }}` namespace line — never touch |
