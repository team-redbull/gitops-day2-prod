# `argocd-day2-platform` — the day2 GitOps machinery

*Zero-to-hero guide to the Argo CD chain that turns folders in a team repo
into running workloads on every cluster in the fleet.*

This repo is **the machinery**. It contains five small Helm charts that render
**nothing but Argo CD `Application` and `ApplicationSet` objects**. No
workload, no CRD, no config map of anyone's app ever comes out of here — only
Argo objects that point at other repos.

Teams rarely touch this repo. They work in their own repo
(`gitops-day2-prod/sigs/<team>`) by creating folders and small YAML files.
This README is for the person who has to *understand or change the chain
itself* — and for the new teammate who wants to know why a folder in a
completely different repo turned into a running chart.

| Doc | What it is |
|---|---|
| **this README** | the platform chain: every chart, every template, every value it passes |
| `ARCHITECTURE.md` (day2 repo root) | the team-facing guide: the `sites/` tree, day-to-day runbooks (Part III), rationale |
| `CHANGES.md` (day2 repo root) | the air-gap migration hand-off — how the current layout was reached |
| `sigs/<team>/README.md` | the working contract for team-repo authors |
| `tools/render-verify/render_chain.py` | the offline harness that simulates this entire chain before merge |

---

## Table of contents

