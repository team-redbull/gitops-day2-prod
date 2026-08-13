# defaults/mces

Chart folders in this directory are deployed to the **in-cluster** (the MCE
hub itself) of **every MCE** of this team (redbull). Add a chart folder here
once instead of duplicating it under each MCE's `in-cluster/`. Siblings:
[`defaults/hub/`](../hub/) (prod-hub) and
[`defaults/hosted-clusters/`](../hosted-clusters/) (every hosted cluster).

## Layout

Same convention as an MCE's `in-cluster/<chart>/` folder, plus optional
per-env and per-MCE value overrides next to the base values:

```
defaults/
  mces/
    <chart>/
      <chart>.yaml         # deploy config (repourl, projectNamespace, syncPolicy, ...)
      values.yaml          # helm values applied on every MCE's in-cluster
      values-<env>.yaml    # optional: overrides for one env (prod | prep | test)
      values-<mce>.yaml    # optional: overrides for one specific MCE
```

## Rules

1. **XOR rule:** a chart lives EITHER here OR under a specific MCE's
   `in-cluster/<chart>/` — never in both. A violation produces two generator
   entries with the same Application name; controller behavior for duplicates
   is undefined — don't rely on it.
2. **Per-MCE overrides for a defaults chart go in `values-<mce>.yaml` here** —
   do NOT create `<mce>/in-cluster/<chart>/` just to hold a values.yaml:
   the directory generator matches any directory, so that would violate
   rule 1.
3. **Every directory directly under this folder becomes an Application on
   every MCE hub.** Never create non-chart directories here (docs, scripts,
   ...). Plain files (like this README) are ignored by the directory
   generator and are safe.
4. **This folder can never be mistaken for an MCE**: MCEs are discovered by
   their `config.yaml` (files generator) — this folder has none. No exclude
   rules are needed anywhere.
5. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads.
6. **Leave `targetRevision` out of the deploy config here if the chart should
   follow per-OCP-stream pins.** This file sits ABOVE the
   `operators/<chart>/versions/ocp-<v>/` layer in the config stack, so a
   `targetRevision` written here overrides every stream pin silently.
   (`dhcp-api-token` currently pins `main` here — intentional, but it means
   stream pins for it are inert until that line moves to `operators/`.)

## How it is wired

In `argocd-day2-platform`:

- `clusters/templates/inClusterApp.yaml` — the in-cluster Application is
  **statically rendered** per MCE (not folder-discovered), so defaults reach
  every MCE hub even when the MCE has no `in-cluster/` folder.
- `operators/templates/operators.yaml` — for `cluster == in-cluster`: a
  second git directories generator over `defaults/mces/*`, plus the config
  layer `$values/defaults/mces/<chart>/<chart>.yaml`.
- `deploy/templates/deployApp.yaml` — for `cluster == in-cluster`: the three
  value layers below (5–7).

Because both generators feed the **same ApplicationSet and template**, and the
template only uses `path.basename`, a chart produces a **byte-identical
Application** no matter which folder it sits in. Moving a chart between the
two locations is an in-place no-op update, never a delete/recreate.

## Values precedence (lowest to highest)

1. `operators/<chart>/values.yaml` — chart, team-wide
2. `operators/<chart>/versions/ocp-<v>/values.yaml` — chart, per OCP stream
   (`<v>` = the MCE's own OCP version, from its `config.yaml`)
3. `sites/<site>/values.yaml` — site-wide
4. `sites/<site>/<env>/values.yaml` — site + env
5. `defaults/mces/<chart>/values.yaml` — chart, every MCE in-cluster
6. `defaults/mces/<chart>/values-<env>.yaml` — chart + env
7. `defaults/mces/<chart>/values-<mce>.yaml` — chart + specific MCE
8. `sites/<site>/<env>/mces/<mce>/values.yaml` — MCE-wide
9. `sites/<site>/<env>/mces/<mce>/in-cluster/values.yaml` — cluster-wide
10. `.../in-cluster/<chart>/values.yaml` — per-MCE charts only (XOR rule)

Deploy config precedence: `operators/<chart>/<chart>.yaml` →
`operators/<chart>/versions/ocp-<v>/<chart>.yaml` →
`defaults/mces/<chart>/<chart>.yaml` →
`.../in-cluster/<chart>/<chart>.yaml` (per-MCE charts only).

## Migrating a duplicated chart into this folder

One chart per commit: **move** its folder from every MCE's
`in-cluster/<chart>/` into `defaults/mces/<chart>/` in a single commit. If
per-MCE values differed, put the common part in `values.yaml` and the diffs
in `values-<mce>.yaml`.

**Verify BEFORE merging, not after** — the platform apps run
`selfHeal: true`; there is no post-merge inspection window. Run the render
check and require: identical app names, identical resolved value-file
contents.
