# sigs/redbull — day2 team repo

Everything this team deploys through the day2 GitOps platform lives here.
The platform (`argocd-day2-prod/argocd-day2-platform`) scans this repo with
ApplicationSet generators; **folders are discovered, files are read — nothing
is registered anywhere else**. The one thing not declared here is the OCP
version of MCEs and hosted clusters — it is read from the day1 repo at render
time (see below); UPI clusters may declare their own. The
deep-dive is in `ARCHITECTURE.md` at the day2 repo root next to `CHANGES.md`
(in the air-gapped env, keep a copy in the platform repo); this README is the
working contract.

## The tree

```
sigs/redbull/
├── sites/                              # WHERE things run (identity: site, env)
│   └── <site>/                         # site1, five, ...
│       ├── values.yaml                 # optional site-wide values (use sparingly)
│       └── <env>/                      # prod | prep | test — nothing else
│           ├── values.yaml             # optional site+env values
│           ├── mces/
│           │   └── <mce>/              # THE FOLDER IS THE MCE (no registry file)
│           │       ├── values.yaml     # optional MCE-wide values
│           │       ├── in-cluster/     # charts on the MCE hub itself
│           │       │   └── <chart>/{<chart>.yaml, values.yaml}
│           │       └── <cluster>/      # any other folder here IS a hosted cluster
│           │           ├── values.yaml # optional cluster-wide values
│           │           └── <chart>/{<chart>.yaml, values.yaml}
│           └── upi/
│               ├── values.yaml         # optional: every UPI cluster at this site+env
│               └── <cluster>/          # THE FOLDER IS THE UPI CLUSTER (standalone, no MCE)
│                   ├── version.yaml    # optional: `mastertag` only (see below)
│                   ├── values.yaml     # optional cluster-wide values
│                   └── <chart>/{<chart>.yaml, values.yaml}
├── operators/                          # WHAT can run (per-chart, team-wide; never generator-scanned)
│   └── <chart>/
│       ├── <chart>.yaml                # team-default deploy config (default version pin)
│       ├── values.yaml                 # team-default values
│       └── ocp-versions/               # ONLY for version-sensitive charts
│           └── <v>/{<chart>.yaml, values.yaml}       # per OCP version, FULL: 4.16.27
└── defaults/                           # deploy-once-to-a-whole-fleet layers
    ├── hub/                            # → the prod-hub mgmt cluster (see its README)
    ├── mces/                           # → every MCE hub          (see its README)
    │   └── exclusions.yaml             # optional: the ONE structural opt-out
    ├── hosted-clusters/                # → every hosted cluster   (see its README)
    │   └── exclusions.yaml             # optional: same, keyed by chart
    └── upi/                            # → every UPI cluster      (see its README)
        └── exclusions.yaml             # optional: same, keyed by chart
```

## Naming rules

1. **A folder's name is the destination cluster name as seen by the Argo that
   consumes it.** MCE, hosted-cluster and UPI folder basenames must equal the
   Argo cluster names exactly — a UPI cluster's as registered on the UPI Argo
   instance (`openshift-gitops-upi`). Cluster names are flat and global, the
   sites/ tree does not relax that. `in-cluster` is every Argo's name for its own cluster:
   under an MCE folder it means the MCE hub; in `defaults/hub` context it is
   prod-hub.
2. **Cluster naming convention:** `ocp4-<env>-<name>-<site>[-<seq>]` — e.g.
   `ocp4-prod-mce-site1-a` (an MCE), `ocp4-prep-eyal-site1` (a hosted
   cluster). The env and site in the name must agree with the folder's
   position in the sites/ tree. **UPI clusters are exempt** — their names
   predate day2 (`ocp4-dok-site1` has no env); for them the folder position
   alone sets env and site. A UPI name may never reuse an MCE or hosted-cluster
   name, nor be `in-cluster` (the render check enforces both).
