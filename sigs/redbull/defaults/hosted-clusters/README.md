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
2. **Per-scope overrides go in `values-<env>.yaml` / `values-<cluster>.yaml`
   here** — do NOT create the chart under a specific cluster just to hold an
   override file (that violates rule 1).
3. **Every directory directly under this folder becomes an Application on
   every hosted cluster.** Never create non-chart directories here. Plain
   files (like this README) are ignored by the directory generator and are
   safe.
4. **There is no structural opt-out** for a single cluster — that is what
   makes it a default. Behavior differences belong in `values-<cluster>.yaml`.
5. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads.
6. **Leave `targetRevision` out of the deploy config here if the chart should
   follow per-OCP-stream pins.** This file sits ABOVE the
   `operators/<chart>/versions/ocp-<v>/` layer in the config stack, so a
   `targetRevision` written here overrides every stream pin silently.

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
