# mces/in-cluster-defaults

Charts under `charts/` are deployed to the **in-cluster** (the MCE hub itself) of
**every MCE** of this team (redbull). Add a chart folder here once instead of
duplicating it under `mces/<mce>/in-cluster/` for each MCE.

Naming convention in this repo: a folder's name is the destination as seen by the
Argo that consumes it. `mces/<mce>/in-cluster/` = the MCE hub (from the MCE's
argo); this folder = defaults for those. The repo **top level is reserved for
prod-hub context** (e.g. a future `in-cluster/` folder for team charts on the
prod-hub mgmt cluster) — that's why this folder lives under `mces/`.

## Layout

Same convention as an `mces/<mce>/in-cluster/<chart>/` folder, plus optional
per-MCE value overrides next to the base values:

```
mces/
  in-cluster-defaults/
    charts/
      <chart>/
        <chart>.yaml         # deploy config (repoUrl, projectNamespace, syncPolicy, ...)
        values.yaml          # helm values applied on every MCE's in-cluster
        values-<mce>.yaml    # optional: value overrides for one specific MCE
```

## Rules

1. **XOR rule:** a chart lives EITHER here OR under `mces/<mce>/in-cluster/<chart>/`
   — never in both. A violation produces two generator entries with the same
   Application name; controller behavior for duplicates is undefined — don't rely
   on it. (Both entries would at least render identical specs, since the template
   only uses `path.basename`.)
2. **Per-MCE overrides for a defaults chart go in `values-<mce>.yaml` here** — do
   NOT create `mces/<mce>/in-cluster/<chart>/` just to hold a values.yaml: the
   directory generator matches any directory, so that would violate rule 1.
3. **This folder is NOT an MCE.** The mcesAppset scans `mces/*` and explicitly
   excludes `mces/in-cluster-defaults`. Any future ApplicationSet or tooling that
   scans `mces/*` MUST replicate that exclude, or it will treat this folder as a
   cluster.

## How it is wired

In `argocd-day2-platform`:

- `mces/templates/mcesAppset.yaml` — `exclude: true` entry for
  `mces/in-cluster-defaults` so this folder is not treated as an MCE.
- `operators/templates/operators.yaml` — guarded by `cluster == in-cluster`: a
  second git directories generator over `mces/in-cluster-defaults/charts/*` in
  the team repo, plus a config valueFiles layer
  `$values/mces/in-cluster-defaults/charts/<chart>/<chart>.yaml`.
- `deploy/templates/deployApp.yaml` — guarded by `cluster == in-cluster`: two
  extra value layers (see precedence).

Because both generators feed the **same ApplicationSet and template**, and the
template only uses `path.basename`, a chart produces a **byte-identical
Application** no matter which folder it sits in. Moving a chart between the two
locations is an in-place no-op update, never a delete/recreate.

## Values precedence (lowest to highest)

1. `operators/<chart>/values.yaml` — chart, team-wide
2. `mces/<mce>/values.yaml` — MCE-wide
3. `mces/<mce>/in-cluster/values.yaml` — cluster-wide
4. `mces/in-cluster-defaults/charts/<chart>/values.yaml` — chart, every MCE in-cluster
5. `mces/in-cluster-defaults/charts/<chart>/values-<mce>.yaml` — chart + specific MCE
6. `mces/<mce>/in-cluster/<chart>/values.yaml` — per-MCE charts only (XOR rule)

The defaults layers (4–5) sit **after** the MCE/cluster-wide files — the same
precedence slot a chart's own values occupy today (a per-MCE chart's values file
already beats the MCE/cluster-wide files). So migrating a chart does not change
how any colliding key resolves.

Deploy config precedence: `operators/<chart>/<chart>.yaml` →
`mces/in-cluster-defaults/charts/<chart>/<chart>.yaml` →
`mces/<mce>/in-cluster/<chart>/<chart>.yaml` (last one for per-MCE charts only).
Defaults charts share one deploy config across all MCEs; if a chart needs
different config (not values) per MCE, keep it per-MCE instead.

## Rollout (each step is independently a no-op)

1. Platform: ship the `mces` (exclude) + `operators` + `deploy` chart changes.
   **The mcesAppset exclude MUST be live before (or together with) this folder's
   first appearance in a team repo** — otherwise the folder is generated as a
   bogus "MCE" Application with a nonexistent destination cluster. With the
   folder not yet present, all three changes are exact no-ops for hosted-cluster
   apps (byte-identical render) and spec-only for in-cluster apps (extra
   valueFiles entries pointing at not-yet-existing files,
   `ignoreMissingValueFiles: true`) — rendered workload manifests unchanged.
2. Team: add a **new** chart under `charts/` → new Applications only.
3. Migrate an existing duplicated chart, one chart per commit: **move** its
   folder from every `mces/<mce>/in-cluster/<chart>/` into `charts/<chart>/` in a
   single commit. If per-MCE values differed, put the common part in
   `values.yaml` and the diffs in `values-<mce>.yaml`.

   **Verify BEFORE merging, not after** — the apps run `selfHeal: true`, so a
   wrong resolution syncs to prod immediately; there is no post-merge inspection
   window. Offline check per MCE: `helm template` the actual chart with the old
   value-file stack vs the new one (same files, chart values read from the new
   location) and require an empty diff. Since the chart's values keep the same
   precedence slot, any non-empty diff means the move itself was not
   content-identical.

Verified against Argo CD 3.1.11: rendered old-vs-new `helm template` diffs are
byte-identical for hosted clusters, additive-only (missing-file-tolerant
valueFiles) for in-cluster; the mcesAppset diff is the exclude entry only.