1. [The 30-second version](#1-the-30-second-version)
2. [The world this platform manages](#2-the-world-this-platform-manages)
3. [The chain at a glance](#3-the-chain-at-a-glance)
4. [Follow one chart end to end](#4-follow-one-chart-end-to-end)
5. [Prerequisites that make the chain work](#5-prerequisites-that-make-the-chain-work)
6. [Template-by-template reference](#6-template-by-template-reference)
7. [Every value in the chain](#7-every-value-in-the-chain)
8. [Where you can define values — the two stacks](#8-where-you-can-define-values--the-two-stacks)
9. [Deploy-config keys the platform reads](#9-deploy-config-keys-the-platform-reads)
10. [Versions — day1 owns them](#10-versions--day1-owns-them)
11. [Labels and fleet operations](#11-labels-and-fleet-operations)
12. [Discovery mechanics — `directories:` vs `files:`](#12-discovery-mechanics--directories-vs-files)
13. [The frozen line — do not fix it](#13-the-frozen-line--do-not-fix-it)
14. [Safety model and invariants](#14-safety-model-and-invariants)
15. [Verify before merge](#15-verify-before-merge)
16. [Glossary](#16-glossary)

---

## 1. The 30-second version

> **Folders say WHERE things run. The day1 repo says WHICH VERSION runs
> there. This repo is the plumbing between the two.**

- Five charts, each rendering the next: `groups` → `mces` → `clusters` →
  `operators` → `deploy`.
- Every discovery step is a **git `directories:` generator** — a folder
  existing *is* the registration. There is no registry file, no marker file,
  no UI step.
- Each hop passes a handful of values down (`group`, `mce`, `mcePath`,
  `cluster`, `clusterPath`, `env`, `site`, `ocpVersion`, `operator`; for UPI
  clusters also `upi`, `upiPath`, `argoNamespace`) and every later template
  builds its file paths out of them.
- MCE and hosted-cluster OCP versions come from a **different repo**
  (`gitops-day1/platform-config`), resolved at render time through a
  multi-source Argo app. No sig repo declares their version. UPI clusters are
  the one exception: day1 does not know them, so their folder may carry an
  optional `version.yaml` (§10).
- Configuration is layered: every layer is a **slot** — a value-file path that
  is always listed and may not exist (`ignoreMissingValueFiles: true`
  everywhere). Most slots are empty. That is normal.

Three orientation examples:

| You want to... | Someone does... | This repo... |
|---|---|---|
| deploy a chart to one cluster | adds a folder with 2 files under that cluster in `sigs/<team>` | the `operators` generator finds the folder and renders a leaf app |
| deploy a chart to every hosted cluster | adds a folder under `sigs/<team>/defaults/hosted-clusters/` | a second `operators` generator fans it out — same template, byte-identical app |
| ...except on two of them | names them under that chart in `defaults/hosted-clusters/exclusions.yaml` | the same generator gains `exclude:` entries for those paths (§6.7) |
| upgrade a cluster to OCP 4.20.9 | edits one line in the **day1** repo | the chain re-renders `ocpVersion`, and every version-keyed value path with it |
| deploy charts to a standalone (UPI) cluster | adds `sigs/<team>/sites/<site>/<env>/upi/<cluster>/` | `upiAppset` hands the cluster's `operators` chart to the UPI Argo instance, which deploys it (§6.9) |

---

## 2. The world this platform manages

```
                 prod-hub  (the top management cluster — runs the top Argo)
                 │
                 ├── ocp4-prod-mce-site1-a   (an MCE hub — runs its OWN Argo)
                 │     ├── ocp4-prod-herzi-site1     (hosted cluster — no Argo)
                 │     └── ocp4-prod-karniol-site1   (hosted cluster — no Argo)
                 │
                 ├── ocp4-prep-mce-site1-a   (an MCE hub — runs its OWN Argo)
                 │     ├── ocp4-prep-itay-site1
                 │     └── ocp4-prep-eyal-site1
                 │
                 └── [ UPI Argo instance, openshift-gitops-upi — a SECOND Argo on prod-hub ]
                       └── ocp4-dok-site1          (UPI cluster — standalone, no MCE, no Argo)
```

**Four kinds of destination, and they behave differently:**

| Destination | Runs an Argo? | Reached by | Version-aware? |
|---|---|---|---|
| **prod-hub** | yes, the top one | the `hub` flow (`mces` chart → `deploy`) | **no** — hub is version-less |
| **MCE hub** ("in-cluster") | yes, its own | the `mces` → `clusters` → static in-cluster app → `operators` → `deploy` flow | yes — by the MCE's own OCP version |
| **hosted cluster** | no | `clusters` appset → `operators` → `deploy`, all running on the MCE's Argo | yes — by its own OCP version |
| **UPI cluster** | no | `mces` → `upiAppset` wrapper on prod-hub → `operators` → `deploy` on the **UPI Argo instance** (`openshift-gitops-upi`, on prod-hub) | optional — by its own `version.yaml` in the sigs repo; version-less without one |

**Four repos are involved:**

| Repo | Role |
|---|---|
| `gitops-day2-prod/argocd-day2-platform` | **this one** — renders Argo objects only |
| `gitops-day2-prod/sigs/<team>` | the team repo — folders and small YAML files. Referenced as **`$values`** in every value path below |
| `gitops-day1/platform-config` | the repo that *provisions* clusters, so it owns their OCP versions (`mastertag`). Referenced as **`$day1`**. Day2 reads it, never writes it |
| `helm-charts/<chart>` | the real workload charts, one repo each, one frozen branch per release |

`$values` and `$day1` are Argo **multi-source refs**: a source declared with
`ref: <name>` contributes no manifests, only a checkout that later
`valueFiles` entries can address as `$<name>/...`.

**Which Argo runs which layer** matters when you go looking for an object:

- `groups`, `mces` (its four appsets and the static `<team>-upi-app-project`
  app) and the hub `deploy` apps live on **prod-hub's day2 Argo**
  (`openshift-gitops`). So do the UPI wrappers `<team>-<cluster>`.
- `clusters` (its appset plus the static in-cluster app), `operators` and
  every MCE and hosted-cluster `deploy` leaf live on **the MCE's Argo** — the
  leaf's *destination* is the hosted cluster, but the `Application` object
  itself sits on the MCE.
- For a UPI cluster, `operators` and its `deploy` leaves live on the **UPI Argo
  instance**, in namespace `openshift-gitops-upi` on prod-hub. The wrapper on
  prod-hub's day2 Argo writes them there: a hop by namespace instead of by
  cluster, because the UPI Argo already holds the UPI cluster secrets.
- Label selectors are therefore per-Argo: an `argocd app list -l ...` run
  against prod-hub will not see anything an MCE or the UPI Argo renders.

---

## 3. The chain at a glance

Each row renders the chart in the next row.

| # | Chart / template | Runs on | Generator | Emits | Feeds |
|---|---|---|---|---|---|
| 1 | `groups/templates/groupsAppset.yaml` | prod-hub | `scmProvider` (GitLab group `243709`) | App `<team>` | the `mces` chart |
| 2 | `mces/templates/mcesAppset.yaml` | prod-hub | dirs `sites/*/*/mces/*` | App `<team>-<mce>`, destination = **the MCE** | the `clusters` chart, **on the MCE** |
| 3 | `mces/templates/appProjectAppset.yaml` | prod-hub | `clusters: {}` | App `<team>-app-projects-<cluster>` (sync-wave −1) | the external `argo-appproject` chart |
| 4 | `mces/templates/inClusterAppset.yaml` | prod-hub | dirs `defaults/hub/*` | App `<team>-in-cluster-<chart>` | the `deploy` chart in **hub mode** |
| 5 | `clusters/templates/clustersAppset.yaml` | the MCE | dirs `<mcePath>/*` minus `<mcePath>/in-cluster` | App `<team>-<cluster>` | the `operators` chart |
| 6 | `clusters/templates/inClusterApp.yaml` | the MCE | **none** — always rendered | App `<team>-in-cluster` | the `operators` chart, `cluster: in-cluster` |
| 7 | `operators/templates/operators.yaml` | the MCE (the UPI Argo, for UPI) | dirs ×2: `<clusterPath>/*` **+** one of `defaults/mces/*` (MCE hub), `defaults/upi/*` (UPI) or `defaults/hosted-clusters/*` (hosted), the defaults one carrying `exclude:` entries from `exclusions.yaml` | App `<team>-<cluster>-<chart>` | the `deploy` chart |
| 8 | `deploy/templates/deployApp.yaml` | the MCE (prod-hub in hub mode, the UPI Argo for UPI) | — | App `<team>-<cluster>-<chart>-deploy` — **the workload** | `helm-charts/<chart>` |
| 9 | `mces/templates/upiAppset.yaml` | prod-hub | dirs `sites/*/*/upi/*` | App `<team>-<cluster>`, destination = **`openshift-gitops-upi`** | the `operators` chart, **on the UPI Argo** |
| 10 | `mces/templates/upiAppProjectApp.yaml` | prod-hub | **none** — always rendered | App `<team>-upi-app-project` (sync-wave −1) | the external `argo-appproject` chart, into `openshift-gitops-upi` |

```
 prod-hub Argo                                    the MCE's Argo
 ─────────────                                    ──────────────
 groupsAppset  ──▶ App: redbull
                        │ renders chart: mces
                        ├──▶ mcesAppset ──▶ App: redbull-<mce> ─────────────▶ renders chart: clusters
                        │                    (destination = the MCE)              │
                        ├──▶ appProjectAppset ──▶ AppProject on every cluster     │
                        │                                                         │
                        └──▶ inClusterAppset ──▶ App: redbull-in-cluster-<chart>  │
                                                    │ renders chart: deploy       │
                                                    │        (hub: true)          │
                                                    ▼                             │
                                       App: ...-deploy ▶ prod-hub                 │
                                                                                  │
        ┌─────────────────────────────────────────────────────────────────────────┘
        │
        ├──▶ clustersAppset ──▶ App: redbull-<hosted-cluster> ─┐
        │                                                      │ renders chart: operators
        └──▶ inClusterApp (static) ──▶ App: redbull-in-cluster ┤
                                                               ▼
                                        operators appset ──▶ App: redbull-<cluster>-<chart>
                                                                     │ renders chart: deploy
                                                                     ▼
                                             App: redbull-<cluster>-<chart>-deploy
                                             destination: <cluster>  ◀── THE WORKLOAD
```

UPI clusters take a shorter path. There is no MCE, so the hop goes to the
second Argo instance on prod-hub, by namespace:

```
 prod-hub day2 Argo (openshift-gitops)             UPI Argo instance (openshift-gitops-upi)
 ─────────────────────────────────────             ────────────────────────────────────────
 App: redbull  (mces chart)
   ├──▶ upiAppProjectApp ──▶ AppProject redbull ──▶ (in openshift-gitops-upi)
   └──▶ upiAppset ──▶ App: redbull-<upi> ─────────▶ renders chart: operators
                      (destination: in-cluster /        │ operators appset
                       openshift-gitops-upi)            ▼
                                                  App: redbull-<upi>-<chart>
                                                        │ renders chart: deploy
                                                        ▼
                                                  App: redbull-<upi>-<chart>-deploy
                                                  destination: <upi>  ◀── THE WORKLOAD
```

**Why there is a `hub` shortcut.** The hub flow goes `mces` → `deploy`
directly and **never renders the `operators` chart**. That single fact is the
mechanical cause of everything special about hub apps: the hub app declares no
`$day1` source, so no `mastertag` ever reaches it, and the `operators` chart —
the only place `mastertag` becomes `ocpVersion` for a `deploy` app — is never
rendered. Hence no `ocp-versions/<v>/` layer and no `day2.gitops/ocp-version`
label on hub apps. It is also outside the `sites/` tree, so there are no
site/env value layers to resolve.

---

## 4. Follow one chart end to end

Say this exists in the team repo:

```
sigs/redbull/sites/site1/prod/mces/ocp4-prod-mce-site1-a/ocp4-prod-herzi-site1/cluster-roles/
    ├── cluster-roles.yaml   # deploy config: which repo, which branch, which namespace
    └── values.yaml          # workload values
```

and this exists in the day1 repo:

```yaml
# gitops-day1/platform-config/sites/site1/mces/ocp4-prod-mce-site1-a/hostedClusters/ocp4-prod-herzi-site1.yaml
mastertag: 4.16.27-x86_64
```

1. **prod-hub discovers the team.** `groupsAppset` scans the GitLab group,
   finds the repo `redbull`, and creates the Application `redbull` — which
   renders this repo's **`mces`** chart with a single value, `group: redbull`.
2. **prod-hub discovers the MCE.** `mcesAppset` lists directories matching
   `sites/*/*/mces/*`. It finds
   `sites/site1/prod/mces/ocp4-prod-mce-site1-a` and creates
   `redbull-ocp4-prod-mce-site1-a`, whose **destination is the MCE itself**.
   That app renders the **`clusters`** chart *onto the MCE*, passing
   `mce`, `mcePath`, `env: prod` and `site: site1` — read straight off the
   path (`path[1]` = site, `path[2]` = env) — plus a `$day1` value file
   holding the MCE's own `mastertag`.
3. **The MCE discovers its hosted clusters.** `clustersAppset` (now running on
   the MCE's Argo) lists directories inside the MCE folder, excluding
   `in-cluster`. It finds `ocp4-prod-herzi-site1/` and creates
   `redbull-ocp4-prod-herzi-site1`, which renders the **`operators`** chart —
   with the `$day1` pointer re-aimed at *this cluster's* version file.
4. **The chart folder becomes an app.** The `operators` template derives
   `ocpVersion: 4.16.27` from `mastertag: 4.16.27-x86_64`, then lists the
   directories in the cluster's folder. It finds `cluster-roles/` and creates
   `redbull-ocp4-prod-herzi-site1-cluster-roles`, which renders the **`deploy`**
   chart — loading the *deploy-config* stack as its own chart values.
5. **The leaf.** `deployApp.yaml` emits
   `redbull-ocp4-prod-herzi-site1-cluster-roles-deploy`: source
   `helm-charts/cluster-roles`, destination `ocp4-prod-herzi-site1`,
   `releaseName: cluster-roles`, and a ten-entry *workload-values* stack
   pointing back into the team repo. An operator syncs it (leaf apps do not
   auto-sync) and the chart runs.

Notice what did the work: **a folder made a cluster count as a cluster, a
folder made a chart exist there, and the day1 repo said which OCP version to
build the value paths from.** No registries — a folder's existence is the
whole opt-in.

There is exactly **one** opt-*out*, and it is deliberately the only list of
names in the system: `defaults/<scope>/exclusions.yaml`, which lets a fleet
default skip named clusters (§6.7). It is a list because it has to be — the
alternative would be a per-chart file, and nothing in the chain can read one
early enough to stop an app being generated.

---

## 5. Prerequisites that make the chain work

These are not rendered by this repo, but the chain silently does nothing
without them.

1. **Clusters must be registered with the right Argo, under exactly the right
   name.** Argo destinations here are by `name`, never by `server`:
   - every **MCE** must be registered on **prod-hub's** Argo — step 2 above
     targets `destination.name: <mce-folder-basename>`;
   - every **hosted cluster** must be registered on **its MCE's** Argo — the
     leaf app targets `destination.name: <cluster-folder-basename>`;
   - every **UPI cluster** must be registered on the **UPI Argo instance**
     (`openshift-gitops-upi` on prod-hub) — its leaves live there and target
     `destination.name: <cluster-folder-basename>`. It is *not* registered on
     prod-hub's day2 Argo, which only writes the handover objects.

   **The folder basename is the join key for everything**: it is the Argo
   cluster name, it is the day1 file name minus `.yaml`, and it is the only
   part of the path that ever appears in an Application name. Cluster names
   are flat and global; the tree nesting is for humans and for globs.

   A missing registration shows up as Argo's *"there are no clusters with this
   name"* on the generated app — the same symptom a phantom app produces
   (see §14).

   **For UPI there are three more conditions**, all on prod-hub and all
   checked in `APPLY-UPI.md` §1 before the first UPI folder lands:
   prod-hub's day2 Argo controller may create `ApplicationSet`s and
   `AppProject`s in `openshift-gitops-upi`; the `AppProject <team>` there
   (planted by §6.10) and the one on prod-hub allow the handover destination
   `in-cluster` / `openshift-gitops-upi`; and the UPI Argo instance has repo
   credentials for the platform repo and the sigs repos.

2. **Argo must reconcile objects in the per-team namespaces.** The manifests
   place `Application`s and `ApplicationSet`s in `gitops-<team>` (and the
   `groups`/app-projects appsets in `openshift-gitops`), so the
   apps-in-any-namespace / appsets-in-any-namespace configuration must permit
   those namespaces. Most platform layers set `CreateNamespace=true`
   (`mcesAppset` and `appProjectAppset` do not), but Argo's own allow-list is
   cluster configuration, not something this chart can render.

3. **The `AppProject <team>` must exist on every Argo running these apps** —
   that is what `appProjectAppset` is for (§6.3), and `upiAppProjectApp` for
   the UPI Argo instance (§6.10). Every app in the chain sets
   `project: <team>`, except the bootstrap layers that create it (§6.1).

4. **The GitLab token** referenced by `groupsAppset`
   (`secretName: gitops-day2`, key `token`) must exist in `openshift-gitops`
   on prod-hub, with read access to the group being scanned.

5. **A folder that would otherwise be empty needs a `.gitkeep`.** git tracks
   files, not directories — an MCE or cluster onboarded before it has any
   content of its own does not exist in git, so no generator sees it.

---

## 6. Template-by-template reference

Every chart directory here is a Helm chart (`Chart.yaml`, `values.yaml`,
`templates/`). The charts declare no default values of their own — everything
arrives from the caller above.

### 6.1 `groups/templates/groupsAppset.yaml` — the seed

|  |  |
|---|---|
| **Object** | `ApplicationSet groups`, namespace `openshift-gitops` |
| **Runs on** | prod-hub |
| **Generator** | `scmProvider.gitlab`, group `243709`, self-hosted API, `insecure: true`, token from secret `gitops-day2` |
| **Emits** | `Application <repository>` in namespace `gitops-<repository>` |
| **Values received** | none (this is the bootstrap; how the chart gets applied to prod-hub is outside this repo) |
| **Values passed** | `group: <repository>` — that is all |
| **Renders** | this repo, `path: mces` |
| **Destination** | `in-cluster` (prod-hub), namespace `gitops-<repository>` |
| **Sync** | `automated: {selfHeal: true, prune: false}`, `CreateNamespace=true` |

**Onboarding a whole team = creating a repo in that GitLab group.** The repo
name becomes the team name, the namespace name, the AppProject name and the
prefix of every Application in the fleet.

Note `project: default`, here and in `appProjectAppset` — a chicken-and-egg
necessity, not an oversight: the per-team `AppProject` is created *by* the
`mces` chart this app renders, so the two bootstrap layers cannot themselves
run under it. Everything below them does (`project: <team>`).

### 6.2 `mces/templates/mcesAppset.yaml` — MCE discovery

|  |  |
|---|---|
| **Object** | `ApplicationSet <team>-mces`, namespace `gitops-<team>` |
| **Runs on** | prod-hub |
| **Generator** | git `directories:` — `sites/*/*/mces/*` in `sigs/<team>` |
| **Emits** | `Application <team>-<mce-basename>` (namespace: the [frozen line](#13-the-frozen-line--do-not-fix-it)) |
| **Renders** | this repo, `path: clusters` |
| **Destination** | **`name: <mce-basename>`** — this is the hop that moves execution onto the MCE |
| **Sync** | `automated: {selfHeal: true, prune: false}` |

**Values received:** `group`.

**Values passed down** (inline `values:`, plus one `$day1` value file):

```yaml
valueFiles:
  - '$day1/sites/{{path[1]}}/mces/{{path.basename}}/version.yaml'   # -> mastertag
values: |
  group:    <team>
  mce:      {{path.basename}}
  mcePath:  {{path}}          # e.g. sites/site1/prod/mces/ocp4-prod-mce-site1-a
  env:      {{path[2]}}       # prod | prep | test
  site:     {{path[1]}}
```

**Labels:** `team`, `env`, `site`, `mce`, `role: mce`. Deliberately **no**
`ocp-version` — this is a discovery layer, it never learns the version, it
only points the next chart at the day1 file that holds it.

Three things to know about this template:

- **It and `upiAppset` (§6.9) are the only templates that know the tree
  layout.** Everything below them receives `{{path}}` as
  `mcePath`/`clusterPath` and builds file paths from that. A future layout
  change touches these two files.
- **Depth is enforced by the engine.** `directories:` globs are matched with
  Go `path.Match`, where `*` never crosses `/`. That is why `path[1]` and
  `path[2]` are trustworthy as site and env — see §12.
- **The MCE hub's version lives in `version.yaml`, not the MCE's
  `values.yaml`.** In the day1 tree, `values.yaml`'s `mastertag` means
  *day1's default version for the hosted clusters under this MCE* — the same
  key, a different fact. `version.yaml` is day2-owned (day1's own charts never
  read it), must carry `mastertag` **and nothing else** (any other key lands
  as a chart value here), and is hand-maintained — nothing provisions or
  verifies an MCE hub's version. Also note the **day1 tree has no `<env>`
  level**: `sites/<site>/mces/<mce>/`, not `sites/<site>/<env>/mces/<mce>/`.

### 6.3 `mces/templates/appProjectAppset.yaml` — the AppProject planter

|  |  |
|---|---|
| **Object** | `ApplicationSet <team>-app-projects`, namespace **`openshift-gitops`** (unlike its two siblings), annotation `argocd.argoproj.io/sync-wave: "-1"` |
| **Runs on** | prod-hub |
| **Generator** | `clusters: {}` — every cluster registered with **prod-hub's** Argo, i.e. prod-hub itself plus the MCEs |
| **Emits** | `Application <team>-app-projects-<cluster>` |
| **Renders** | the external chart `helm-charts/argo-appproject`, `path: .`, `targetRevision: main` |
| **Values passed** | `group: <team>` |
| **Destination** | `name: <cluster>`, namespace `openshift-gitops` |
| **Sync** | `automated: {selfHeal: true, prune: false}` |

This plants the `AppProject <team>` into each Argo's `openshift-gitops`
namespace, which every app further down the chain references as
`project: <team>`. Sync-wave −1 makes it land before the apps that need it.

**Hosted clusters get none** — they run no Argo, so there is no AppProject to
create there; the apps that *target* them live on the MCE and use the MCE's
copy. **UPI clusters get none either**, and are never generated here: they are
registered on the UPI Argo instance, not on prod-hub's day2 Argo, so
`clusters: {}` never sees them. The UPI Argo's own copy of `AppProject <team>`
comes from `upiAppProjectApp` (§6.10).

⚠️ Before the first chart lands in `defaults/hub/`, check that the
`AppProject <team>` on prod-hub actually permits destination `in-cluster` plus
the chart's namespace — deploy-type apps under that project never existed on
prod-hub before that folder.

### 6.4 `mces/templates/inClusterAppset.yaml` — the hub flow

|  |  |
|---|---|
| **Object** | `ApplicationSet <team>-in-cluster`, namespace `gitops-<team>` |
| **Runs on** | prod-hub |
| **Generator** | git `directories:` — `defaults/hub/*` in `sigs/<team>` |
| **Emits** | `Application <team>-in-cluster-<chart>` |
| **Renders** | this repo, `path: deploy` — **skipping the `operators` chart entirely** |
| **Destination** | `in-cluster` (prod-hub), namespace `gitops-<team>` |
| **Sync** | `automated: {selfHeal: true, prune: false}`, `CreateNamespace=true` |

**Values passed:**

```yaml
valueFiles:                                              # deploy-config stack (hub)
  - '$values/operators/{{path.basename}}/{{path.basename}}.yaml'
  - '$values/defaults/hub/{{path.basename}}/{{path.basename}}.yaml'
values: |
  group:    <team>
  cluster:  in-cluster
  hub:      true
  operator: {{path.basename}}
```

`hub: true` is the switch that makes `deployApp.yaml` take its hub branch: no
`env`/`site`/`mce`/`ocpVersion` are passed, and none are needed.

**Labels:** `team`, `chart`, `role: hub`. Nothing else — prod-hub is
version-less and outside the `sites/` tree.

> **Naming gotcha.** This appset is called `<team>-in-cluster`, and so is the
> static `Application` the `clusters` chart renders on each MCE (§6.6).
> Different kinds, different clusters, no collision — but if someone says
> "look at `redbull-in-cluster`", ask *which Argo*.

### 6.5 `clusters/templates/clustersAppset.yaml` — hosted-cluster discovery

|  |  |
|---|---|
| **Object** | `ApplicationSet <team>-<mce>-clusters`, namespace `gitops-<team>` |
| **Runs on** | the MCE |
| **Generator** | git `directories:` — `<mcePath>/*`, with `<mcePath>/in-cluster` explicitly `exclude: true` |
| **Emits** | `Application <team>-<cluster-basename>` |
| **Renders** | this repo, `path: operators` |
| **Destination** | `in-cluster` — i.e. the app object stays on the MCE |
| **Sync** | `automated: {selfHeal: true, prune: false}`, `CreateNamespace=true` |

**Values received:** `group`, `mce`, `mcePath`, `env`, `site`, `mastertag`
(the MCE's — unused by this template, see §6.6).

**Values passed down:**

```yaml
valueFiles:
  - '$values/defaults/hosted-clusters/exclusions.yaml'                     # -> exclusions
  - '$day1/sites/<site>/mces/<mce>/hostedClusters/{{path.basename}}.yaml'  # -> mastertag
values: |
  group:       <team>
  mce:         <mce>
  mcePath:     <mcePath>
  cluster:     {{path.basename}}
  clusterPath: {{path}}
  env:         <env>
  site:        <site>
```

**Labels:** `team`, `env`, `site`, `mce`, `cluster`, `role: hosted-cluster` —
again **no** `ocp-version` on this discovery layer.

A hosted cluster's day1 file is day1's own provisioning input, so the tag day2
reads is the tag day1 actually installed — it cannot drift from reality. The
file's other keys (`dhcp_values`, …) are inert: nothing downstream reads them,
and the inline `values:` block outranks them anyway, because **Argo applies
`helm.values` after `helm.valueFiles`**.

### 6.6 `clusters/templates/inClusterApp.yaml` — the MCE hub itself

|  |  |
|---|---|
| **Object** | `Application <team>-in-cluster`, namespace `gitops-<team>` — a plain Application, **no generator** |
| **Runs on** | the MCE |
| **Renders** | this repo, `path: operators` |
| **Destination** | `in-cluster` (the MCE) |
| **Sync** | `automated: {selfHeal: true, prune: false}`, `CreateNamespace=true` |

It is **statically rendered for every MCE** rather than folder-discovered.
That is deliberate: fleet defaults from `defaults/mces/` must reach every MCE
hub *even when that MCE has no `in-cluster/` folder of its own*.

It also carries the only `valueFiles` entry on this app —
`'$values/defaults/mces/exclusions.yaml'`, above the inline `values:` block —
and a second source `ref: values` to resolve it. That is this app's **first
and only** `$values` reference; the inline block is applied after `valueFiles`,
so `mastertag` cannot be shadowed from there. See §6.7.

This is one of only two places a version is derived:

```gotemplate
{{- $mastertag := required "mastertag missing: ..." .Values.mastertag | toString -}}
{{- $ocpVersion := $mastertag | splitList "-" | first -}}     # 4.16.27-x86_64 -> 4.16.27
```

`required` makes a missing day1 entry a **loud render failure**, never a
silently version-less deploy.

**Values passed down:**

```yaml
values: |
  group:       <team>
  mce:         <mce>
  mcePath:     <mcePath>
  cluster:     in-cluster
  clusterPath: <mcePath>/in-cluster
  env:         <env>
  site:        <site>
  mastertag:   <raw tag, e.g. 4.16.27-x86_64>
```

Note it passes the **raw `mastertag`**, not the derived `$ocpVersion` — so the
`operators` chart applies the same one derivation rule for MCE hubs and hosted
clusters alike. `$ocpVersion` is used here only for this app's own
`day2.gitops/ocp-version` label.

**Labels:** `team`, `env`, `site`, `mce`, `cluster: in-cluster`, `role: mce`,
**and** `ocp-version` — unlike the two discovery layers, this app does know
the version.

### 6.7 `operators/templates/operators.yaml` — chart discovery + version derivation

|  |  |
|---|---|
| **Object** | `ApplicationSet <team>-<cluster>-operators`, namespace `gitops-<team>` — for UPI, `openshift-gitops-upi` (`argoNamespace`) |
| **Runs on** | the MCE — for UPI, the UPI Argo instance on prod-hub |
| **Emits** | `Application <team>-<cluster>-<chart>`, in the ApplicationSet's own namespace |
| **Renders** | this repo, `path: deploy` |
| **Destination** | `in-cluster`, namespace = the same `argoNamespace` (so the leaf lands on the same Argo) |
| **Sync** | `automated: {selfHeal: true, prune: false}`, `CreateNamespace=true` |

**Generators (two, feeding one template):**

| When | Glob (in `sigs/<team>`) | What it fans out |
|---|---|---|
| always | `<clusterPath>/*` | the destination's own chart folders |
| `cluster == in-cluster` | `defaults/mces/*` | the fleet layer for every MCE hub |
| `upi: true` | `defaults/upi/*` | the fleet layer for every UPI cluster |
| otherwise | `defaults/hosted-clusters/*` | the fleet layer for every hosted cluster |

**The structural opt-out.** Each defaults generator also emits, from
`.Values.exclusions` (resolved by the parent app from
`defaults/<scope>/exclusions.yaml`), one `- path: "defaults/<scope>/<chart>"` /
`exclude: true` per chart that names this destination. Three constraints,
which are why the template looks the way it does:

1. the entries sit in the **same `git:` block** as the include glob — Argo
   computes `include && !exclude` per generator, so an exclude in the sibling
   `<clusterPath>/*` generator is a silent no-op;
2. they match the include glob's output **byte-for-byte** — a deeper path
   removes nothing, silently;
3. the three defaults generators are one `if` / `else if` / `else if` chain,
   so scopes cannot leak into each other. The UPI branch comes **before** the
   hosted-cluster branch, which would otherwise catch every non-MCE
   destination.

The data cannot live per chart: chart folder names are discovered from git at
**generator** time, while this template is Helm rendered before any chart name
exists — it sees only values at statically known paths. Malformed input
`fail`s the render on purpose; a well-formed file naming something that does
not exist is inert and silent, which is what `render_chain.py`'s four
exclusion rules catch in CI. Full rationale: `ARCHITECTURE.md` §2.2; procedure:
runbook R10.

Because both generators feed **the same ApplicationSet and the same
template**, and the template only ever uses `path.basename`, a chart renders a
**byte-identical Application** whether it sits in a defaults folder or in a
specific cluster folder. Moving a chart between the two is an in-place update,
never a delete/recreate. It is also why the **XOR rule** exists: in both
places at once means two generator entries producing the same app name, and
controller behaviour for duplicates is undefined.

(The hosted-cluster branch is guarded `else if not .Values.hub` — belt and
braces: the hub flow never renders this chart at all.)

**Values received:** `group`, `mce`, `mcePath`, `cluster`, `clusterPath`,
`env`, `site`, `mastertag`. From `upiAppset` instead: no `mce`/`mcePath`, plus
`upi: true`, `upiPath` and `argoNamespace`, and `mastertag` only if the UPI
folder has a `version.yaml`.

**Version derivation.** `mastertag` is `required` for every destination except
a UPI cluster. A UPI cluster without one is version-less like prod-hub:
`ocpVersion` is empty and the `ocp-versions/<v>/` slot, the `ocpVersion` value
and the `ocp-version` label are all left out. The role is computed with
`if`/`else`, never `ternary`: `.Values.upi` is nil on every other render, and
`ternary` needs a real bool.

**Values passed down:**

```yaml
values: |
  group:       <team>
  mce:         <mce>                       # only when set (not for UPI)
  mcePath:     <mcePath>                   # only when set (not for UPI)
  cluster:     <cluster>
  clusterPath: <clusterPath>
  env:         <env>
  site:        <site>
  ocpVersion:  <derived, e.g. 4.16.27>     # <-- the derivation ends here; absent when version-less
  operator:    {{path.basename}}           # the chart name
  upi:           true                      # ┐
  upiPath:       sites/<site>/<env>/upi    # │ UPI only
  argoNamespace: openshift-gitops-upi      # ┘
```

plus the **deploy-config stack** as value files (§8.1).

**Labels:** everything — `team`, `env`, `site`, `mce` (when set), `cluster`,
`chart`, `ocp-version` (when known), `role` (`mce` when
`cluster == in-cluster`, `upi` for UPI, else `hosted-cluster`).

### 6.8 `deploy/templates/deployApp.yaml` — the leaf

|  |  |
|---|---|
| **Object** | `Application <team>-<cluster>-<chart>-deploy` (overridable by `appname`), namespace `gitops-<team>` — for UPI, `argoNamespace` (`openshift-gitops-upi`) |
| **Runs on** | the MCE — or prod-hub, in hub mode — or the UPI Argo instance, for UPI |
| **Renders** | `{{ .Values.repourl }}` at `{{ .Values.targetRevision \| default "HEAD" }}`, `path: {{ .Values.path \| default "." }}` — **the real workload chart** |
| **Destination** | `name: {{ .Values.cluster }}`; namespace only if `projectNamespace` is set |
| **Sync** | **only if the deploy config defines `syncPolicy`** — leaf apps are manual-sync by default |

`releaseName` is the chart name, or `<cluster>-<team>-<chart>` when
`oldConvention: true`.

The big fork is on `hub`. Within the fleet branch, `cluster == in-cluster`,
then `upi`, select the defaults layer (§8.2, layers 5–7), the layer-8 slot and
the `role` label; the remaining forks are the optional deploy-config keys
`appname`, `oldConvention`, `projectNamespace`, `syncPolicy` and
`ignoreDifferences` (§9).

| | hub (`hub: true`) | fleet (MCE hub / hosted cluster) | fleet (UPI cluster) |
|---|---|---|---|
| labels | `team`, `chart`, `role: hub` | `team`, `chart`, `env`, `site`, `mce`, `cluster`, `ocp-version`, `role` | the same without `mce`; `ocp-version` only if the cluster has a version |
| value stack | 3 layers | 10 layers (§8.2) | 10 layers, 9 when version-less (§8.2) |
| namespace | `gitops-<team>` | `gitops-<team>` | `openshift-gitops-upi` |

The `hub: true` flag is also the guard that keeps hub values out of fleet apps
and fleet values out of hub apps — they share only the team-wide
`operators/<chart>/` layer.

### 6.9 `mces/templates/upiAppset.yaml` — UPI cluster discovery and handover

|  |  |
|---|---|
| **Object** | `ApplicationSet <team>-upi`, namespace `gitops-<team>` |
| **Runs on** | prod-hub's day2 Argo |
| **Generator** | git `directories: sites/*/*/upi/*` |
| **Emits** | `Application <team>-<cluster>` (the wrapper), labels `team`, `env`, `site`, `cluster`, `role: upi` — no `mce`, no `ocp-version` |
| **Renders** | this repo, `path: operators` |
| **Value files** | `$values/defaults/upi/exclusions.yaml`, then `$values/<clusterPath>/version.yaml` (optional) |
| **Destination** | `in-cluster`, namespace **`openshift-gitops-upi`** |
| **Sync** | `automated: {selfHeal: true, prune: false}` |

**The handover.** For an MCE, `mcesAppset` hops to another *cluster*
(`destination.name: <mce>`), whose Argo runs the rest. A UPI cluster has no
MCE, but prod-hub runs a second Argo instance, `openshift-gitops-upi`, that
already holds every UPI cluster secret. So this wrapper hops by *namespace*: it
writes the `operators` ApplicationSet into `openshift-gitops-upi`, and that
instance generates the chart apps and leaves and syncs them. prod-hub's day2
Argo never needs a UPI cluster secret.

**Values passed:** `group`, `cluster: {{path.basename}}`,
`clusterPath: {{path}}`, `upiPath: sites/{{path[1]}}/{{path[2]}}/upi`,
`env: {{path[2]}}`, `site: {{path[1]}}`, `upi: true`,
`argoNamespace: openshift-gitops-upi`. Sources: the platform chart and
`ref: values`; **no `ref: day1`** — day1 does not know UPI clusters.

Notes:

- `upi/` is a **sibling of `mces/`** at the same depth, so `path[1]`/`path[2]`
  mean site and env exactly as in `mcesAppset`. The literal `upi` and `mces`
  segments keep the two globs from ever matching the same folder.
- There is **no day1 parity check** for UPI folders: a stray folder under
  `upi/` becomes a phantom wrapper, visible offline only as an unexpected
  `apps added` line in `render_chain.py compare`.
- The string `openshift-gitops-upi` lives in this file and in §6.10, nowhere
  else. If the UPI Argo reconciles another namespace, change both.
- Deleting a UPI folder deletes the wrapper, but the `operators`
  ApplicationSet it wrote into `openshift-gitops-upi` stays and keeps
  deploying `defaults/upi/` charts. Cleanup: `APPLY-UPI.md` §8.

### 6.10 `mces/templates/upiAppProjectApp.yaml` — the AppProject for the UPI Argo

|  |  |
|---|---|
| **Object** | `Application <team>-upi-app-project`, namespace `gitops-<team>`, sync-wave −1, `project: default` |
| **Runs on** | prod-hub's day2 Argo — **always rendered**, no generator |
| **Renders** | the external chart `helm-charts/argo-appproject`, values `group: <team>` |
| **Destination** | `in-cluster`, namespace `openshift-gitops-upi` |
| **Sync** | `automated: {selfHeal: true, prune: false}` |

Every app handed to the UPI Argo uses `project: <team>`, so the AppProject has
to exist in `openshift-gitops-upi`. `appProjectAppset` (§6.3) cannot plant it:
the UPI Argo is another Argo on the same cluster, not a cluster secret on
prod-hub's day2 Argo. Helm cannot see whether a team has UPI folders, so every
team gets this app and one inert AppProject in `openshift-gitops-upi`. The
chart must create only namespaced objects there (`APPLY-UPI.md` check 7).

---

## 7. Every value in the chain

`{{...}}` = a generator parameter substituted by the appset controller.

| Value | Set by | Meaning | Consumed by |
|---|---|---|---|
| `group` | `groupsAppset` (`{{repository}}`) | team / repo / namespace suffix / AppProject name | every template |
| `repository` | **never set** | see [the frozen line](#13-the-frozen-line--do-not-fix-it) | `mcesAppset`, `appProjectAppset` |
| `mce` | `mcesAppset` (`{{path.basename}}`) | MCE cluster name | `clusters`, `operators`, `deploy` (label + `$day1` path) |
| `mcePath` | `mcesAppset` (`{{path}}`) | MCE folder, repo-relative | `clustersAppset` glob, MCE-wide value slot |
| `site` | `mcesAppset` / `upiAppset` (`{{path[1]}}`) | site | labels, `$day1` path, site value slots |
| `env` | `mcesAppset` / `upiAppset` (`{{path[2]}}`) | `prod` \| `prep` \| `test` | labels, env value slots |
| `mastertag` | a `$day1` value file (twice), then re-passed inline by `inClusterApp`; for UPI, the optional `$values/<clusterPath>/version.yaml` | `4.16.27-x86_64` | `inClusterApp`, `operators` — the only two that derive from it |
| `cluster` | `clustersAppset` / `upiAppset` (`{{path.basename}}`) / literal `in-cluster` | destination cluster name | `operators`, `deploy` destination |
| `clusterPath` | `clustersAppset` / `upiAppset` (`{{path}}`) / `<mcePath>/in-cluster` | the folder scanned for chart dirs | `operators` glob, cluster value slots |
| `ocpVersion` | derived in `operators` | `4.16.27`; absent for a version-less UPI cluster | version-layer paths, `ocp-version` label |
| `upi` | `upiAppset` (`true`) | UPI-mode switch | `operators`, `deploy` |
| `upiPath` | `upiAppset` (`sites/{{path[1]}}/{{path[2]}}/upi`) | the UPI folder at this site+env | `deploy` — the UPI-wide value slot (layer 8) |
| `argoNamespace` | `upiAppset` (`openshift-gitops-upi`); default `gitops-<team>` | the namespace, and so the Argo instance, that holds the operators appset and everything below it | `operators`, `deploy` |
| `operator` | `operators` / `inClusterAppset` (`{{path.basename}}`) | the chart name | app name, `releaseName`, every value path |
| `hub` | `inClusterAppset` (`true`) | hub-mode switch | `deployApp` |
| `repourl`, `targetRevision`, `path`, `projectNamespace`, `syncPolicy`, `ignoreDifferences`, `appname`, `oldConvention` | the team repo's `<chart>.yaml` files | the deploy config (§9) | `deployApp` |

---

## 8. Where you can define values — the two stacks

**The single most useful thing to internalise about this platform.** There are
two independent stacks, they are resolved by two different mechanisms, and
both are ordered lowest → highest with **later winning per key**.

Every layer is declared under `ignoreMissingValueFiles: true`, so think of
each one as a **slot, not a file**: a missing file quietly contributes
nothing, and creating it later is a deliberate, scoped opt-in. Most slots are
empty today. That is the intended state.

### 8.0 The two mechanisms (the "aha")

- **Deploy config (`<chart>.yaml` files)** is listed as `valueFiles` on the
  *`operators`/`inClusterAppset` source that renders the `deploy` chart*. So
  those files are **Helm values of the `deploy` chart itself** — the platform
  reads them, and their keys become `.Values.repourl`, `.Values.syncPolicy`
  and friends inside `deployApp.yaml`.
- **Workload values (`values.yaml` files)** are listed as `valueFiles` on the
  *leaf Application's own source*. The platform **never reads them** — it just
  writes the path strings into the leaf app, and Argo resolves them later
  against the real workload chart, against the `$values` ref the leaf app
  declares for itself.

That is why a typo in a deploy config breaks the render, while a typo in a
workload `values.yaml` only breaks the workload's own sync.

### 8.1 Stack 1 — deploy config (which repo, branch, namespace, sync policy)

| # | hosted cluster | MCE in-cluster | UPI cluster | prod-hub |
|---|---|---|---|---|
| 1 | `operators/<c>/<c>.yaml` | same | same | same |
| 2 | `operators/<c>/ocp-versions/<v>/<c>.yaml` | same (`<v>` = the MCE's) | same, only with a `version.yaml` | — (version-less) |
| 3 | `defaults/hosted-clusters/<c>/<c>.yaml` | `defaults/mces/<c>/<c>.yaml` | `defaults/upi/<c>/<c>.yaml` | `defaults/hub/<c>/<c>.yaml` |
| 4 | `<clusterPath>/<c>/<c>.yaml` | `<mcePath>/in-cluster/<c>/<c>.yaml` | `<clusterPath>/<c>/<c>.yaml` | — |

### 8.2 Stack 2 — workload values (what the chart itself sees)

Hosted-cluster column in full; the MCE in-cluster and UPI columns differ only
where shown:

| # | Layer (hosted cluster) | MCE in-cluster equivalent | UPI cluster equivalent | Scope |
|---|---|---|---|---|
| 1 | `operators/<c>/values.yaml` | same | same | chart, team-wide |
| 2 | `operators/<c>/ocp-versions/<v>/values.yaml` | same | same, only with a `version.yaml` | chart, per exact OCP version |
| 3 | `sites/<site>/values.yaml` | same | same | site-wide, chart-agnostic (use sparingly) |
| 4 | `sites/<site>/<env>/values.yaml` | same | same | site + env |
| 5 | `defaults/hosted-clusters/<c>/values.yaml` | `defaults/mces/<c>/values.yaml` | `defaults/upi/<c>/values.yaml` | chart, whole fleet |
| 6 | `defaults/hosted-clusters/<c>/values-<env>.yaml` | `defaults/mces/<c>/values-<env>.yaml` | `defaults/upi/<c>/values-<env>.yaml` | chart + env |
| 7 | `defaults/hosted-clusters/<c>/values-<cluster>.yaml` | `defaults/mces/<c>/values-<mce>.yaml` | `defaults/upi/<c>/values-<cluster>.yaml` | chart + one destination |
| 8 | `<mcePath>/values.yaml` | same | `sites/<site>/<env>/upi/values.yaml` | MCE-wide (UPI: every UPI cluster at this site+env) |
| 9 | `<clusterPath>/values.yaml` | `<mcePath>/in-cluster/values.yaml` | `<clusterPath>/values.yaml` | cluster-wide |
| 10 | `<clusterPath>/<c>/values.yaml` | `<mcePath>/in-cluster/<c>/values.yaml` | `<clusterPath>/<c>/values.yaml` | chart @ cluster — always wins |

Layers 3 and 4 are shared by every kind of cluster at the site, on purpose:
they hold site facts. A value only UPI clusters should see goes in layers 5–8
of the UPI column.

**prod-hub** keeps three: `defaults/hub/values.yaml` (hub-wide,
chart-agnostic) → `operators/<c>/values.yaml` →
`defaults/hub/<c>/values.yaml`.

Mnemonic: **generic → versioned → geographic → fleet-default → specific.**
The most context-specific file always wins.

Layers 6 and 7 are how you vary a fleet-default chart per env or per cluster
**without** creating a folder under that cluster — doing the latter would
violate the XOR rule and produce a duplicate app name.

### 8.3 ⚠️ Two precedence footguns

1. **A defaults config overrides every version pin.**
   `defaults/*/<c>/<c>.yaml` is layer 3; `ocp-versions/<v>/` is layer 2. A
   `targetRevision` written in a defaults config silently wins over every
   version pin, on every destination. Rule: defaults configs carry
   `repourl` / `projectNamespace` / `syncPolicy`; pins live in `operators/`.
   (`dhcp-api-token` pins `main` in `defaults/mces/` today — intentional, but
   it means version pins for it are inert until that line moves.)
2. **Create `ocp-versions/<new>/` BEFORE day1 flips the tag — every upgrade,
   z-streams included.** Layers are keyed by the **full patch version**, so
   `4.16.27 → 4.16.29` moves a destination off its layer exactly as surely as
   `4.16 → 4.20`. If the new folder does not exist for a *pinned* chart, the
   slot resolves to nothing and the cluster silently falls back to the team
   default — `ignoreMissingValueFiles` cannot tell "no layer needed" from
   "layer forgotten". And the flip is **not your merge request**: it lands in
   the day1 repo, possibly merged by someone who has never opened your sig.

---

## 9. Deploy-config keys the platform reads

Everything `deployApp.yaml` reads out of the `<chart>.yaml` stack:

| Key | Default | Effect |
|---|---|---|
| `repourl` | *(none)* | the workload chart's repo. **All lowercase** — `repoUrl` reaches the template as nil and renders an empty `repoURL`. Several older configs in the sigs repo have this bug; do not copy them |
| `targetRevision` | `HEAD` | branch/tag of the workload chart — this is the **pin** |
| `path` | `.` | subchart path inside the chart repo (e.g. `charts/dhcp-api-token`) |
| `projectNamespace` | *(unset)* | the leaf app's `destination.namespace`; omitted entirely when unset |
| `syncPolicy` | *(unset)* | passed through verbatim. **Unset ⇒ manual sync**, which is the default posture for workloads |
| `ignoreDifferences` | *(unset)* | passed through verbatim |
| `appname` | `<team>-<cluster>-<chart>-deploy` | overrides the leaf app name — an identity field, so changing it recreates the app |
| `oldConvention` | `false` | `releaseName` becomes `<cluster>-<team>-<chart>` instead of `<chart>` — for charts migrated from the previous layout, where changing the release name would orphan resources |

Version pinning has three levels, each one line in one file:

```yaml
# operators/ako/ako.yaml                                  — team default
targetRevision: "2.1.2"
# operators/ako/ocp-versions/4.20.9/ako.yaml              — the per-version matrix (the fleet op)
targetRevision: "2.1.4"
# sites/<site>/<env>/mces/<mce>/<cluster>/ako/ako.yaml    — per-cluster emergency pin
targetRevision: "2.1.5-hotfix"
```

Pin values are **branch names in the chart's own repo**, and a version branch
is **frozen at creation** — a fix is a new branch, never a push to an existing
one, because a moved branch changes what every pinned cluster deploys with no
merge request anywhere in day2.

Charts that track `main` (most of them) simply have no `ocp-versions/` folder.
The `ocp-versions/<v>` slots are emitted on every render regardless; an absent folder
resolves to nothing, so a cluster OCP upgrade produces **zero diff** for them.

---

## 10. Versions — day1 owns them

No sig repo declares the OCP version of an MCE or hosted cluster. It is
resolved at render time from `gitops-day1/platform-config`:

| the day2 folder | the file that owns its version |
|---|---|
| `sites/<site>/<env>/mces/<mce>` | day1 `sites/<site>/mces/<mce>/version.yaml` |
| `sites/<site>/<env>/mces/<mce>/<cluster>` | day1 `sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml` |
| `sites/<site>/<env>/upi/<cluster>` | **the sigs repo**, `<that folder>/version.yaml` — optional |

Translating a day2 path to a day1 path means **dropping the `<env>` segment** —
env lives only inside the cluster name. Site and MCE names match exactly, and
a hosted cluster's folder name equals its day1 file name minus `.yaml`.

```yaml
mastertag: 4.16.27-x86_64      # -> ocpVersion: 4.16.27
```

The rule is: **strip the architecture at the first `-`, use the rest
verbatim.** Nothing is truncated to a minor line. It is applied in exactly two
templates — `clusters/templates/inClusterApp.yaml` and
`operators/templates/operators.yaml` — and both open with the same derivation
(§6.6). Both use `required`, so an MCE or hosted cluster with no day1 entry
fails the render loudly.

**UPI clusters are the one exception.** day1 provisions MCEs and hosted
clusters only, so it has no entry for a UPI cluster. Its folder may carry
`version.yaml` with `mastertag` and nothing else, read by `upiAppset` from the
sigs repo. Without it the cluster is **version-less, like prod-hub**: the
`operators` chart skips `required` for UPI only, and leaves out the version
slot, the `ocpVersion` value and the `ocp-version` label. The file is
hand-maintained and per sigs repo, so a UPI upgrade is one edit in each team
repo that has the cluster. `render_chain.py` checks its schema but cannot
check it against reality.

Why day1 rather than here: the air-gap runs **five sig repos**, and the same
physical cluster appears in all five. Its version used to be written five
times, and drifted. Now a cluster is upgraded once, in the repo that actually
upgrades it, and every sig re-renders against the new value.

Only four templates know the day1 repo exists: `mcesAppset` and
`clustersAppset` reach into its tree; `inClusterApp` and `operators` derive a
version from what those resolve. Nothing else in the chain does — `upiAppset`
deliberately has no `$day1` source.

---

## 11. Labels and fleet operations

Every generated Application carries:

```yaml
day2.gitops/team: redbull
day2.gitops/env: prod                # ┐ read off the sites/ path
day2.gitops/site: site1              # ┘
day2.gitops/mce: ocp4-prod-mce-site1-a
day2.gitops/cluster: ocp4-prod-herzi-site1
day2.gitops/chart: cluster-roles     # chart-level apps and below
day2.gitops/ocp-version: "4.16.27"   # the DESTINATION's FULL version
day2.gitops/role: hosted-cluster     # hub | mce | hosted-cluster | upi
```

UPI apps carry no `mce` label, and carry `ocp-version` only when the cluster
has a `version.yaml`.

```bash
argocd app list -l day2.gitops/env=prod,day2.gitops/chart=ako
argocd app sync -l day2.gitops/chart=ako,day2.gitops/ocp-version=4.20.9
argocd app sync -l day2.gitops/cluster=ocp4-prod-herzi-site1
```

Three rules for using them:

- **The version is the full version.** `ocp-version=4.20` matches nothing.
- **Two layers deliberately have no `ocp-version`:** `<team>-<mce>` and
  `<team>-<cluster>` (for hosted and UPI clusters alike), the discovery
  layers, which never learn it. In practice
  that is the right split — a version selector picks out the apps that
  actually deploy something and skips the plumbing.
- **Labels are per-Argo.** MCE-scoped selectors run against that MCE's Argo,
  hub-scoped against prod-hub's day2 Argo, UPI chart and leaf selectors
  against the UPI Argo instance. A bare `ocp-version=4.20.9` sweeps MCE hubs
  *and* hosted clusters together — add `day2.gitops/role` to hit one kind.

---

## 12. Discovery mechanics — `directories:` vs `files:`

If you ever add a generator to this repo, read this first.

| Generator | Matched by | Does `*` cross `/`? | Parameters |
|---|---|---|---|
| `directories:` | Go `path.Match`, in the appset controller | **No** — exactly one path segment | `{{path}}`, `{{path.basename}}`, `{{path[n]}}` |
| `files:` | `git ls-files -- <pattern>` on the repo-server | **Yes** — matches at any depth | the same, **plus every key in the file** |

**Every discovery step in this platform is a `directories:` generator**, and
that is load-bearing, not stylistic:

```console
$ git ls-files -- 'sites/*/config.yaml'      # a files: glob is a git pathspec
sites/site1/prod/mces/ocp4-prod-mce-site1-a/config.yaml                        # meant this
sites/site1/prod/mces/ocp4-prod-mce-site1-a/ocp4-prod-herzi-site1/config.yaml  # got this too
```

> **The Phase B production incident.** Discovery used to be a `files:`
> generator anchored on a marker file, with the same filename at two depths.
> Because `*` crosses `/` in a git pathspec, `mcesAppset` matched every hosted
> cluster's file too and emitted Applications whose `destination.name` was a
> hosted cluster — Argo answered *"there are no clusters with this name"* for
> each. Full write-up in `CHANGES.md` §0; the deeper analysis in
> `ARCHITECTURE.md` §2.1.

Depth cannot be expressed in a `files:` glob at all. As a `directories:`
pattern, `sites/*/*/mces/*` is depth-exact **for free** — the property comes
from the matching engine, and an engine cannot be forgotten during a review.
That is also what makes `path[1]`/`path[2]` safe to read as site and env.

Argo *can* be told to match `files:` globs with depth-exact doublestar
(`applicationsetcontroller.enable.new.git.file.globbing: "true"`). We
deliberately never relied on it: it defaults to off, and `clustersAppset` runs
on **every** MCE's Argo — including every MCE onboarded in the future — so the
whole fleet would have had to carry the flag forever.

`render_chain.py` models both engines and fails the pre-merge check on any
`files:` glob whose two readings differ. That guard is kept even though
nothing matches it today.

---

## 13. The frozen line — do not fix it

In **`mces/templates/mcesAppset.yaml`** and
**`mces/templates/appProjectAppset.yaml`**, the generated app's template
carries:

```yaml
namespace: gitops-{{ .Values.repository }}
```

`.Values.repository` is **never set** — the `groups` layer passes `group`, not
`repository` — so this renders as the literal `gitops-`.

**It is wrong, it is known, and it is deliberately frozen.** A generated app's
namespace is part of its identity: "fixing" it would delete and recreate every
Application in the fleet. Leave both lines byte-identical, always.
`render_chain.py` lints for exactly this.

---

## 14. Safety model and invariants

1. **App names are built from folder basenames only.** No path level above the
   basename ever appears in a name. Moving a folder (in one commit) presents
   the same app name with new parameters, so the controller updates the app
   **in place** — nothing is deleted or recreated. This is what made the whole
   `sites/` migration a zero-impact change.
2. **No `resources-finalizer`.** If a generator entry does disappear, only the
   `Application` CR is deleted — the deployed workloads are **orphaned in
   place, still running**. A same-named app re-adopts them cleanly. Worst case
   is cruft, never an outage.
3. **Leaf apps are manual-sync by default; platform layers self-heal.** Spec
   changes propagate down the chain on their own, but workloads move only when
   an operator syncs — per app or in bulk by label. (A chart's own deploy
   config can opt into auto-sync; today only `dhcp-api-token` does.)
4. **THE ONE INVARIANT: at any commit, each MCE / cluster / chart is emitted by
   exactly one generator entry.** Every working rule derives from it —
   one-commit `git mv`, never copy-then-delete, the XOR rule, add-glob-before-
   remove ordering during migrations.
5. **Nothing but clusters lives under an MCE folder, nothing but MCEs under
   `mces/`, nothing but UPI clusters under `upi/`.** A stray folder at any of
   these levels becomes a **phantom Application** aimed at a cluster that does
   not exist. Under `mces/` it is caught before merge: a stray folder has no
   day1 version file, so the day1-parity lint names it. Under `upi/` there is
   no day1 file to check — the only offline signal is an unexpected
   `apps added` line in `compare`.

The full invariants checklist is in `ARCHITECTURE.md` Part IV. The ones that
bite *platform* changes specifically:

- discovery generators are `directories:`, never `files:` (§12);
- the frozen namespace line stays byte-identical (§13);
- app-name patterns are identity — changing one recreates the fleet;
- a value-only `ref:` source is *not* identity (adding one is safe), but
  losing one breaks resolution.

---

## 15. Verify before merge

**There is no "after".** Platform apps run `selfHeal: true`, so a wrong render
syncs immediately — there is no post-merge inspection window. Every structural
change goes through the offline harness, which simulates this entire chain:

```bash
python3 tools/render-verify/render_chain.py snapshot --out /tmp/before   # on main
# ...apply your change...
python3 tools/render-verify/render_chain.py snapshot --out /tmp/after
python3 tools/render-verify/render_chain.py compare /tmp/before /tmp/after
```

`snapshot` needs all three checkouts — the sigs tree, the platform charts and
the **day1** repo, which every destination's version is read from. Pass
`--group NAME`, `--sigs ROOT`, `--platform ROOT` and `--day1 ROOT` when they
are separate GitLab projects, as they are in the air-gapped env; the defaults
describe a single mock checkout. A missing one exits 2 naming the flag to
pass, rather than guessing.

**`snapshot` exits 1 on any check failure**, so a CI lint job is `snapshot`
with the output discarded — reference GitLab CI fragments for both repo roles
ship at `tools/ci/`.

`compare` splits every app's resolved value files by repo, because the two
have opposite expectations:

- the **sigs** sequence is **HARD** — a change there changes what a workload
  renders;
- the **day1** sequence is **INFO** — that is precisely where versions are
  supposed to change;
- a UPI cluster's own **version** file is **INFO**, for the same reason as
  day1;
- the **control** sequence is **INFO** — the `exclusions.yaml` matrices (§6.7),
  which decide whether an app *exists* rather than what it renders. Their real
  effect lands as `APPS DISAPPEARED` on the few apps actually excluded;
  hashing them into the sigs sequence would raise a HARD diff on every app in
  the team for that same two-line change.

Identity (name, destination, `releaseName`, `syncPolicy`, repo/branch) stays
HARD, as do disappearing apps.

It also lints: `env ∈ {prod,prep,test}`, duplicate app names, leftover
`{{...}}` placeholders, the frozen namespace line, depth-ambiguous `files:`
globs, the four **exclusion rules** (§6.7 — schema, chart names, cluster
names, no hub file), and **day1 parity** — every MCE and hosted-cluster folder
must have a day1 file carrying a `mastertag` matching
`<major>.<minor>.<patch>[-<arch>]`. UPI folders get their own checks instead:
env allow-list, no `in-cluster` name, no reuse of an MCE or hosted-cluster
name, and — only if present — a `version.yaml` carrying a valid `mastertag`
and nothing else. Apps handed to the UPI Argo instance are reported as
`prod-hub-upi:<app>`.

Structural changes must end **`IDENTITY OK`**; deliberate changes (pins,
values) must show **only** the diffs you intended, on the apps you intended.

It is a pre-merge gate, not a substitute for live Argo verification.

---

## 16. Glossary

| Term | Meaning |
|---|---|
| prod-hub | the top management cluster; runs the `groups` appset |
| MCE | a hub cluster managing hosted clusters; runs its own Argo |
| hosted cluster / spoke | a leaf cluster where workloads run; runs no Argo |
| UPI cluster | a standalone cluster, not under any MCE, no Argo of its own; a folder under `sites/<site>/<env>/upi/`, deployed by the UPI Argo instance |
| UPI Argo instance | the second OpenShift GitOps instance on prod-hub, namespace `openshift-gitops-upi`; holds the UPI cluster secrets and runs everything below the UPI wrappers |
| `in-cluster` | every Argo's name for the cluster it runs on — the MCE hub in the fleet flow, prod-hub in the hub flow |
| Application | Argo's "deploy this chart there" object |
| ApplicationSet / appset | template + generator that stamps out Applications from git content |
| multi-source app | an Application with several `sources:`; extra `ref:` ones supply value files only — that is how `$values` and `$day1` reach the chain |
| day1 / `platform-config` | the repo that provisions clusters and owns their OCP versions. Day2 reads it, never writes it |
| `mastertag` | day1's version key: `<major>.<minor>.<patch>[-<arch>]` |
| `ocpVersion` | the derived value: `mastertag` with the architecture stripped at the first `-`. Never declared in a sig repo, except a UPI cluster's optional `version.yaml` |
| version layer | `operators/<chart>/ocp-versions/<v>/` — the slot keyed by a destination's **exact** OCP version |
| slot | a value-file path that is always listed but may not exist (`ignoreMissingValueFiles`) |
| pin | a `targetRevision` line selecting a frozen chart branch |
| leaf app | `<team>-<cluster>-<chart>-deploy` — the app that deploys the actual workload |
| deploy config | `<chart>.yaml` — repo/branch/namespace/sync settings, read by the platform |
| XOR rule | a chart lives in a defaults folder OR a specific cluster folder — never both |
| phantom app | an Application generated for a folder that is not a real cluster |
| frozen line | `namespace: gitops-{{ .Values.repository }}` — renders as `gitops-`, never touch (§13) |
| THE ONE INVARIANT | each MCE/cluster/chart emitted by exactly one generator entry, at every commit |

---

## Where to go next

- **You maintain a team repo** → `sigs/<team>/README.md`, then
  `ARCHITECTURE.md` Part III (runbooks: upgrade a cluster, upgrade a chart,
  add a cluster, add an MCE, decommission).
- **You are changing this repo** → §6, §12, §13, §14, then run §15 before
  every merge request.
- **You are reproducing this in the air-gapped environment** → `CHANGES.md`,
  which is the phase-by-phase hand-off.
