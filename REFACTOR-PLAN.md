# Day2 Management Refactor — Architecture Review & Plan

**Status: IMPLEMENTED in the mock, 2026-08-13** — one commit per migration phase,
render-verified at every gate; **decision 9 (the day1 version source) implemented
and render-verified 2026-08-17**. `CHANGES.md` is the air-gap hand-off;
`ARCHITECTURE.md` is the team guide. This document remains the reviewed design
rationale. (Original date: 2026-08-13.)

> **AMENDMENT 2, 2026-08-17 (later the same day) — the OCP version left the
> sigs repos, and the marker files went with it.** Every cluster's version is
> now resolved at Argo render time from the day1 repo
> `gitops-day1/platform-config`, which provisioned that cluster and owns its
> version as **`mastertag`** (`sites/<site>/mces/<mce>/version.yaml` for an MCE,
> `sites/<site>/mces/<mce>/hostedClusters/<hc>.yaml` for a hosted cluster —
> day1 has **no `<env>` level**). No sig repo declares a version at all, so the
> same physical cluster is versioned once for all five sigs instead of five
> times. `ocpVersion` is now the **full patch version** (`4.16.27`), making
> `versions/ocp-<v>/` layers per-exact-version. And because carrying
> `ocpVersion` was the marker files' only remaining job, **`mce.yaml` /
> `hc.yaml` are deleted**: discovery is folder existence again, via depth-exact
> `directories:` generators (`sites/*/*/mces/*` and `<mcePath>/*` minus
> `in-cluster`), where Go `path.Match` gives the depth-exactness that
> AMENDMENT 1 had to buy with a filename. **This supersedes AMENDMENT 1 below
> and §8 decision 8; read both as the history that led here.** Full record:
> **§8 decision 9**, and the superseded-note at the head of §5.2. The passages
> below that state the marker-file contract are kept intact and flagged
> **[superseded by decision 9]**.

> **AMENDMENT 1, 2026-08-17 — the cluster registry file is no longer named
> `config.yaml`.** **[superseded by decision 9 — there is no registry file at
> all now; the pathspec hazard it documents is still why the platform uses
> `directories:` and not `files:` generators.]** It is **`mce.yaml`** at MCE
> level and **`hc.yaml`** at hosted-cluster level. Everything else about it (schema, jobs, precedence) is
> unchanged, so read every `config.yaml` below as "the marker file at that
> depth". The reason is a design error found in production during Phase B of
> the air-gap rollout: this document assumed a `files:` generator glob is
> depth-exact, and it is not — Argo matches it as a **git pathspec**, where
> `*` crosses `/`. One shared filename at two depths therefore made every
> hosted cluster match the MCE glob. Depth had to move out of the glob and
> into the filename. Full write-up: `CHANGES.md` §0; mechanics:
> `ARCHITECTURE.md` §2.1. The passages below that asserted depth-exact
> matching have been corrected in place and are marked **[corrected]**.

This document is self-contained: current-state findings, review of the proposed
architecture, the recommended target design, and a zero-impact migration plan.

---

## 1. Goals

1. **Defaults for all hosted clusters** — deploy a chart to every hosted cluster of a team
   from a single place (today this exists only for MCE hubs via `mces/in-cluster-defaults/`).
2. **Group by env / site / versions** — the sigs tree should separate prod/prep/test, sites,
   and OCP versions, so fleet operations like "upgrade all prod clusters" or "everything on
   site five" become tractable. **OCP version is the only version dimension** — there is no
   separate MCE-version concept; an MCE hub is versioned by its own OCP version, exactly like
   a hosted cluster (user decision 2026-08-13).
3. **Chart-version management** — pick which chart version runs per OCP stream, with a
   default and per-cluster override, driven from the day2 repo.

## 2. Hard constraints

- The air-gapped env is **full production**: existing Applications must not be impacted.
  Only exceptions: top-level `in-cluster/` and `mces/in-cluster-defaults/` (no production
  charts there yet).
- All generated apps at platform layers run `selfHeal: true` → every change must be
  render-verified **before** merge; there is no post-merge inspection window.

---

## 3. Current state (condensed findings)

### 3.1 The generation chain

| Layer | File | Generator | Scans (sigs repo) | Emits | Destination |
|---|---|---|---|---|---|
| groups (prod-hub) | `groups/templates/groupsAppset.yaml` | scmProvider/gitlab (group `243709`) | one entry per team repo | App `<group>` → platform `mces/` | prod-hub |
| mces (prod-hub) | `mces/templates/mcesAppset.yaml` | git directories | `mces/*` minus `mces/in-cluster-defaults` | App `<group>-<mce>` → platform `clusters/` | **`name: {{path.basename}}`** = the MCE |
| app-projects | `mces/templates/appProjectAppset.yaml` | `clusters: {}` | — | AppProject `<group>` everywhere (sync-wave `-1`) | every cluster |
| hub in-cluster | `mces/templates/inClusterAppset.yaml` | git directories | `in-cluster/*` | hub-mode chart apps (`hub: true`, no `mce`) | prod-hub |
| clusters (on MCE) | `clusters/templates/clustersAppset.yaml` | git directories | `mces/<mce>/*` minus `.../in-cluster` | App `<group>-<cluster>` → platform `operators/` | the MCE |
| — static | `clusters/templates/inClusterApp.yaml` | none (static) | — | App `<group>-in-cluster` (`cluster: in-cluster`) | the MCE |
| operators (on MCE) | `operators/templates/operators.yaml` | git directories ×2 | `mces/<mce>/<cluster>/*`; + `mces/in-cluster-defaults/*` when `cluster == in-cluster` | App `<group>-<cluster>-<chart>` → platform `deploy/` | the MCE |
| deploy (leaf) | `deploy/templates/deployApp.yaml` | — | — | App `<group>-<cluster>-<chart>-deploy` = the real workload chart | **`name: {{cluster}}`** = the spoke |

### 3.2 Two value stacks flow through the chain

- **Deploy-config stack** — `<chart>/<chart>.yaml` files, consumed by the platform `deploy`
  chart itself. Keys: `repourl` (**lowercase**), `targetRevision` (default `HEAD`), `path`
  (default `.`), `projectNamespace`, `syncPolicy`, `ignoreDifferences`, `appname`, `oldConvention`.
- **Workload-values stack** — `<chart>/values.yaml` files, consumed by the actual helm chart.
  Current order (lowest → highest), all `ignoreMissingValueFiles: true`:
  `operators/<chart>/` → `mces/<mce>/` → `mces/<mce>/<cluster>/` →
  [`mces/in-cluster-defaults/<chart>/{values,values-<mce>}.yaml` when in-cluster and not hub] →
  `mces/<mce>/<cluster>/<chart>/` → [`in-cluster/<chart>/` when hub].

### 3.3 Identity & deletion semantics (what makes a safe refactor possible)

- **Application names are built only from basenames** (`<group>`, `<mce>`, `<cluster>`,
  `<chart>`) — intermediate path levels never appear in an app name.
- Destinations are always **by cluster `name:`** → folder basenames must equal Argo cluster
  names, in any layout. Cluster names are flat/global — nesting folders doesn't relax that.
