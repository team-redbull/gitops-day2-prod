# in-cluster

Chart folders in this directory are deployed to the **prod-hub mgmt cluster
itself** — the cluster running the `groups` ApplicationSet in
`openshift-gitops`. This is the top-level prod-hub context that the repo's
naming convention reserved: a folder's name is the destination as seen by the
Argo that consumes it, the repo top level is consumed by **prod-hub's Argo**,
and `in-cluster` is prod-hub's name for itself. (`mces/<mce>/in-cluster/` is
the same word from a different Argo — the MCE hub, as seen by the MCE's Argo.)

Wiring: the `<group>-in-cluster` ApplicationSet (rendered by the platform
`mces` chart, which already runs on prod-hub per team) scans `in-cluster/*`
and creates, per chart folder, `<group>-in-cluster-<chart>` → the platform
`deploy` chart in hub mode (`hub: true`) → `<group>-in-cluster-<chart>-deploy`
with destination `in-cluster` (prod-hub), namespace = `projectNamespace`,
releaseName `<chart>`.

## Layout

```
in-cluster/
  <chart>/
    <chart>.yaml         # deploy config (repourl, projectNamespace, syncPolicy, ...)
    values.yaml          # helm values for this chart on prod-hub
```

## Rules

1. **Every directory directly under this folder becomes an Application on
   prod-hub.** Never create non-chart directories here (docs, scripts, ...).
   Plain files (like this README) are ignored by the directory generator and
   are safe.
2. **Only chart folders live here** — there is deliberately no hub-wide
   `in-cluster/values.yaml` layer. Hub-wide concerns belong in each chart's
   own values.
3. **A chart may exist both here and in the `mces/` flows** (hub and fleet are
   different destinations — no XOR rule against `mces/`). The two deployments
   share only the team-wide `operators/<chart>/` layer; the hub values file
   never leaks into fleet apps (it is guarded by `hub: true` in the deploy
   template) and fleet/defaults values never leak into hub apps.
4. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads
   (`.Values.repourl`). Several older configs in this repo write `repoUrl`;
   that spelling reaches the template as nil and renders an empty `repoURL`.
   Copy the `example-chart` config from the mock repo, not the older configs.

## Values precedence (lowest to highest)

1. `operators/<chart>/values.yaml` — chart, team-wide (shared with the fleet flows)
2. `in-cluster/<chart>/values.yaml` — chart on prod-hub

Deploy config precedence: `operators/<chart>/<chart>.yaml` →
`in-cluster/<chart>/<chart>.yaml`. Same convention as the fleet flows:
`operators/` is the default layer for every chart in day2, the
context-specific file wins.

A hub app's rendered spec also lists the `mces/...` value files with an empty
`<mce>` segment (`$values/mces//values.yaml`, ...). They can never exist and
are tolerated by `ignoreMissingValueFiles: true` — the effective stack is
exactly the two files above.

## Rollout

Both orderings are independently no-ops — unlike `mces/in-cluster-defaults`,
there is **no exclude-first constraint**: nothing else scans the repo's
top-level directories, so creating this folder before the platform change is
inert, and shipping the platform change first just leaves the ApplicationSet
generating zero Applications until a chart folder appears.

Before the **first real chart** lands here, verify the AppProject `<group>`
on prod-hub permits destination `in-cluster` plus the chart's target
namespace — deploy-type Applications under that project have never existed on
the prod-hub Argo before this folder.