3. **Application names are built from basenames only**
   (`redbull-<cluster>-<chart>-deploy`) — path levels above them never appear
   in an app name. That is why folders can move without apps being recreated.

## What makes a folder a cluster

There is **no registry file** — a cluster declares itself by existing:

- a folder under `sites/<site>/<env>/mces/` **is** an MCE;
- any folder inside an MCE folder except `in-cluster/` **is** a hosted
  cluster of that MCE;
- a folder under `sites/<site>/<env>/upi/` **is** a UPI cluster: a
  standalone cluster with no MCE and no Argo of its own. prod-hub's day2 Argo
  discovers it and hands its charts to the UPI Argo instance
  (`openshift-gitops-upi`), which deploys them.

All three are `directories:` generators (`sites/*/*/mces/*`, `<mcePath>/*`
minus `in-cluster`, and `sites/*/*/upi/*`), and there `*` matches exactly one
path segment — the depth is exact by construction, so env and site are read
straight off the path and never written anywhere.

- **Onboarding a cluster = creating its folder.** git cannot track an empty
  folder, so a cluster (or MCE) that has no chart of its own yet needs a
  `.gitkeep` inside it to exist in the repo at all.
- ⚠️ **Nothing but clusters lives under an MCE folder or `upi/`.** A stray
  folder (docs, scripts, a scratch copy) becomes a phantom Application aimed
  at a cluster that does not exist. Under an MCE the render check catches it
  before merge — a stray folder has no day1 version file. Under `upi/` there
  is no day1 file to check, so the only signal is an unexpected
  `apps added` line in the render compare: read it.

## Where the OCP version comes from

For MCEs and hosted clusters, not from here. Their version is owned by the
day1 repo (`gitops-day1/platform-config`) that provisioned them, as
`mastertag`, and is resolved at Argo render time:

| this repo | the file that holds the version |
|---|---|
| `sites/<site>/<env>/mces/<mce>/` | day1 `sites/<site>/mces/<mce>/version.yaml` |
| `sites/<site>/<env>/mces/<mce>/<cluster>/` | day1 `sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml` |
| `sites/<site>/<env>/upi/<cluster>/` | **this repo**, `<that folder>/version.yaml` — optional |

The day1 tree has **no `<env>` level** (env lives only inside the cluster
name), and a hosted-cluster folder name equals its day1 file name minus
`.yaml`.

- `mastertag: 4.16.27-x86_64` → `ocpVersion: 4.16.27` (the arch suffix is
  stripped at the first `-`, the rest used verbatim). That version selects
  the `operators/<chart>/ocp-versions/<v>/` layers for every chart deployed
  to that cluster: an MCE's own version governs its in-cluster charts, each
  hosted cluster's version governs its charts.
- **A cluster OCP upgrade is a day1 edit — nothing changes in this repo.**
  One physical cluster, one version, shared by all five sig repos instead of
  duplicated in each.
- An MCE or hosted cluster with no day1 entry **fails the render loudly**;
  nothing ever deploys with a silently empty version.
- **UPI clusters are the one exception.** day1 does not know them, so a UPI
  folder may carry its own `version.yaml` — `mastertag: 4.16.27-x86_64` and
  nothing else (any other key would land as a chart value; the render check
  rejects it). With it, the `ocp-versions/<v>/` layers apply as for any other
  cluster. **Without it the cluster is version-less, like prod-hub**: no
  version layers, no `ocp-version` label, and a version-pinned chart gets its
  team default. The file is hand-maintained and per team repo: a UPI upgrade
  is one edit in every sigs repo that has the cluster.

## Chart folders and the two value stacks

Every chart folder holds `<chart>.yaml` (deploy config: `repourl` —
all-lowercase! — `targetRevision`, `path`, `projectNamespace`, `syncPolicy`,
`ignoreDifferences`, ...) and `values.yaml` (helm values for the workload).
Both stacks resolve lowest → highest, every layer optional
(`ignoreMissingValueFiles`); the most context-specific file wins:

