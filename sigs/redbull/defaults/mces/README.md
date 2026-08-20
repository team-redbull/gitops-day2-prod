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
   **Carve-out:** the pair is legal *iff* that exact MCE is listed under that
   chart in [`exclusions.yaml`](#structural-opt-out) — the deliberate
   full-override escape hatch, for when one MCE needs a different `repourl` /
   `targetRevision` rather than different values. The exclusion removes the
   fleet entry, so only one generator emits the name. Without the entry it is
   still a duplicate-app failure, so the *accidental* case (rule 2) is
   unaffected.
2. **Per-MCE overrides for a defaults chart go in `values-<mce>.yaml` here** —
   do NOT create `<mce>/in-cluster/<chart>/` just to hold a values.yaml:
   the directory generator matches any directory, so that would violate
   rule 1.
3. **Every directory directly under this folder becomes an Application on
   every MCE hub.** Never create non-chart directories here (docs, scripts,
   ...). Plain files are ignored by the directory generator and are safe —
   this README and `exclusions.yaml` are both plain files here for exactly
   that reason.
4. **This folder can never be mistaken for an MCE**: MCEs are the folders
   matching `sites/*/*/mces/*` — a `directories:` glob, where `*` matches
   exactly one path segment, so cluster discovery never leaves the `sites/`
   subtree. No exclude rules are needed anywhere, and no file you put here
   can change that (there are no marker files any more — see the team
   README).
5. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads.
6. **Leave `targetRevision` out of the deploy config here if the chart should
   follow per-OCP-version pins.** This file sits ABOVE the
   `operators/<chart>/versions/ocp-<v>/` layer in the config stack, so a
   `targetRevision` written here overrides every version pin silently.
   (`dhcp-api-token` currently pins `main` here — intentional, but it means
   version pins for it are inert until that line moves to `operators/`.)

## Structural opt-out

`exclusions.yaml` — one file for the whole folder, keyed by chart — is how a
fleet default skips a named set of MCE hubs. It is a plain file directly under
`defaults/mces/`, so the directory generator never sees it.

```yaml
# defaults/mces/exclusions.yaml
exclusions:
  <chart>:
    - <mce-name>
    - <another-mce-name>
```

Keys are chart folder names in this directory; values are **MCE names** (the
folder basename under `sites/<site>/<env>/mces/`, e.g. `ocp4-prep-mce-site1-a`)
— not `in-cluster`, which is the literal name every MCE hub shares.

Absent is the normal state — most teams never write this file, and a repo
without it behaves exactly as it did before the feature existed.

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
   commit**: chart-first deploys it to the excluded MCE for one sync interval,
   entry-first fails this rule.
2. **Every listed name is a real MCE** (a folder matching
   `sites/*/*/mces/*`).
3. **No `defaults/hub/exclusions.yaml`.** The hub is one cluster and never
   flows through the operators chart; delete the chart folder instead.

Rules 1 and 2 both exist because the two typos fail differently and **both are
silent**: a wrong chart name emits an exclude that matches no folder, so the
chart still deploys; a wrong MCE name matches no destination, so no exclude is
emitted at all.

**Excluded everywhere → delete the folder instead.** An exclusions list naming
every MCE is a chart that is not a fleet default.

**An exclusion is prevention, not teardown.** Removing the entry's app does not
uninstall a running workload: platform apps are `prune: false` with no
`resources-finalizer`, so the `-deploy` child and the workload are orphaned in
place, still running. See runbook **R10** in `ARCHITECTURE.md` for the manual
teardown, and for the undo (delete the entry — the wrapper reappears and
re-adopts the orphan in place).

## How it is wired

In `argocd-day2-platform`:

- `clusters/templates/inClusterApp.yaml` — the in-cluster Application is
  **statically rendered** per MCE (not folder-discovered), so defaults reach
  every MCE hub even when the MCE has no `in-cluster/` folder. It also resolves
  `$values/defaults/mces/exclusions.yaml` and passes it down as a Helm value —
  the only way the opt-out matrix can reach a generator (see
  [Structural opt-out](#structural-opt-out)).
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
2. `operators/<chart>/versions/ocp-<v>/values.yaml` — chart, per OCP version
   (`<v>` = the MCE's own OCP version, resolved at render time from the day1
   repo's `mastertag` — the **full** patch version, e.g. `ocp-4.16.27`)
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
