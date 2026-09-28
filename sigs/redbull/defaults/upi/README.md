# defaults/upi

Chart folders in this directory are deployed to **every UPI cluster** of this
team (redbull), on every site and env. A UPI cluster is a standalone OpenShift
cluster: no MCE above it and no Argo of its own. This folder is the UPI mirror
of [`defaults/hosted-clusters/`](../hosted-clusters/) (every hosted cluster),
[`defaults/mces/`](../mces/) (every MCE hub) and [`defaults/hub/`](../hub/)
(the prod-hub mgmt cluster).

Wiring: the platform's `upiAppset` (on prod-hub's day2 Argo) creates one
`redbull-<cluster>` app per folder under `sites/<site>/<env>/upi/`. That app
hands the `operators` chart over to the **UPI Argo instance**
(`openshift-gitops-upi`, on the same hub cluster), whose generator scans
`defaults/upi/*` next to the cluster's own chart folders and feeds the **same
ApplicationSet and template**. A chart therefore renders a byte-identical
Application whether it sits here or in a specific cluster folder — moving it
between the two is an in-place update, never a delete/recreate.

## Layout

```
defaults/
  upi/
    <chart>/
      <chart>.yaml            # deploy config (repourl, projectNamespace, syncPolicy, ...)
      values.yaml             # helm values applied on every UPI cluster
      values-<env>.yaml       # optional: overrides for one env (prod | prep | test)
      values-<cluster>.yaml   # optional: overrides for one specific UPI cluster
```

## Registering a UPI cluster

A UPI cluster exists for day2 when its folder exists:
`sites/<site>/<env>/upi/<cluster>/`. Two things to know:

- **The folder name is the cluster's name on the UPI Argo instance**
  (`argocd cluster list` against `openshift-gitops-upi`). The leaf apps target
  `destination.name: <cluster>` there. Name the folder after the existing
  cluster secret, never the reverse.
- **`version.yaml` in that folder is optional.** It holds `mastertag:
  4.16.27-x86_64` and nothing else. With it, the cluster's charts pick up
  `operators/<chart>/ocp-versions/<v>/` pins and carry a
  `day2.gitops/ocp-version` label. Without it, the cluster is version-less
  like prod-hub: pinned charts get the team default. day1 does not know UPI
  clusters, so this is the one place a sigs repo declares a version, and a UPI
  upgrade is one edit per team repo that declares it.

There is **no day1 parity check** for UPI folders, so a stray folder under
`upi/` becomes a phantom app. The render check shows it only as an unexpected
`apps added` line, so read that line on every MR.

## Rules

