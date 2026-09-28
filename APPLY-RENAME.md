# APPLY-RENAME — renaming the `gitops-day2-prod` GitLab group

`gitops-day2-prod` is a **GitLab group**, not a repo. Under it live
`argocd-day2-platform.git` and the `sigs/<team>.git` subgroup. Renaming it
changes one path segment inside 17 hardcoded `repoURL:` strings and 2 CI
variables — nothing else.

Throughout: `<OLD>` = `gitops-day2-prod`, `<NEW>` = the new group path,
`<GITLAB>` = your GitLab host (copy it from a neighbouring line rather than
typing it).

---

## Why this is safe — what does *not* derive from the group path

This is the whole reason the rename is a URL edit and not a migration. Every
identity in the rendered fleet comes from somewhere else:

| Identity | Comes from | Group path involved? |
|---|---|---|
| Application names | `{{repository}}` (scmProvider) and `path.basename` | no |
| Namespaces `gitops-<team>` | `{{ .Values.group }}` | no |
| AppProject names | `{{ .Values.group }}` | no |
| `destination.name` / `.namespace` | day1 + sigs tree | no |
| scmProvider scan target | numeric group id `"243709"` | no — ids survive renames |
| scmProvider `tokenRef` | secret `gitops-day2` | no — a secret name |

Because names and destinations are unchanged, Argo treats the flip as an
**in-place update of `spec.source.repoURL`** on existing Applications. No
Application is deleted, no namespace is recreated, no workload is touched.
The rendered manifests downstream of the repoURL are byte-identical, so the
resync after the flip is a no-op.

`sigs/` repos need **no change at all** — they carry only `helm-charts` URLs
(`grep -rn 'gitops-day2-prod' sigs/` is empty).

---

## Preconditions

```bash
# 1. Clean baseline on main, before touching anything:
python3 tools/render-verify/render_chain.py snapshot --out /tmp/rv-before
#    Must print "N apps" and exit 0. Keep /tmp/rv-before — step 5 diffs against it.

# 2. Confirm the inventory is exactly 17 repoURL lines + 2 CI vars:
grep -rn "gitops-day2-prod" --include='*.yaml' argocd-day2-platform/ | grep repoURL | wc -l   # -> 17
grep -rn "gitops-day2-prod" tools/ci/*.gitlab-ci.yml | grep -c '^.*: *https'                  # -> 2
```

### Four things this repo cannot answer — check them in the cluster first

1. **Group id `243709`.** `groups/templates/groupsAppset.yaml` scans by numeric
   id, which is why the rename does not disturb the generator. Confirm the id
   really is the group you are renaming (or its `sigs` subgroup) before
   relying on that:
   `curl -s -H "PRIVATE-TOKEN: $T" https://<GITLAB>/api/v4/groups/243709 | jq .full_path`
2. **AppProject `sourceRepos`.** Team AppProjects come from the external chart
   `redbull/helm-charts/argo-appproject.git`. If it whitelists repos by the
   group path instead of a wildcard, every app fails project validation the
   moment the URL flips. Read the chart; if it is path-based, it must be
   widened to allow both `<OLD>` and `<NEW>` **before** step 4.
3. **Argo repo credentials.** `argocd repo list` / the `openshift-gitops`
   secrets. Credentials of type `repo-creds` match by **URL prefix**, so one
   new prefix entry covers the whole group; per-repo `repository` secrets match
   the **exact URL** and need one new secret each.
4. **Whatever applies the `groups` chart itself.** The `groups` ApplicationSet
   is the root of the whole chain, but nothing in this repo deploys it — a
   bootstrap Application on the hub (or a manual `helm upgrade` runbook) points
   at the platform repo, and it is therefore **not in the 17-line inventory**.
   If it is an Application, its `repoURL` needs the flip too, and it must be
   flipped *last* or it will re-render the old URLs over your change. Find it:
   `argocd app list -o json | jq -r '.[] | select(.spec|tostring|test("argocd-day2-platform")) | .metadata.name'`

---

## The order: rename first, flip second

Flipping the URLs before the new path exists points every Application at a
404 and degrades the whole fleet to `ComparisonError`. Do not do that.

### 1. Stage credentials for the new URL (no rename yet)

Add repo credentials for `https://<GITLAB>/redbull/<NEW>` alongside the
existing `<OLD>` ones. Both prefixes coexisting is harmless — Argo picks the
longest matching prefix per repo, and nothing points at `<NEW>` yet.

### 2. Prepare the flip commit — but do not merge it