- **No `resources-finalizer` on any Application** → if an appset drops an entry, the
  Application CR is deleted but the deployed workloads are **orphaned, not deleted**.
  The worst failure mode of a bad move is cruft, never a client outage.
- Platform layers: `automated {selfHeal: true, prune: false}`. Leaf workload apps:
  **manual-sync** unless the chart's config opts in (only `dhcp-api-token` does).
- **Zero labels anywhere today** — no way to select "all prod apps" (§5.5 fixes this).

### 3.4 Known issues to respect (not fix here)

- **FROZEN:** `namespace: gitops-{{ .Values.repository }}` in `mcesAppset.yaml` /
  `appProjectAppset.yaml` renders `gitops-` (`.Values.repository` is never set). CHANGES.md
  says don't copy it, don't fix it. **It is load-bearing frozen for this refactor too:**
  Phase B rewrites the generator in that same file — the line must stay **byte-identical**,
  because changing it changes generated app namespaces → app identity → fleet-wide
  delete/recreate.
- `repoUrl` vs `repourl` casing bug in `operators/{bmhgen,kyverno,cluster-roles}` and
  `mces/in-cluster-defaults/example-chart` (renders an empty `repoURL`). Separate cleanup —
  fixing it mid-migration would suddenly "un-break" apps; keep it out of this refactor.
- The two `example-chart/` folders are convention demos — never ship to prod.
- Existing XOR rule: a defaults chart lives in `in-cluster-defaults/` **or** in a specific
  MCE's `in-cluster/`, never both (duplicate app names).

---

## 4. Review of your proposed architecture

### 4.1 What I endorse as-is

- **`sites/` tree with env + site levels** — correct. Env and site are *immutable identity*;
  directory structure is exactly where immutable identity belongs.
- **`defaults/{hub,mces,hosted-clusters}/`** — correct, and cheap: `hosted-clusters` is the
  same mechanism `in-cluster-defaults` already uses (a second generator in `operators.yaml`),
  pointed at a new folder and gated on the opposite condition. The two renames are safe
  because those layers carry no production charts.
- **Versioned value layers per chart under `operators/`** — correct instinct; kept, as
  `operators/<chart>/versions/` (§5.3).

### 4.2 Your orphan fear is unfounded — here's why

You were worried that moving a cluster folder from `4.16/` to `4.20/` deletes its `ako`
Application and orphans resources. It doesn't, because of §3.3:

1. App names derive **only from basenames**. `redbull-prep-kubevirt-five-a-ako` contains no
   version segment. A `git mv` across version folders (in **one commit**) makes the appset
   see the same app name with new parameters → **in-place update**, not delete+recreate.
   The result on the cluster is a normal helm upgrade.
2. Even in the worst case (a chart folder genuinely disappears), there are no resource
   finalizers → the workload is orphaned in place, not torn down. No client impact.

So version folders *would work*. I still recommend against them — see 4.3.

### 4.3 The one structural change I recommend: versions as **data**, not directories

**Directory position should encode identity (things that never change: env, site, mce,
cluster). Versions are mutable state — they belong in a file, not in the path.**

Recommended: each MCE folder and each hosted-cluster folder carries a tiny `config.yaml`
(env, site, `ocpVersion`), read by Argo CD **git file generators**. Version-scoped values
live in per-chart version layers selected by those parameters.

> **[superseded by decision 9, 2026-08-17]** The conclusion stands — a version is
> mutable state, so it belongs in data and not in a path segment — but the data no
> longer lives in a sigs file: it is day1's `mastertag`, read at render time, which
> also removes the last duplication (the same cluster's version written once per sig
> repo). Everything below about a per-folder registry file is history; the
> version-as-data-vs-directories trade-off it argues is not.

The trade-off in one sentence: **version-as-data costs a one-time platform generator change;
version-as-folders costs recurring `git mv` churn plus "never let a folder exist twice"
discipline on every upgrade, forever.**

Concretely, version-as-data gives you:

- **Cluster upgrade = a one-line diff** (`ocpVersion: "4.16"` → `"4.20"`), reviewable in an
  MR, trivially revertible — instead of a folder move per upgrade polluting git history.
- **No transient-duplicate risk.** With version folders, a botched move (copy-then-delete
  across commits, or a folder present under two versions) yields two generator entries with
  the same app name — undefined ApplicationSet behavior. A file edit cannot produce this.
- **Stable tree depth and stable generator globs** — the chart path stays
  `.../mces/<mce>/<cluster>/<chart>/` instead of 8 levels deep.
- **Extensible metadata** — hardware generation, maintenance windows, canary flags can be
  added to `config.yaml` later without another restructure.
- **Fleet queries** — "which clusters are on 4.16" is one `grep`, and with §5.5 labels, one
  Argo selector.

Your ideas map onto the recommendation like this:

| Your idea | Where it lands |
|---|---|
| `sites/<site>/<env>/mces/<mce-ver>/<mce>/<hc-ver>/<cluster>/` | `sites/<site>/<env>/mces/<mce>/<cluster>/` + a `config.yaml` at each level carrying that cluster's own `ocpVersion` |
| `operators/ako/<ako-version>/` | `operators/ako/versions/ocp-<v>/` — a values/pin layer per OCP stream (§5.3) |
| helm-charts branch per HC version, folder per chart version, one marked default | **branch per chart release** in each chart repo (kept — user decision 2026-08-13); "default" = the pin in `operators/ako/ako.yaml`; per-stream pin in `versions/ocp-<v>/ako.yaml` (§5.3) |
| "upgrade chart by referencing a different folder" | upgrade chart by editing one pin line — same ergonomics, better audit trail |
| version-agnostic charts (your open question) | simply have no `versions/` dir — every layer is optional via `ignoreMissingValueFiles`, so nothing special is needed |
| delete app non-cascading + let new app adopt (your workaround idea) | unnecessary — no app is ever deleted (§4.2) |

If you strongly prefer seeing versions as folders, Appendix A describes how to do that
safely — but the rest of this plan assumes version-as-data.

---

## 5. Target design

### 5.1 Target tree (per team, e.g. `sigs/redbull/`)

```
sigs/<team>/
├── sites/
│   └── <site>/                         # five, site1, ...
│       ├── values.yaml                 # optional site-wide values (use sparingly)
│       └── <env>/                      # prod | prep | test
│           ├── values.yaml             # optional site+env values
│           └── mces/
│               └── <mce-name>/         # folder name == Argo cluster name (unchanged rule)
│                   ├── config.yaml     # env, site, ocpVersion (the MCE's own OCP version)
│                   ├── values.yaml     # optional MCE-wide values (see note below — no such FILE exists today)
│                   ├── in-cluster/     # charts on the MCE hub itself
│                   │   └── <chart>/{<chart>.yaml, values.yaml}
│                   └── <hosted-cluster>/          # folder name == Argo cluster name
│                       ├── config.yaml            # env, site, ocpVersion
│                       ├── values.yaml            # optional cluster-wide values
│                       └── <chart>/{<chart>.yaml, values.yaml}
├── operators/                          # team-wide per-chart layer (never generator-scanned)
│   └── <chart>/
│       ├── <chart>.yaml                # team default deploy config (default version pin)
│       ├── values.yaml                 # team default values
│       └── versions/                   # ONLY for version-sensitive charts
│           └── ocp-<v>/{<chart>.yaml, values.yaml}    # per OCP stream — serves hosted
│                                                      # clusters AND MCE in-cluster charts
│                                                      # (selected by the destination's ocpVersion)
└── defaults/
    ├── hub/                            # was: top-level in-cluster/  → prod-hub charts
    │   └── <chart>/{<chart>.yaml, values.yaml}
    ├── mces/                           # was: mces/in-cluster-defaults/ → every MCE hub
    │   └── <chart>/{<chart>.yaml, values.yaml, values-<env>.yaml, values-<mce>.yaml}
    └── hosted-clusters/                # NEW → every hosted cluster of the team
        └── <chart>/{<chart>.yaml, values.yaml, values-<env>.yaml, values-<cluster>.yaml}
```

