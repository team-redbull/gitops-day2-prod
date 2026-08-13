# defaults/hub

Chart folders in this directory are deployed to the **prod-hub mgmt cluster
itself** — the cluster running the `groups` ApplicationSet in
`openshift-gitops`. This is the hub member of the three fleet layers:
[`defaults/mces/`](../mces/) (every MCE hub) and
[`defaults/hosted-clusters/`](../hosted-clusters/) (every hosted cluster) are
its siblings.

Wiring: the `<group>-in-cluster` ApplicationSet (rendered by the platform
`mces` chart, which runs on prod-hub per team) scans `defaults/hub/*` and
creates, per chart folder, `<group>-in-cluster-<chart>` → the platform
`deploy` chart in hub mode (`hub: true`) → `<group>-in-cluster-<chart>-deploy`
with destination `in-cluster` (prod-hub), namespace = `projectNamespace`,
releaseName `<chart>`.

## Layout

```
defaults/
  hub/
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
   values layer. Hub-wide concerns belong in each chart's own values.
3. **A chart may exist both here and in the fleet flows** (hub and fleet are
   different destinations — no XOR rule against `sites/` or the other
   defaults folders). The deployments share only the team-wide
   `operators/<chart>/` layer; the hub values file never leaks into fleet
   apps (guarded by `hub: true` in the deploy template) and fleet/defaults
   values never leak into hub apps.
4. **The hub is version-less**: hub apps resolve no
   `operators/<chart>/versions/` layer and carry no
   `day2.gitops/ocp-version` label. A `targetRevision` for a hub chart
   belongs in `operators/<chart>/<chart>.yaml` or in this folder's config.
5. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads
   (`.Values.repourl`). Several older configs in this repo write `repoUrl`;
   that spelling reaches the template as nil and renders an empty `repoURL`.
   Copy the `example-chart` config, not the older configs.

## Values precedence (lowest to highest)

1. `operators/<chart>/values.yaml` — chart, team-wide (shared with the fleet flows)
2. `defaults/hub/<chart>/values.yaml` — chart on prod-hub

Deploy config precedence: `operators/<chart>/<chart>.yaml` →
`defaults/hub/<chart>/<chart>.yaml`.

## Rollout

Before the **first real chart** lands here, verify the AppProject `<group>`
on prod-hub permits destination `in-cluster` plus the chart's target
namespace — deploy-type Applications under that project have never existed on
the prod-hub Argo before this folder. (The planned DHCP scope-manager tenant
lands at `defaults/hub/dhcp-scope-manager/`.)