1. **XOR rule:** a chart lives EITHER here OR in a specific UPI cluster's
   folder (`sites/<site>/<env>/upi/<cluster>/<chart>/`) — never both. A
   violation produces two generator entries with the same Application name;
   controller behavior for duplicates is undefined.
   **Carve-out:** the pair is legal *iff* that exact cluster is listed under
   that chart in [`exclusions.yaml`](#structural-opt-out) — the deliberate
   full-override escape hatch, for when one cluster needs a different
   `repourl` / `targetRevision` rather than different values. The exclusion
   removes the fleet entry, so only one generator emits the name. Without the
   entry it is still a duplicate-app failure, so the *accidental* case is
   unaffected.
2. **Per-scope overrides go in `values-<env>.yaml` / `values-<cluster>.yaml`
   here** — do NOT create the chart under a specific cluster just to hold an
   override file (that violates rule 1).
3. **Every directory directly under this folder becomes an Application on
   every UPI cluster.** Never create non-chart directories here. Plain files
   are ignored by the directory generator and are safe — this README and
   `exclusions.yaml` are both plain files here for exactly that reason.
4. **Two different questions, two different files.** A cluster that needs the
   chart to *behave* differently gets a `values-<cluster>.yaml` here. A cluster
   that must not have the chart **at all** is named in `exclusions.yaml` — see
   [Structural opt-out](#structural-opt-out) below. Reach for the values file
   first: an exclusion is the heavier tool, and it is *prevention*, never
   teardown.
5. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads.
6. **Leave `targetRevision` out of the deploy config here if the chart should
   follow per-OCP-version pins.** This file sits ABOVE the
   `operators/<chart>/ocp-versions/<v>/` layer in the config stack, so a
   `targetRevision` written here overrides every version pin silently.
7. **Never let gitops-upi and day2 deploy the same chart to the same cluster.**
   Both now run on the UPI Argo instance with the same `releaseName` and
   namespace, so two Applications would fight over one release. Remove the
   chart from gitops-upi first, then add it here or to the cluster folder.

## Structural opt-out

`exclusions.yaml` — one file for the whole folder, keyed by chart — is how a
fleet default skips a named set of UPI clusters. It is a plain file directly
under `defaults/upi/`, so the directory generator never sees it.

```yaml
# defaults/upi/exclusions.yaml
exclusions:
  <chart>:
    - <upi-cluster-name>
    - <another-upi-cluster-name>
```

**This file does not exist in this repo yet**, and absent is the normal state —
most teams never write one. It cannot be created here until this folder has at
least one chart folder, because every key must name one (Rule 1).

Why one central file and not `<chart>/exclusions.yaml`: the decision *"does this
chart become an Application here?"* is made by a `directories:` generator, which
discovers chart folder names from git. The template that builds that generator
is Helm, rendered before any chart name exists — it can only read Helm **values**
from statically known paths. So the data has to arrive from one fixed path per
scope. A per-chart file could only be read one layer lower, where the app has
already been generated.

The four rules, all enforced by `render_chain.py` in CI:

0. **`exclusions` is the only top-level key.** This file is merged into the
   operators chart's values, so any other key becomes a real chart value — a
   stray `mastertag` here would be an OCP version, not a comment.
1. **Every key names a chart folder in this directory.** A chart that ships
   *with* exclusions means the chart folder and its entry land in the **same
   commit**: chart-first deploys it to the excluded cluster for one sync
   interval, entry-first fails this rule.
2. **Every listed name is a real UPI cluster** (a folder under
   `sites/<site>/<env>/upi/`).
3. **No `defaults/hub/exclusions.yaml`.** The hub is one cluster and never
   flows through the operators chart; delete the chart folder instead.

Rules 1 and 2 both exist because the two typos fail differently and **both are
silent**: a wrong chart name emits an exclude that matches no folder, so the
chart still deploys; a wrong cluster name matches no destination, so no exclude
is emitted at all.

**Excluded everywhere → delete the folder instead.** An exclusions list naming
every cluster is a chart that is not a fleet default.

**An exclusion is prevention, not teardown.** Removing the entry's app does not
uninstall a running workload: platform apps are `prune: false` with no
`resources-finalizer`, so the `-deploy` child and the workload are orphaned in
place, still running. See runbook **R10** in `ARCHITECTURE.md` for the manual
teardown, and for the undo (delete the entry — the wrapper reappears and
re-adopts the orphan in place).

## Values precedence (lowest to highest)

1. `operators/<chart>/values.yaml` — chart, team-wide
2. `operators/<chart>/ocp-versions/<v>/values.yaml` — chart, per OCP version (only when the cluster has a `version.yaml`)
3. `sites/<site>/values.yaml` — site-wide (shared with every kind of cluster at the site)
4. `sites/<site>/<env>/values.yaml` — site + env (shared likewise)
5. `defaults/upi/<chart>/values.yaml` — chart, every UPI cluster
6. `defaults/upi/<chart>/values-<env>.yaml` — chart + env
7. `defaults/upi/<chart>/values-<cluster>.yaml` — chart + cluster
8. `sites/<site>/<env>/upi/values.yaml` — every UPI cluster at this site + env
9. `sites/<site>/<env>/upi/<cluster>/values.yaml` — cluster-wide
10. `.../<cluster>/<chart>/values.yaml` — per-cluster charts only (XOR rule)

Layers 3 and 4 are shared with MCE hubs and hosted clusters at the same
site/env on purpose: they hold site facts (registry, DNS, proxy) that every
cluster there needs. Anything only UPI clusters should see goes in layers 5–9.

Deploy config precedence: `operators/<chart>/<chart>.yaml` →
`operators/<chart>/ocp-versions/<v>/<chart>.yaml` (versioned clusters only) →
`defaults/upi/<chart>/<chart>.yaml` →
`.../<cluster>/<chart>/<chart>.yaml` (per-cluster charts only).