Unchanged rules that keep this compatible: folder basename == Argo destination cluster name;
chart folder == `<chart>.yaml` + `values.yaml`; every dir under a generator-scanned path
becomes an Application (plain files like `config.yaml`/`README.md` are ignored by directory
generators — this fact is what makes the migration safe).

> **[superseded by decision 9, 2026-08-17]** The two `config.yaml` entries in the tree
> above (later `mce.yaml` / `hc.yaml`) **no longer exist**. An MCE is a bare folder under
> `sites/<site>/<env>/mces/`, a hosted cluster is any folder inside one except
> `in-cluster/`, and the version comes from day1. Two consequences of folder-only
> discovery: git cannot track an empty folder, so a cluster onboarded with no content of
> its own needs a `.gitkeep`; and a stray non-cluster folder under an MCE becomes a
> phantom Application — caught before merge by the render check's day1-parity lint (a
> stray folder has no day1 version file). Everything else in the tree is current.

> **Why `mces/` exists but there's no `envs/` wrapper:** a container folder must earn its
> place by disambiguating sibling *kinds* or anchoring automation. `mces/` does both — the
> literal segment in the glob `sites/*/*/mces/*/mce.yaml` confines MCE discovery to that
> subtree **[corrected: the literal segment bounds the subtree, not the depth — only the
> `mce.yaml` filename does that; superseded by decision 9 — the glob is now the
> `directories:` glob `sites/*/*/mces/*`, whose `*` cannot cross `/`, so the literal
> segment bounds the subtree and the engine bounds the depth]**, reserves the env level for future env-scoped
> siblings, and keeps `mcePath` ending in `mces/<mce>` in both layouts. An `envs/` wrapper
> would do neither job: envs are the only children of a site and a closed set
> (`prod|prep|test`, enforced by the §9 render check) — it would only add depth.

> **Note on "optional" values files:** every `values.yaml` marked optional above is an
> `ignoreMissingValueFiles` *slot*, not a required file. The MCE-wide and cluster-wide slots
> are already in today's `deployApp.yaml` stack (`$values/mces/<mce>/values.yaml`,
> `$values/mces/<mce>/<cluster>/values.yaml`) — but **no such file exists in any MCE or
> cluster folder today** (verified), so nothing changes for existing apps. The refactor only
> re-points these slots at the new paths; they keep resolving to nothing until someone
> deliberately creates one, and creating one is always a scoped, opt-in change.

### 5.2 `mce.yaml` / `hc.yaml` — the cluster registry entry

> **THIS WHOLE SECTION IS SUPERSEDED BY DECISION 9 (2026-08-17) — the marker files are
> deleted.** The end-state schema this section drives at is a file holding exactly one key,
> `ocpVersion`; decision 9 moves that one key out of the sigs repos entirely (day1's
> `mastertag`), which leaves the file with nothing to hold, and its discovery-marker role
> is done better by a `directories:` glob. **The current contract in one paragraph:** an MCE
> is a folder matching `sites/*/*/mces/*`; a hosted cluster is any folder inside one except
> `in-cluster/`; env/site are `{{path[2]}}`/`{{path[1]}}` (as below); the version is read
> from day1 and derived once per template as `mastertag | splitList "-" | first`, giving the
> **full** version `4.16.27`. The reasoning below is kept because it explains why the
> markers existed and why nothing replaced them.

```yaml
# sites/five/prod/mces/prod-mce-five-a/mce.yaml
env: prod               # ┐ needed only during migration — the legacy layout has no env/site
site: five              # ┘ in its path; both fields are dropped in Phase D (see rules below)
ocpVersion: "4.20"      # the MCE's OWN OCP version. ALWAYS quote — YAML parses 4.20 as the float 4.2
```

```yaml
# sites/five/prod/mces/prod-mce-five-a/prod-kubevirt-five-a/hc.yaml
ocpVersion: "4.20"      # env/site are NEVER needed here — the cluster layer inherits them
                        # from the MCE-level parameters passed down the chain
```

Rules:

- **One version field everywhere: `ocpVersion` = the OCP version of the folder's own
  cluster.** There is no MCE-version dimension — charts deployed on an MCE hub resolve
  version layers by the MCE's OCP version (e.g. `ocp4-prep-mce-five-a` runs OCP 4.20, so
  every chart deployed to it uses the `ocp-4.20` layers). End-state, MCE-level and
  cluster-level `config.yaml` therefore share an identical schema (just `ocpVersion`).

- **Versions are the file's permanent job** — they can never be derived from a path.
  Env/site are different: the *target* tree encodes them, but the *legacy* folder location
  does not (`mces/<mce>/` — where every MCE sits today; no `config.yaml` exists there yet,
  Phase A creates it in place before anything else changes), and during the Phase B→C window
  one shared template serves both globs — so env/site must come from file content to stay
  uniform. Therefore:
  - **During migration**: the MCE-level `config.yaml` carries `env`/`site` and is
    authoritative; a render-time check asserts path ⇔ config agreement for MCEs already in
    the new tree.
  - **End-state (Phase D)**: once the legacy glob is removed, `sites/*/*/mces/*/mce.yaml`
    matches MCE folders and nothing else, so path positions are trustworthy — the platform
    switches to `{{path[1]}}` (site) / `{{path[2]}}` (env) and both fields are deleted from
    every marker file, leaving only the version. No duplication, no permanent consistency
    check. **[corrected: what makes the match exact is the unique `mce.yaml` filename, NOT
    the glob — `*` in a `files:` glob crosses `/`. With the original shared `config.yaml`
    this claim was false and `{{path[n]}}` shifted by one on the over-matched hits.]**
  - **Ordering caveat**: switch the template first, *then* strip the fields — removing a
    field while the template still reads it leaves literal `{{env}}` placeholders in
    rendered specs (fasttemplate keeps unmatched placeholders as-is).
- MCE hub `in-cluster/` folders have **no** marker file — which is exactly why the
  file-generator naturally skips them (the current generator `exclude` becomes obsolete).
- Presence of a marker file is what makes a folder an MCE (`mce.yaml`) or a hosted cluster
  (`hc.yaml`). A folder without one is invisible — this replaces both existing generator
  excludes. **The two names must never converge**: the filename is the only thing pinning
  each generator to its depth (ARCHITECTURE.md §2.1).
