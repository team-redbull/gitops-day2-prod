# sigs/redbull — day2 team repo

Everything this team deploys through the day2 GitOps platform lives here.
The platform (`argocd-day2-prod/argocd-day2-platform`) scans this repo with
ApplicationSet generators; **folders are discovered, files are read — nothing
is registered anywhere else**. The deep-dive is in `ARCHITECTURE.md` at
the day2 repo root next to `CHANGES.md` (in the air-gapped env, keep a copy in
the platform repo); this README is the working contract.

## The tree

```
sigs/redbull/
├── sites/                              # WHERE things run (identity: site, env)
│   └── <site>/                         # site1, five, ...
│       ├── values.yaml                 # optional site-wide values (use sparingly)
│       └── <env>/                      # prod | prep | test — nothing else
│           ├── values.yaml             # optional site+env values
│           └── mces/
│               └── <mce>/              # folder name == Argo cluster name
│                   ├── config.yaml     # ocpVersion of the MCE itself (REQUIRED)
│                   ├── values.yaml     # optional MCE-wide values
│                   ├── in-cluster/     # charts on the MCE hub itself
│                   │   └── <chart>/{<chart>.yaml, values.yaml}
│                   └── <cluster>/      # folder name == Argo cluster name
│                       ├── config.yaml # ocpVersion of the cluster (REQUIRED)
│                       ├── values.yaml # optional cluster-wide values
│                       └── <chart>/{<chart>.yaml, values.yaml}
├── operators/                          # WHAT can run (per-chart, team-wide; never generator-scanned)
│   └── <chart>/
│       ├── <chart>.yaml                # team-default deploy config (default version pin)
│       ├── values.yaml                 # team-default values
│       └── versions/                   # ONLY for version-sensitive charts
│           └── ocp-<v>/{<chart>.yaml, values.yaml}   # per OCP stream
└── defaults/                           # deploy-once-to-a-whole-fleet layers
    ├── hub/                            # → the prod-hub mgmt cluster (see its README)
    ├── mces/                           # → every MCE hub          (see its README)
    └── hosted-clusters/                # → every hosted cluster   (see its README)
```

## Naming rules

1. **A folder's name is the destination cluster name as seen by the Argo that
   consumes it.** MCE and hosted-cluster folder basenames must equal the Argo
   cluster names exactly — cluster names are flat and global, the sites/ tree
   does not relax that. `in-cluster` is every Argo's name for its own cluster:
   under an MCE folder it means the MCE hub; in `defaults/hub` context it is
   prod-hub.
2. **Cluster naming convention:** `ocp4-<env>-<name>-<site>[-<seq>]` — e.g.
   `ocp4-prod-mce-site1-a` (an MCE), `ocp4-prep-eyal-site1` (a hosted
   cluster). The env and site in the name must agree with the folder's
   position in the sites/ tree.
3. **Application names are built from basenames only**
   (`redbull-<cluster>-<chart>-deploy`) — path levels above them never appear
   in an app name. That is why folders can move without apps being recreated.

## config.yaml — the cluster registry entry

Presence of `config.yaml` is what makes a folder an MCE or a hosted cluster;
a folder without one is invisible to the generators (that is why `in-cluster/`
and chart folders are never mistaken for clusters). It carries exactly one
key:

```yaml
ocpVersion: "4.20"   # the folder's OWN cluster. ALWAYS quote — 4.20 unquoted is the float 4.2
```

- env/site are **never** written here — they come from the path
  (`sites/<site>/<env>/`).
- `ocpVersion` selects the `operators/<chart>/versions/ocp-<v>/` layers for
  every chart deployed to that cluster. An MCE's own version governs its
  in-cluster charts; each hosted cluster's version governs its charts.
- **A cluster OCP upgrade is a one-line edit of this file.** No folder moves.

## Chart folders and the two value stacks

Every chart folder holds `<chart>.yaml` (deploy config: `repourl` —
all-lowercase! — `targetRevision`, `path`, `projectNamespace`, `syncPolicy`,
`ignoreDifferences`, ...) and `values.yaml` (helm values for the workload).
Both stacks resolve lowest → highest, every layer optional
(`ignoreMissingValueFiles`); the most context-specific file wins:

Deploy config: `operators/<c>/<c>.yaml` → `operators/<c>/versions/ocp-<v>/<c>.yaml`
→ defaults layer (`defaults/{mces,hosted-clusters}/<c>/<c>.yaml`) → the
cluster's own `<c>/<c>.yaml`.

Workload values: `operators/<c>/values.yaml` → `versions/ocp-<v>/values.yaml`
→ `sites/<site>/values.yaml` → `sites/<site>/<env>/values.yaml` → defaults
layers (`values.yaml`, `values-<env>.yaml`, `values-<mce|cluster>.yaml`) →
MCE-wide → cluster-wide → the cluster's own chart `values.yaml`.

## Version pinning (charts)

Pin values are **branch names in the chart's own repo**; a version branch is
frozen at creation — a fix is a new branch, never a push to an existing one.

| Scope | File |
|---|---|
| Team default | `operators/<chart>/<chart>.yaml` (`targetRevision`) |
| One OCP stream (the fleet op) | `operators/<chart>/versions/ocp-<v>/<chart>.yaml` |
| One cluster (emergency) | `sites/.../<cluster>/<chart>/<chart>.yaml` |

Charts that track `main` (most of them) simply have no `versions/` dir —
nothing to create, nothing changes for them on cluster upgrades.

⚠️ A `targetRevision` in a `defaults/*/<chart>/<chart>.yaml` file sits ABOVE
the stream-pin layer and silently overrides it. Keep `targetRevision` out of
defaults configs for any chart that should follow stream pins.

## Hard rules

- **XOR:** a chart lives in a defaults folder OR in a specific
  cluster/in-cluster folder — never both (duplicate Application names).
- **One-commit moves:** moving any folder is a single `git mv` commit; never
  copy-then-delete across commits (transient duplicate generator entries).
- **Verify before merge:** platform-layer apps run `selfHeal: true` — run the
  render check (`tools/render-verify/` in the mock repo) on every structural
  change; there is no post-merge inspection window.
