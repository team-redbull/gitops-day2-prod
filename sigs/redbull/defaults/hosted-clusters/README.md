# defaults/hosted-clusters

Chart folders in this directory are deployed to **every hosted cluster** of
this team (redbull), on every MCE — the hosted-cluster mirror of
[`defaults/mces/`](../mces/) (every MCE hub) and
[`defaults/hub/`](../hub/) (the prod-hub mgmt cluster).

Wiring: a dedicated generator in the platform `operators` chart scans
`defaults/hosted-clusters/*` for every hosted cluster and feeds the **same
ApplicationSet and template** as the cluster's own chart folders, so a chart
renders a byte-identical Application whether it sits here or in a specific
cluster folder — moving it between the two is an in-place update, never a
delete/recreate.

## Layout

```
defaults/
  hosted-clusters/
    <chart>/
      <chart>.yaml            # deploy config (repourl, projectNamespace, syncPolicy, ...)
      values.yaml             # helm values applied on every hosted cluster
      values-<env>.yaml       # optional: overrides for one env (prod | prep | test)
      values-<cluster>.yaml   # optional: overrides for one specific cluster
```

## Rules

1. **XOR rule:** a chart lives EITHER here OR in a specific cluster's folder
   (`sites/<site>/<env>/mces/<mce>/<cluster>/<chart>/`) — never both. A
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
   every hosted cluster.** Never create non-chart directories here. Plain
   files are ignored by the directory generator and are safe — this README
   and `exclusions.yaml` are both plain files here for exactly that reason.
4. **Two different questions, two different files.** A cluster that needs the
   chart to *behave* differently gets a `values-<cluster>.yaml` here. A cluster
   that must not have the chart **at all** is named in `exclusions.yaml` — see
   [Structural opt-out](#structural-opt-out) below. Reach for the values file
   first: an exclusion is the heavier tool, and it is *prevention*, never
   teardown.
5. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads.
6. **Leave `targetRevision` out of the deploy config here if the chart should
   follow per-OCP-stream pins.** This file sits ABOVE the
   `operators/<chart>/versions/ocp-<v>/` layer in the config stack, so a
   `targetRevision` written here overrides every stream pin silently.

## Structural opt-out

`exclusions.yaml` — one file for the whole folder, keyed by chart — is how a
fleet default skips a named set of clusters. It is a plain file directly under
`defaults/hosted-clusters/`, so the directory generator never sees it.

```yaml
# defaults/hosted-clusters/exclusions.yaml
exclusions:
  <chart>:
    - <hosted-cluster-name>
    - <another-hosted-cluster-name>
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
2. **Every listed name is a real hosted cluster** (a folder under an MCE,
   other than `in-cluster`).
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
2. `operators/<chart>/versions/ocp-<v>/values.yaml` — chart, per OCP stream
3. `sites/<site>/values.yaml` — site-wide
4. `sites/<site>/<env>/values.yaml` — site + env
5. `defaults/hosted-clusters/<chart>/values.yaml` — chart, every hosted cluster
6. `defaults/hosted-clusters/<chart>/values-<env>.yaml` — chart + env
7. `defaults/hosted-clusters/<chart>/values-<cluster>.yaml` — chart + cluster
8. `sites/<site>/<env>/mces/<mce>/values.yaml` — MCE-wide
9. `sites/<site>/<env>/mces/<mce>/<cluster>/values.yaml` — cluster-wide
10. `.../<cluster>/<chart>/values.yaml` — per-cluster charts only (XOR rule)

Deploy config precedence: `operators/<chart>/<chart>.yaml` →
`operators/<chart>/versions/ocp-<v>/<chart>.yaml` →
`defaults/hosted-clusters/<chart>/<chart>.yaml` →
`.../<cluster>/<chart>/<chart>.yaml` (per-cluster charts only).