- **Why a whole file for (eventually) one version field:** the file's primary job is that
  discovery-marker role — a files generator needs a file to anchor on, and one canonical
  filename guarantees at most one generator entry per folder (the migration invariant, by
  construction). Given the file must exist anyway, the version rides along free. The
  alternatives all cost more: version-in-path = `git mv` churn on every upgrade; version in
  the cluster's `values.yaml` = platform metadata injected into every chart's helm values;
  a central per-team registry file = merge hotspot that breaks folder-move locality. It is
  also the extension point for future metadata (maintenance windows, canary rings, pause
  flags) without restructuring.

### 5.3 Chart-version management

**helm-charts side** (each chart is its own repo under `redbull/helm-charts/<chart>.git`):

- **Branch per chart version** (user decision 2026-08-13 — keeps the org's existing
  operator-repo convention): development on `main`; each release is a branch named for the
  version: `2.1.2`, `2.1.4`, … `targetRevision` resolves branch names exactly as it would
  tags, so this choice touches zero platform templates.
- **The discipline that makes branches safe:** a version branch is *frozen at creation*.
  A fix is a **new** branch (`2.1.5-hotfix`) cut from the old one — never a push to an
  existing version branch, because a moved branch changes what every pinned cluster deploys
  with no MR in the day2 repo. The pin files must remain the single audit trail.