Deploy config: `operators/<c>/<c>.yaml` → `operators/<c>/ocp-versions/<v>/<c>.yaml`
→ defaults layer (`defaults/{mces,hosted-clusters,upi}/<c>/<c>.yaml`) → the
cluster's own `<c>/<c>.yaml`.

Workload values: `operators/<c>/values.yaml` → `ocp-versions/<v>/values.yaml`
→ `sites/<site>/values.yaml` → `sites/<site>/<env>/values.yaml` → defaults
layers (`values.yaml`, `values-<env>.yaml`, `values-<mce|cluster>.yaml`) →
MCE-wide (UPI: `sites/<site>/<env>/upi/values.yaml`) → cluster-wide → the
cluster's own chart `values.yaml`.

The site and site+env files are shared by every kind of cluster at that site
on purpose: they hold site facts (registry, DNS, proxy). A value only UPI
clusters should see goes in `defaults/upi/` or `sites/<site>/<env>/upi/values.yaml`.

## Version pinning (charts)

Pin values are **branch names in the chart's own repo**; a version branch is
frozen at creation — a fix is a new branch, never a push to an existing one.

| Scope | File |
|---|---|
| Team default | `operators/<chart>/<chart>.yaml` (`targetRevision`) |
| One OCP version (the fleet op) | `operators/<chart>/ocp-versions/<v>/<chart>.yaml` |
| One cluster (emergency) | `sites/.../<cluster>/<chart>/<chart>.yaml` |

`<v>` is the **full** version derived from day1's `mastertag` —
`ocp-versions/4.16.27/`, never `ocp-versions/4.16/`. Every layer is per exact patch
version.

⚠️ **Create the `ocp-versions/<new>/` layer BEFORE day1 flips the tag** — on
every upgrade, z-streams included. A missing layer is not an error:
`ignoreMissingValueFiles` cannot tell "no layer needed" from "layer
forgotten", so a pinned chart silently falls back to the team default in
`operators/<chart>/<chart>.yaml`.

Charts that track `main` (most of them) simply have no `ocp-versions/` dir —
nothing to create, nothing changes for them on cluster upgrades.

⚠️ A `targetRevision` in a `defaults/*/<chart>/<chart>.yaml` file sits ABOVE
the version-pin layer and silently overrides it. Keep `targetRevision` out of
defaults configs for any chart that should follow version pins.

## Opting one cluster out of a fleet default

A chart folder in `defaults/mces/` reaches **every** MCE hub, one in
`defaults/hosted-clusters/` **every** hosted cluster, and one in
`defaults/upi/` **every** UPI cluster. To carve out exceptions,
name them per chart in that folder's `exclusions.yaml`:

```yaml
# defaults/mces/exclusions.yaml
exclusions:
  dhcp-api-token:
    - ocp4-prep-mce-site1-a
```

Absent is the normal state. Keys are chart folders in that same directory,
values are MCE names (hosted-cluster or UPI cluster names, in the other
scopes) — a typo on
**either** axis is silent at runtime and the chart just keeps deploying, so
the pre-merge check is the only thing that catches it. There is no
`defaults/hub/exclusions.yaml`.

Need different *values* rather than absence? Use `values-<mce>.yaml` /
`values-<cluster>.yaml` instead — an exclusion is the heavier tool, and it
does **not** uninstall anything already running.

Details: each defaults folder's README (`## Structural opt-out`). Procedure,
teardown and undo: `ARCHITECTURE.md` runbook R10.

## Hard rules

- **XOR:** a chart lives in a defaults folder OR in a specific
  cluster/in-cluster folder — never both (duplicate Application names).
- **One-commit moves:** moving any folder is a single `git mv` commit; never
  copy-then-delete across commits (transient duplicate generator entries).
- **Verify before merge:** platform-layer apps run `selfHeal: true` — run the
  render check (`tools/render-verify/` in the mock repo) on every structural
  change; there is no post-merge inspection window.