One MR in the **platform** repo. Nothing in the sigs repos.

```bash
git checkout -b rename/day2-group
# Match the BARE group name, not `redbull/gitops-day2-prod` — some doc mentions
# (argocd-day2-platform/README.md, CHANGES.md) carry no `redbull/` prefix and a
# prefixed pattern skips them silently. The bare string only ever appears as
# this group path, so it is safe. (GNU sed; on macOS use `sed -i ''`.)
grep -rl 'gitops-day2-prod' --exclude-dir=.git . \
  | xargs sed -i 's|gitops-day2-prod|<NEW>|g'
git diff --stat
```

That touches, in the platform tree (17 `repoURL:` lines):

| File | lines |
|---|---|
| `operators/templates/operators.yaml` | 5 (4 sigs, 1 platform) |
| `clusters/templates/clustersAppset.yaml` | 3 |
| `mces/templates/inClusterAppset.yaml` | 3 |
| `mces/templates/mcesAppset.yaml` | 2 |
| `clusters/templates/inClusterApp.yaml` | 2 |
| `deploy/templates/deployApp.yaml` | 1 |
| `groups/templates/groupsAppset.yaml` | 1 |

plus `tools/ci/platform-mr.gitlab-ci.yml` (`SIGS_BASE`),
`tools/ci/sigs-mr.gitlab-ci.yml` (`PLATFORM_URL`), and the doc mentions in
`README.md`, `APPLY-EXCLUSIONS.md`, `CHANGES.md`.

Sanity-check the diff before merging — every changed line must mention the
group, and no line may change for any other reason:

```bash
git diff -U0 | grep '^[+-]' | grep -v '^[+-][+-]' \
  | grep -Ev 'gitops-day2-prod|<NEW>'                  # -> nothing
git diff -U0 --stat -- argocd-day2-platform/           # -> only the 7 files above
```

### 3. Rename the group in GitLab

Settings → General → Advanced → *Change group URL*.

GitLab keeps a **redirect from the old path** for git-over-HTTP, so Argo and
the CI `git clone`s keep working through the gap. That redirect is what makes
this a two-step with no outage — and it is why step 6 exists.

Then, before merging anything:

```bash
argocd app list -o wide | grep -v Synced        # -> nothing new
argocd app get <one-app> --hard-refresh          # proves the redirect resolves
```

Let it sit until you have seen at least one successful refresh cycle. Git
webhooks now carry the new path and will not match the old repoURL, so Argo
falls back to polling (~3 min) until step 4 lands. That is expected; do not
engineer around it.

### 4. Merge the flip

Merge the MR from step 2. The `groups` ApplicationSet re-renders from the
platform repo, child Applications get their `repoURL` updated in place, and
each re-resolves against `<NEW>`.

### 5. Verify

```bash
python3 tools/render-verify/render_chain.py snapshot --out /tmp/rv-after
python3 tools/render-verify/render_chain.py compare /tmp/rv-before /tmp/rv-after
```

The only differences may be `repoURL:` lines. Same app count, same names, same
namespaces, same destinations. Anything else means the sed caught something it
should not have.

In-cluster:

```bash
argocd app list -o wide | grep -Ev 'Synced.*Healthy'   # -> nothing
# every source URL in the fleet (these Applications are MULTI-source, so read
# spec.sources too — not just spec.source):
argocd app list -o json \
  | jq -r '.[].spec | (.source // empty | .repoURL), (.sources // [] | .[].repoURL)' \
  | sort -u                                              # -> no <OLD> URL survives
```

### 6. Cleanup — and one permanent rule

- Update the CI pipelines that actually run: `tools/ci/*.gitlab-ci.yml` here
  are **reference templates**. Each team repo has its own copy of the sigs
  pipeline with its own `PLATFORM_URL`. They survive on the redirect, but fix
  them so they do not depend on it.
- Re-point any GitLab webhook to Argo that was registered at the old path.
- Retire the `<OLD>` repo credentials once nothing references them.
- **Never create a new group or project at the old path.** Doing so kills the
  redirect retroactively and breaks any consumer you missed.

---

## Rollback

Before step 3: nothing to roll back.

Between steps 3 and 4: the redirect is carrying everything; either rename back
or continue forward. No Argo state has changed.

After step 4: revert the MR. The old path still resolves (the redirect is
bidirectional in effect — `<OLD>` redirects to `<NEW>`), so reverted apps sync
straight away. There is no destructive step to undo — `prune: false` holds
everywhere, and no Application name or namespace ever changed.