- **Branch per chart version, NOT per OCP version.** Branch-per-OCP-variant means every fix
  is a cherry-pick fan-out and branches drift apart permanently. The "which chart versions
  are supported on OCP 4.20" knowledge belongs in the day2 repo, where it's an
  MR-reviewable pin (each pin value below is a branch name in the chart's repo):

**day2 side** — three pin levels, lowest to highest:

```yaml
# operators/ako/ako.yaml                       — team default (your "default version")
targetRevision: "2.1.2"

# operators/ako/versions/ocp-4.20/ako.yaml     — the curated per-stream matrix
targetRevision: "2.1.4"

# sites/five/prod/mces/<mce>/<cluster>/ako/ako.yaml   — per-cluster emergency pin
targetRevision: "2.1.5-hotfix"
```

- Fleet chart upgrade on a stream = edit one `versions/ocp-<v>/` file. Cluster OCP upgrade =
  edit `ocpVersion` in its `config.yaml` and it starts resolving the `ocp-4.20` layers.
  Leaf apps stay manual-sync (§8 decision 6), so the rollout moment stays operator-controlled
  per chart or in bulk by label — **step-by-step for both: §5.8**.
- MCE OCP upgrade = the exact same one-line edit in the MCE's `config.yaml` — its
  in-cluster charts start resolving the new `ocp-<v>` layers.

> **[superseded by decision 9, 2026-08-17 — both upgrade bullets]** An OCP upgrade is no
> longer a day2 edit at all: it is day1 flipping that cluster's `mastertag`
> (`sites/<site>/mces/<mce>/version.yaml` for an MCE, `.../hostedClusters/<hc>.yaml` for a
> hosted cluster). Every sig repo re-renders off that one file. The chart-pin bullet is
> unchanged, except that `<v>` is now the **full** version everywhere it appears in this
> document — read every `ocp-4.20` example from here on as `ocp-4.20.14`, one layer per
> exact patch release. See the ordering rule in §5.8 §A, which now applies to z-streams too.
- **One layer family serves both roles:** a chart deployed to MCE hubs *and* hosted clusters
  on the same OCP stream shares the same `versions/ocp-<v>/` layer. Role-specific
  differences belong in `defaults/mces/` vs `defaults/hosted-clusters/` values files — never
  reintroduce a per-role version dimension ad hoc.

#### Version-agnostic charts (charts that just track `main`)

Nothing special is needed, and nothing changes for them. This is already the majority case in
the mock: `operators/kyverno/kyverno.yaml` and `operators/cluster-roles/cluster-roles.yaml`
carry `targetRevision: main`, and `operators/bmhgen/bmhgen.yaml` carries no `targetRevision`
at all, falling back to the `default "HEAD"` in `deployApp.yaml`. Both keep working untouched.

**Why absence is free.** The `versions/ocp-<v>/` paths are emitted into the valueFiles list
for *every* chart — the destination's `ocpVersion` is always known, so the path is always
constructed. Both stacks already set `ignoreMissingValueFiles: true` (config stack:
`operators.yaml`; workload stack: `deployApp.yaml`), so a chart with no `versions/` dir
simply resolves that layer to nothing. No folder to create, no render error, no spec diff.

**The pin axis and the values axis are independent** — `versions/ocp-<v>/` holds two
unrelated files and a chart may use either, both, or neither:

| Chart branch | Per-OCP values | What you write |
|---|---|---|
| tracks `main` everywhere | none | nothing — no `versions/` dir at all |
| tracks `main` everywhere | needed | `versions/ocp-4.20/values.yaml` **only** (no `<chart>.yaml`) — same branch on every stream, different values on 4.20 |
| pinned per stream | none | `versions/ocp-4.20/<chart>.yaml` **only** |
| pinned per stream | needed | both files |

So "version-agnostic" is per-axis. A chart can stay on `main` forever and still get a
4.20-specific value, and a pinned chart can share one values file across all streams.

**Escalating later is additive.** If a `main`-tracking chart eventually breaks on a new OCP
stream, you add one file (`versions/ocp-4.22/<chart>.yaml` with a branch pin) — only 4.22
clusters resolve it, everyone else stays on `main`. No restructure, no app rename, no
generator change. Reverting is deleting that file.

**The one real trade-off.** `main` is a moving branch, which is exactly the hazard the
frozen-version-branch rule above exists to prevent: for these charts the day2 pin file is
**not** the audit trail — the chart repo's `main` is. Concretely, a push to the chart repo
makes every manual-sync leaf app go OutOfSync, and the next sync ships whatever `main` holds
at that moment (including unrelated in-flight work); charts that opt into auto-sync (today
only `dhcp-api-token`) roll out on push with no MR anywhere. That is the org's existing
posture and this refactor neither creates nor fixes it — but it means "which chart version is
running on cluster X" is answerable from git only for pinned charts. Where that matters for a
given chart, cutting a version branch and pinning it costs one line.

Fleet labels are unaffected: `day2.gitops/ocp-version` is the *destination's* OCP version,
not the chart's, so version-scoped selectors (§5.5) still sweep `main`-tracking apps
correctly.

### 5.4 `defaults/` — the three fleet layers

| Folder | Reaches | Mechanism |
|---|---|---|
| `defaults/hub/` | prod-hub mgmt cluster | rename of top-level `in-cluster/`; `inClusterAppset.yaml` glob change |
| `defaults/mces/` | every MCE hub | rename of `mces/in-cluster-defaults/`; `operators.yaml` generator-2 + `deployApp.yaml` layer paths |
| `defaults/hosted-clusters/` | every hosted cluster | **NEW** generator-3 in `operators.yaml`, gated `cluster != in-cluster && !hub` — the exact mirror of generator-2 |

- Per-scope tuning without leaving the defaults folder: `values-<env>.yaml`,
  `values-<mce>.yaml` / `values-<cluster>.yaml` siblings (extends the existing
  `values-<mce>.yaml` convention).
- **XOR rule generalizes:** a chart lives in a defaults folder **or** in a specific
  cluster/MCE folder, never both — two generator entries with one app name otherwise.
  Same-template rendering means moving a chart between a defaults folder and a specific
  folder stays an in-place no-op (existing property, preserved).
- Opt-out of a default for one cluster is *not* supported by structure (that's what makes it
  a default). Behavior differences go in `values-<cluster>.yaml`; a true opt-out flag can be
  added later via `config.yaml` metadata if ever needed **[superseded by decision 9: there is
  no per-cluster metadata file any more — such a flag would need a mechanism of its own]**.

### 5.5 Labels on generated Applications — the actual fleet-operations enabler

Grouping folders lets humans *find* things; labels let tooling *act* on them. Today the
platform emits **zero labels**, so there is no way to say "sync everything prod". Add to
every generated Application (all appset templates + `inClusterApp.yaml` + `deployApp.yaml`):

```yaml
labels:
  day2.gitops/team: '{{ .Values.group }}'   # prefix is team-agnostic — templates serve ALL teams
  day2.gitops/env: prod
  day2.gitops/site: five
  day2.gitops/mce: prod-mce-five-a
  day2.gitops/cluster: prod-kubevirt-five-a
  day2.gitops/chart: ako
  day2.gitops/ocp-version: "4.20"           # in-cluster apps carry the MCE's OCP version;
                                            # hub apps OMIT this label (hub is version-less)
  day2.gitops/role: hosted-cluster          # hub | mce | hosted-cluster
```

> **[superseded in part by decision 9, 2026-08-17]** `day2.gitops/ocp-version` now carries
> the **full** version (`"4.16.27"`), so every selector below takes the exact version. And
> the per-MCE and per-HC Applications (`mcesAppset` / `clustersAppset`) **omit the label
> entirely**: those two layers never learn the version — they only point the next chart at
> the day1 file that holds it. Every layer below them (`inClusterApp`, `operators`,
> `deploy`) still carries it, which is where version-scoped fleet ops act anyway.

Then fleet operations become one selector:

```bash
argocd app list  -l day2.gitops/env=prod,day2.gitops/chart=ako
argocd app sync  -l day2.gitops/env=prod,day2.gitops/ocp-version=4.20
argocd app list  -l day2.gitops/site=five,day2.gitops/team=redbull
```

This change is **purely additive and zero-impact**: labels on Application CRs never touch
workload manifests. It can even ship before (or without) the tree refactor. Note labels are
per-Argo — MCE-level selectors run against each MCE's Argo; hub-level against prod-hub.
Since in-cluster apps also carry `day2.gitops/ocp-version` (the MCE's), a bare
`ocp-version=4.20` selector sweeps MCE hubs *and* hosted clusters together — pair it with
`day2.gitops/role` when a version-scoped bulk op should hit only one of the two.

### 5.6 Value layering — target stacks

Deploy-config stack (`<chart>.yaml`), lowest → highest:

| # | Hosted cluster | MCE in-cluster | Hub |
|---|---|---|---|
| 1 | `operators/<c>/<c>.yaml` | same | same |
| 2 | `operators/<c>/versions/ocp-<v>/<c>.yaml` | same layer, `<v>` = the MCE's OCP version | — |
| 3 | `defaults/hosted-clusters/<c>/<c>.yaml` | `defaults/mces/<c>/<c>.yaml` | `defaults/hub/<c>/<c>.yaml` |
| 4 | `<clusterPath>/<c>/<c>.yaml` | `<mcePath>/in-cluster/<c>/<c>.yaml` | — |

Workload-values stack (`values.yaml`), lowest → highest (every file optional):

| # | Hosted cluster |
|---|---|
| 1 | `operators/<c>/values.yaml` |
| 2 | `operators/<c>/versions/ocp-<v>/values.yaml` |
| 3 | `sites/<site>/values.yaml` (site-wide, chart-agnostic — use sparingly) |
| 4 | `sites/<site>/<env>/values.yaml` (site+env) |
| 5 | `defaults/hosted-clusters/<c>/values.yaml` |
| 6 | `defaults/hosted-clusters/<c>/values-<env>.yaml` |
| 7 | `defaults/hosted-clusters/<c>/values-<cluster>.yaml` |
| 8 | `<mcePath>/values.yaml` (MCE-wide) |
| 9 | `<clusterPath>/values.yaml` (cluster-wide) |
| 10 | `<clusterPath>/<c>/values.yaml` (chart @ cluster — highest) |

MCE in-cluster mirrors it with the same `versions/ocp-<v>` layer (selected by the MCE's own
OCP version), `defaults/mces/<c>/{values,values-<env>,values-<mce>}.yaml`,
then `<mcePath>/values.yaml`, `<mcePath>/in-cluster/<c>/values.yaml`.
Hub stays minimal: `operators/<c>/values.yaml` → `defaults/hub/<c>/values.yaml`.

### 5.7 Platform template changes (summary per file)

The key move: **stop hardcoding `mces/<mce>/...` path strings; pass the generator's `{{path}}`
down as `mcePath` / `clusterPath` values** and build all valueFiles from them. After this,
only `mcesAppset.yaml` knows the tree layout — every other template is layout-agnostic.

| File | Change |
|---|---|
| `mces/templates/mcesAppset.yaml` | `directories` → **git files** generator: `mces/*/mce.yaml` (legacy) + `sites/*/*/mces/*/mce.yaml` (target). Drop the `in-cluster-defaults` exclude (obsolete — no marker file there). Pass down: `mce` (=`{{path.basename}}`), `mcePath` (=`{{path}}`), `env`, `site`, `ocpVersion` (the MCE's own — from file content during migration; end-state env/site switch to `{{path[1]}}`/`{{path[2]}}` — §5.2). Labels. **Do not touch the frozen `namespace:` line.** |
| `mces/templates/inClusterAppset.yaml` | glob `in-cluster/*` → `defaults/hub/*` (add-first, then remove old — §7 Phase C'). Labels. |
| `clusters/templates/clustersAppset.yaml` | `directories` → **git files** generator: `{{ .Values.mcePath }}/*/hc.yaml`. The `in-cluster` exclude becomes obsolete (no marker file in `in-cluster/`). Pass down `cluster`, `clusterPath`, `env`, `site`, `ocpVersion` (the hosted cluster's own, **overriding** the MCE's inherited value), plus inherited `mce*`. Labels. |
| `clusters/templates/inClusterApp.yaml` | unchanged shape; passes `mcePath`, labels; does **not** override `ocpVersion`, so in-cluster apps inherit the MCE's — one key, override semantics, no separate `mceVersion` param anywhere. |
| `operators/templates/operators.yaml` | gen-1 dirs: `{{ .Values.clusterPath }}/*`. gen-2 (in-cluster): `defaults/mces/*`. **gen-3 (NEW, hosted clusters): `defaults/hosted-clusters/*`.** Config-stack valueFiles per §5.6. Labels. |
| `deploy/templates/deployApp.yaml` | workload valueFiles per §5.6 (path-parametric + version + env/site/defaults layers, all ignore-missing). Labels. Destination/releaseName/naming **unchanged**. |

> **[superseded by decision 9, 2026-08-17 — the two generator rows]** `mcesAppset.yaml` and
> `clustersAppset.yaml` **keep `directories:` generators** rather than switching to `files:`:
> `sites/*/*/mces/*`, and `{{ .Values.mcePath }}/*` with an `in-cluster` exclude entry. They
> pass no `ocpVersion` down. Each instead gains a second source `ref: day1` plus one
> `$day1/...` path in the primary source's `valueFiles`, so the destination's `mastertag`
> arrives as `.Values.mastertag` at the next chart layer. Derivation happens in exactly two
> templates — `clusters/templates/inClusterApp.yaml` and `operators/templates/operators.yaml`
> — as `required ... | splitList "-" | first`, and `inClusterApp` passes the **raw tag**
> down rather than the derived version, so the chain has one derivation rule and one failure
> message. Everything else in the table (path-parametric `mcePath`/`clusterPath`, labels, the
> frozen `namespace:` line, the `defaults/` generators) stands as written.

Nothing changes in: `groupsAppset.yaml`, `appProjectAppset.yaml`, app names, releaseNames,
destinations, AppProjects, sync policies.

### 5.8 Upgrade runbook — hosted clusters & charts

> Mechanism is §5.3; this is the operational view — what an engineer edits, what moves, and
> what provably does not. MCE hub upgrades are the same one-line edit one level up (§5.3)
> and are out of scope here.

**Two upgrade axes, deliberately independent.** A cluster moves along the *OCP* axis; a chart
moves along the *chart-version* axis. They meet in exactly one place — the
`operators/<chart>/versions/ocp-<v>/` layer, selected by the destination's `ocpVersion`.
**Neither upgrade ever moves a folder or renames an Application.**

#### A. Cluster OCP upgrade (4.16 → 4.20)

> **[superseded by decision 9, 2026-08-17 — the file changes, the mechanics don't.]** The
> one-line edit now lands in the **day1** repo, in that cluster's own file —
> `sites/five/mces/prod-mce-five-a/hostedClusters/prod-kubevirt-five-a.yaml`,
> `mastertag: 4.16.27-x86_64` → `4.20.14-x86_64` (an MCE's is
> `sites/five/mces/prod-mce-five-a/version.yaml`; day1 has no `<env>` level). No day2 commit
> at all, and the upgrade reaches every sig repo at once. In the table below, row 1 becomes
> "`clustersAppset`'s `$day1` value file re-resolves and passes `mastertag` down"; rows 2–5
> hold, with the layers flipping between **full** versions
> (`versions/ocp-4.16.27/` → `versions/ocp-4.20.14/`) and the label carrying the full
> version. Rollback = revert the day1 commit. The ordering rule at the end of this section
> gets sharper, not weaker: **every** upgrade, z-streams included, needs its
> `versions/ocp-<new>/` folder in place *before* day1 flips the tag.

One line in one file:

```diff
  # sites/five/prod/mces/prod-mce-five-a/prod-kubevirt-five-a/hc.yaml
- ocpVersion: "4.16"
+ ocpVersion: "4.20"
```

What that merge does:

| # | Effect |
|---|---|
| 1 | `clustersAppset`'s files generator re-reads `hc.yaml`, passes `ocpVersion: "4.20"` down |
| 2 | Every chart App of that cluster re-renders with layer 2 of **both** stacks flipped from `versions/ocp-4.16/` to `versions/ocp-4.20/` (§5.6) |
| 3 | Charts **pinned per stream** show a `targetRevision` spec diff; charts **tracking `main`** show none (§C) |
| 4 | `day2.gitops/ocp-version` flips to `"4.20"` on every app of that cluster (§5.5) |
| 5 | **Nothing syncs on its own** — leaf apps are manual-sync (decision 6). Apps go OutOfSync and wait |

- **Blast radius:** that one cluster. No folder moves, so the ONE INVARIANT (§6) is never at
  risk and no app is deleted or recreated.
- **Rollout:** `argocd app sync -l day2.gitops/cluster=prod-kubevirt-five-a` (or per chart).
- **Rollback:** revert the one-line commit; the previous layers resolve again.
- **Ordering rule — add the layer before flipping the version.** If `versions/ocp-4.20/`
  doesn't exist yet for a pinned chart, that layer resolves to nothing and the cluster
  **silently falls back** to the team default in `operators/<chart>/<chart>.yaml`.
  `ignoreMissingValueFiles` cannot tell "no layer needed" from "layer forgotten" — that is
  the price of §C being free. Add the stream's files first, then flip; confirm with the §9
  render check.

#### B. Chart version upgrade

Three pin scopes, lowest → highest (§5.3). Each is one file, one line:

| Scope | File | Who moves |
|---|---|---|
| Team default | `operators/ako/ako.yaml` | every cluster with no higher layer, on any stream |
| **One OCP stream** (the fleet op) | `operators/ako/versions/ocp-4.20/ako.yaml` | every 4.20 cluster running ako |
| One cluster (emergency) | `sites/<site>/<env>/mces/<mce>/<cluster>/ako/ako.yaml` | that cluster only |

```diff
  # operators/ako/versions/ocp-4.20/ako.yaml
- targetRevision: "2.1.4"
+ targetRevision: "2.1.5"
```

- The value is a **branch name in the chart's own repo** (decision 3). A version branch is
  frozen at creation — a fix is a *new* branch cut from it, never a push to an existing one,
  or the day2 pin stops being the audit trail.
- **Rollout:** `argocd app sync -l day2.gitops/chart=ako,day2.gitops/ocp-version=4.20`.
- **Rollback:** revert the file. Because the pin is data and not a path, `git log` on this
  one file *is* the version history of ako on the 4.20 fleet.
- A higher layer wins silently: a cluster carrying its own emergency pin will **not** move
  with the stream. Find them before a fleet upgrade —
  `grep -rl targetRevision sites/*/*/mces/*/*/ako/`.

#### C. A chart with no versions — no version folder, ever

This is the majority case: `kyverno` and `cluster-roles` carry `targetRevision: main`,
`bmhgen` carries none at all and falls back to `default "HEAD"` in `deployApp.yaml`.

- **You never create a `versions/` dir to "support" an upgrade.** The `versions/ocp-<v>/`
  paths are emitted into both valueFiles stacks for *every* chart on *every* render —
  `ocpVersion` is always known, so the path is always constructible — and both stacks set
  `ignoreMissingValueFiles: true`. No dir ⇒ the layer resolves to nothing. No folder to
  create, no render error, no spec diff.
- A cluster OCP upgrade (§A) therefore produces **zero diff** for these charts. They are
  version-agnostic in the literal sense: the version simply never reaches them.
- **The two axes are independent per chart** (§5.3 table): a `main`-tracking chart can still
  take a 4.20-only `versions/ocp-4.20/values.yaml` with no `<chart>.yaml` beside it, and a
  pinned chart can share one `values.yaml` across every stream.
- **Escalating later is additive.** ako breaks on 4.22 → add `versions/ocp-4.22/ako.yaml`
  with a pin; only 4.22 clusters resolve it, every other stream stays on `main`. No
  restructure, no app rename, no generator change. Reverting is deleting that one file.

---

## 6. Why this is zero-impact (the mechanics)

- App identity = app name; every name is built from basenames that don't move. All phases
  below either add ignored files, add `ignoreMissingValueFiles` entries that don't exist yet,
  or re-parameterize generators while emitting identical app names → the ApplicationSet
  controller **updates in place**; nothing is deleted or recreated.
- Rendered **workload manifests stay byte-identical** until someone actually creates a
  version/env/defaults values file — Application *spec* diffs (longer valueFiles lists,
  labels) don't touch the cluster, and leaf apps are manual-sync anyway.
- Even a mistake degrades safely: a dropped generator entry deletes only the Application CR;
  workloads are orphaned in place (no finalizers) and re-adopted when the same-named app
  reappears (same name → same tracking id → clean adoption, no drift).

> **THE ONE INVARIANT — at any commit, each MCE / cluster / chart is emitted by exactly one
> generator entry.** This single rule is behind: one-commit `git mv`, the defaults XOR rule,
> add-glob-before-remove ordering, and the Phase-A-before-Phase-B precondition.

---

## 7. Migration plan

All of it is developed and render-verified in this mock first; each phase becomes a
hand-off (CHANGES.md style) applied to the air-gapped repos in order.

**Phase A — sigs repos: add marker files (additive, zero effect)**
Add `mce.yaml` to every existing `mces/<mce>/` folder and `hc.yaml` to every
`mces/<mce>/<cluster>/` folder:
MCE-level files carry `env`, `site`, `ocpVersion` (the MCE's own OCP version); cluster-level
files carry **only** `ocpVersion` (env/site are inherited from the MCE layer — §5.2). Plain files are invisible
to the current directory generators — this phase changes nothing anywhere.

**Phase B — platform: one MR (generator switch + path-parametric templates + labels)**
Everything in §5.7 except the `defaults/` glob changes.
> **HARD PRECONDITION (bold, like the exclude-first lesson): every team repo has completed
> Phase A before this MR merges.** A team without `config.yaml` files at switch time gets
> its `<group>-<mce>` apps deleted (children orphaned — workloads untouched but unmanaged
> until the files are added and the same-named apps recreate and re-adopt).
> Verification gate: rendered leaf workload manifests byte-identical for every existing app.

**Phase C — sigs repos: move the trees (per team, per MCE, one commit each)**
`git mv mces/<mce> sites/<site>/<env>/mces/<mce>`. Atomic move ⇒ one generator entry at all
times ⇒ same app names, same params (config.yaml is authoritative) ⇒ in-place updates only.
Never copy-then-delete across commits.

**Phase C' — defaults renames + the new hosted-clusters layer (non-prod content)**
Ordering is the *inverse* of exclude-first — **add the new glob first**:
1. Platform: add `defaults/hub/*` glob alongside `in-cluster/*`; add gen-3
   `defaults/hosted-clusters/*` (empty folder ⇒ zero apps); add `defaults/mces/*` alongside
   the `in-cluster-defaults` path in gen-2 + deployApp layers.
2. Sigs: `git mv in-cluster defaults/hub`, `git mv mces/in-cluster-defaults defaults/mces`
   (one commit each — the XOR invariant again).
3. Platform: remove the old globs/paths.
Do **not** remove an exclude or old glob while the old folder still exists.
(Heads-up: the planned DHCP hub tenant lands at `defaults/hub/dhcp-scope-manager/` instead
of `in-cluster/dhcp-scope-manager/`.)

**Phase D — cleanup**
Remove the legacy `mces/*/mce.yaml` glob from `mcesAppset.yaml`; switch env/site sourcing
from file content to path segments (`{{path[1]}}`/`{{path[2]}}`) — **template first**, then
delete the `env`/`site` fields from every MCE `config.yaml` (§5.2 ordering caveat); delete
emptied `mces/` dirs; update the three READMEs (naming rules — including the currently-undocumented cluster
naming convention — value-precedence tables, defaults XOR, config.yaml contract).

**Phase E — day1 becomes the version source (decision 9, 2026-08-17)**
Strictly ordered, add-first as always:
1. **Sigs:** create `operators/<chart>/versions/ocp-<full-version>/` for every pinned chart,
   for every version day1 currently reports — the old `ocp-4.16` folders stop matching once
   the key is `4.16.27`.
2. **Platform:** the multi-source change — `ref: day1` source + `$day1/...` valueFile in
   `mcesAppset`/`clustersAppset`, `mastertag` derived in `inClusterApp`/`operators`, the
   `ocp-version` label dropped from those two upper layers, and both generators switched
   back to `directories:`.
3. **Sigs:** delete every `mce.yaml`/`hc.yaml`, adding a `.gitkeep` to any cluster folder
   that would otherwise be left with no tracked content.

Step 3 must **not** run before step 2: while the `files:` generators are still live, deleting
a marker drops that generator entry and deletes the Application (children orphaned). After
step 2 a leftover marker is just an ignored plain file, so the window is safe in that
direction. Step 1 before step 2, or a pinned chart silently falls back to its team default on
the first render.

Each phase is independently revertible; because names never change, reverting a phase is
also an in-place update.

### Failure modes & controls

| Mistake | Consequence | Control |
|---|---|---|
| Team misses Phase A when B merges | its `<group>-<mce>` apps deleted; workloads orphaned, unmanaged | precondition gate; recovery = add config.yaml, apps recreate + re-adopt |
| Folder copied, not moved | duplicate app name in one appset — undefined/flapping | one-commit `git mv` rule; render check |
| Version unquoted (`4.20` → `4.2`) | wrong version layer resolved | quoting rule + render-time consistency check |
| config.yaml disagrees with path (migration window only — fields dropped in Phase D) | humans misread the tree | render-time path ⇔ config assertion |
| Fixing the frozen `namespace:` line "while in there" | fleet-wide app identity change → delete/recreate | explicitly frozen (§3.4) |
| **(9)** `versions/ocp-<new>/` not created before day1 flips the tag | pinned chart silently falls back to the team default — `ignoreMissingValueFiles` cannot tell "no layer needed" from "layer forgotten" | layer first, tag second (§5.8 §A); applies to z-streams too |
| **(9)** stray non-cluster folder under an MCE | phantom Application for a cluster that does not exist | the price of folder-only discovery; the render check's day1-parity lint fails it — a stray folder has no day1 version file |
| **(9)** cluster/MCE folder with no tracked content | git tracks no empty folder ⇒ the cluster is invisible to the generator | `.gitkeep` on onboarding |

---

## 8. Decisions taken — change any if you disagree

| # | Decision | Rationale / alternative |
|---|---|---|
| 1 | **`sites/<site>/<env>/`** (site first — user decision 2026-08-13) | Mechanically identical to env-first. "All prod" is not a single subtree, but env-scoped operations don't depend on the tree anyway: they use `config.yaml` data and `day2.gitops/env` label selectors (§5.5), and per-chart env-wide values live in `defaults/*/values-<env>.yaml`. |
| 2 | **Versions as `config.yaml` data**, not directories **[superseded in part by 9]** | §4.3. Alternative preserved in Appendix A. Still data rather than a path segment — but the data is day1's `mastertag`, not a file in this repo. |
| 3 | **Chart versions = branch-per-version in each chart repo + pin files** (user decision 2026-08-13, matching the operator-repo convention), not branch-per-OCP-version | §5.3; version branches are frozen at creation — a fix is a new branch, so day2 pins stay the single audit trail. Mechanically identical to tags for `targetRevision`; tags were the original recommendation. |
| 4 | **[superseded by 9 for the version half]** `config.yaml` is authoritative for **versions** always; for **env/site** only during the migration window — end-state derives env/site from path segments and drops the fields (your simplification, 2026-08-13). Cluster-level config never carries env/site at all. | The legacy layout has no env/site in its path and one template must serve both globs; once the legacy glob is gone, the per-depth marker filename (`mce.yaml`) makes the path trustworthy **[corrected: originally credited to "depth-exact matching", which a `files:` glob does not provide — see the amendment at the top]**, and both the duplication and the permanent consistency check disappear. |
| 5 | Version layers live at `operators/<chart>/versions/ocp-<v>/` | chart-centric (matches your `operators/ako/<ver>` instinct); everything about a chart in one folder |
| 6 | Leaf apps stay **manual-sync** by default | existing prod posture; upgrades stay operator-controlled; bulk ops via labels |
| 7 | Label prefix `day2.gitops/` (team-agnostic — the platform serves every team; team is a label *value*) on all generated apps | §5.5; ships safely even before the tree refactor |
| 8 | **No MCE-version dimension — `ocpVersion` is the single version key**, meaning the OCP version of the app's destination cluster (user decision 2026-08-13; e.g. `ocp4-prep-mce-five-a` runs OCP 4.20 → all charts deployed to it resolve `ocp-4.20` layers) **[the single-key half stands; the marker-file half is superseded by 9]** | One key with override semantics down the chain; one `versions/ocp-<v>/` layer family; MCE and cluster `config.yaml` share a schema. The prod-hub stays version-less (this decision covers MCEs and hosted clusters only). |
| 9 | **The version belongs to day1, not to the sigs repos** (user decision 2026-08-17). Each cluster's OCP version is resolved at render time from `gitops-day1/platform-config` — `sites/<site>/mces/<mce>/version.yaml` (MCE, **AMENDMENT 2**) and `sites/<site>/mces/<mce>/hostedClusters/<hc>.yaml` (hosted cluster), key `mastertag`, day1 having **no `<env>` level**. A sig repo declares no version at all. `ocpVersion` becomes the **full patch version** (`4.16.27`, from `4.16.27-x86_64`), so `versions/ocp-<v>/` layers are per exact version. **This supersedes the marker-file mechanism of decision 8:** `mce.yaml`/`hc.yaml` existed only to carry `ocpVersion` as data, so with the version gone they are **deleted** and discovery returns to depth-exact `directories:` generators (`sites/*/*/mces/*`; `<mcePath>/*` minus `in-cluster`) — Go `path.Match` bounds the depth, which is the job the marker filenames were invented for (AMENDMENT 1). | The air-gap has **five** sig repos: the same physical cluster's version was written in all five and had to be bumped in all five, and any of them could silently disagree with what day1 actually installed. One day1 edit now upgrades a cluster for every sig at once, and the value is the tag day1 provisioned, not a human's copy of it. Costs, both accepted: (a) **every** upgrade including z-streams needs `versions/ocp-<new>/` created *before* day1 flips the tag, or a pinned chart silently falls back to the team default; (b) folder-only discovery means an onboarded-but-empty folder needs a `.gitkeep`, and a stray folder under an MCE becomes a phantom Application — both caught offline by the render check's day1-parity lint (a stray folder has no day1 file). The version is `required` at both derivation points, so a cluster day1 doesn't know fails the render loudly instead of deploying version-less. |
| 9a | **AMENDMENT 2 (user decision 2026-08-18): an MCE's version lives in its own day1 file, `sites/<site>/mces/<mce>/version.yaml`, not in the MCE's `values.yaml`.** Key and format unchanged (`mastertag`, arch suffix optional), so both derivation points, `render_chain.py`'s reader and the day1 `grep -r mastertag` recipe are untouched — only the path moves. | The MCE's `values.yaml` is a **live day1 chart input**, where `mastertag` already means *the default version for the hosted clusters under this MCE*, overridden by each HC's own file. It was inert only because every HC happened to override it — an accident of data, not a contract — and it failed silently both ways: an HC added without its own tag would be **provisioned** at what day2 read as the hub's version, and anyone editing that default would re-version the hub's in-cluster apps in every sig, with day1's CI blind to it because day1's chart never reads the key. A dedicated file also drops the MCE layer out of the E.0-4 key-collision audit entirely (day2 stops importing `dhcp_values` and friends). Accepted cost: `version.yaml` is **hand-maintained** — no day1 field records a hub's version, so decision 9's "the value is the tag day1 provisioned, not a human's copy" holds for hosted clusters only, and a hub upgrade must edit this file (no offline check can catch a stale one). Rejected alternative: renaming the key to `version:` — it would split the vocabulary across the two layers, needing a per-layer reader in `render_chain.py`, a key column in the Phase E table, ~a dozen doc caveats, and it would break the day1 `grep -r mastertag` sweep for MCEs. |

---

## 9. Verification (when implementing)

1. **Render harness** (as in previous sessions): helm-template the full chain
   (groups→mces→clusters→operators→deploy) for every MCE/cluster/chart, before vs. after
   each phase; assert leaf workload manifests are byte-identical where no new values file
   exists, and only expected diffs elsewhere (labels, valueFiles lists).
2. **Consistency checks**: config.yaml ⇔ path agreement; versions quoted as strings; env
   folder names ∈ {prod, prep, test}; each chart emitted by exactly one generator entry
   (XOR / invariant check).
3. **Dry-run in mock**: simulate a hosted-cluster upgrade (edit its `ocpVersion`), an MCE
   upgrade (edit the MCE's `ocpVersion` — its in-cluster charts must re-pin, hosted clusters
   under it must NOT change), and a fleet chart upgrade (edit a `versions/ocp-<v>` pin), and
   diff renders.

> **[superseded by decision 9, 2026-08-17 — checks 2 and 3]** With no version declared in the
> repo, the config ⇔ path and quoting checks have nothing to check. Their replacement is the
> **day1-parity lint**: every folder matching `sites/*/*/mces/*` and every non-`in-cluster`
> folder inside one must have a day1 file carrying a well-formed
> `mastertag: <major>.<minor>.<patch>[-<arch>]` — which is simultaneously the version check,
> the stray-folder check and the "day1 hasn't provisioned this yet" check. Env-folder and XOR
> checks are unchanged. The dry-runs move to the day1 side: flip a `mastertag` in a day1
> checkout and diff renders (the harness takes the day1 root as an argument).
4. Air-gap preconditions per phase in the hand-off doc (AppProject permissions already
   flagged in CHANGES.md for hub apps remain relevant).

---

## Appendix A — if you insist on version directories

Safe variant of your original draft: `sites/<site>/<env>/mces/<mce-ocp-ver>/<mce>/<hc-ocp-ver>/<cluster>/<chart>/`
(both version segments are OCP versions — no MCE-version dimension here either),
directory generators with depth-exact globs, env/site/versions extracted from `{{path[n]}}`
segments instead of config.yaml. Upgrade = one-commit `git mv` of the cluster folder — safe
because app names contain no version segment (§4.2), but every upgrade is a tree move, the
invariant must be re-enforced manually each time, and adding future metadata means another
level or a config file anyway. All other sections of this plan (defaults/, pins, labels,
migration ordering) apply unchanged.
