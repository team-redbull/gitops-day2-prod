# APPLY-OCP-VERSIONS — rename the version layer to `ocp-versions/<v>/`

Standalone apply guide for one change. The per-OCP-version slot moves:

```
operators/<chart>/versions/ocp-<v>/{<chart>.yaml, values.yaml}     # old
operators/<chart>/ocp-versions/<v>/{<chart>.yaml, values.yaml}     # new
```

**`<v>` does not change.** It is still the destination's **full patch**
version, derived from day1's `mastertag` (`4.16.27-x86_64` → `4.16.27`), so a
folder is `ocp-versions/4.16.27/`, never `ocp-versions/4.16/`. How the version
is resolved, what the `day2.gitops/ocp-version` label carries, and the
layer-before-tag-flip ordering rule are all unchanged. This is a folder-name
change and nothing else.

Implemented and render-verified in the mock repo — §6 has the exact harness
output to expect.

> `<platform>` below is an `argocd-day2-platform` checkout, `<sigs>` a
> `sigs/<team>` checkout, `<day1>` a `gitops-day1/platform-config` checkout.

---

## 0. Does this document apply to you?

`CHANGES.md` has this rename **folded into its hunks** as of 2026-08-30. So
whether you need this document depends on whether you already applied the
old-convention templates. One command tells you:

```bash
cd <platform>            # on main, clean
grep -c 'versions/ocp-' deploy/templates/deployApp.yaml operators/templates/operators.yaml
```

| Output | What it means | What to do |
|---|---|---|
| `deployApp.yaml:1` and `operators.yaml:2` | old convention is live in your platform repo | **apply this whole document** |
| `deployApp.yaml:0` and `operators.yaml:0` | your platform already carries `ocp-versions/` (you pulled `CHANGES.md` after the fold) | **skip §3.** Still run §4 on the sigs repos, and §6 |
| anything else | your templates diverge from both conventions | stop; reconcile against `CHANGES.md` before touching this |

(`operators.yaml` counts 2 because one occurrence is the preamble comment.)

---

## 1. Why this is safe

Three things worth confirming rather than trusting, because the instinct after
the Phase B incident is to worry about phantom Applications:

1. **`operators/` is never scanned by a generator.** Renaming a folder under it
   cannot create or delete an Application. The complete set of generator paths
   in the platform charts is:

   | Chart | Generator paths |
   |---|---|
   | `mces/mcesAppset.yaml` | `sites/*/*/mces/*` |
   | `clusters/clustersAppset.yaml` | `<mcePath>/*`, `<mcePath>/in-cluster` |
   | `operators/operators.yaml` | `<clusterPath>/*`, `defaults/mces/*`, `defaults/hosted-clusters/*` |
   | `mces/inClusterAppset.yaml` | `defaults/hub/*` |

   None of them touches `operators/`, and all four are `directories:`
   (depth-exact under Go `path.Match`), not `files:`. Verify on your own tree:

   ```bash
   grep -rn 'directories:\|files:' -A3 <platform>/*/templates/*.yaml | grep 'path:'
   ```

2. **Both slots are `ignoreMissingValueFiles: true`.** An absent version folder
   is the normal state for most charts, not an error. That is what makes the
   rename cheap — and it is also exactly what makes §2's ordering rule
   necessary.

3. **No identity field moves.** App names, namespaces, projects, destinations,
   `releaseName`s, `syncPolicy`s and every `day2.gitops/*` label are untouched.
   Two path strings inside a `valueFiles:` list change; that is the whole blast
   radius.

---

## 2. Push order — the one hazard

Because the slot is optional, **either single-sided flip silently drops the
layer.** The chart falls back to `operators/<chart>/<chart>.yaml` and nothing
anywhere reports a problem — no render error, no lint failure, no event. The
app simply goes OutOfSync against the team default.
`ignoreMissingValueFiles` cannot tell "no layer needed" from "layer moved out
from under me".

The gap-free order is **copy → flip → delete**:

| # | Repo | Action | State during the window |
|---|---|---|---|
| 1 | sigs | **copy** `versions/ocp-<v>/` → `ocp-versions/<v>/`, both present | old platform still reads the old path — zero diff |
| 2 | platform | flip the two path strings, merge | new platform reads the new path, which now exists — zero diff |
| 3 | sigs | delete `versions/` | old path is referenced by nothing |

The two paths are never both in the same `valueFiles:` list — each template
version emits exactly one — so the duplication in step 1 cannot double-apply
values.

> **Your case is order-free.** Exactly one sigs repo has a `versions/` folder,
> it is not production, and you have said its existing apps don't matter. Use
> the plain `git mv` in §4.1 and push in whichever order suits you. Keep this
> table for the first time a **production** sig grows a version layer — the
> copy-first sequence is the one that has no silent window.

---

## 3. Platform repo — `argocd-day2-platform`

Two files, three hunks. Nothing else in either file changes.

### 3.1 `deploy/templates/deployApp.yaml` — the workload-values stack

One line, inside the `{{- else }}` (non-hub) branch of `valueFiles:`.

```diff
           - '$values/defaults/hub/{{ .Values.operator }}/values.yaml'
           {{- else }}
           - '$values/operators/{{ .Values.operator }}/values.yaml'
-          - '$values/operators/{{ .Values.operator }}/versions/ocp-{{ .Values.ocpVersion }}/values.yaml'
+          - '$values/operators/{{ .Values.operator }}/ocp-versions/{{ .Values.ocpVersion }}/values.yaml'
           - '$values/sites/{{ .Values.site }}/values.yaml'
           - '$values/sites/{{ .Values.site }}/{{ .Values.env }}/values.yaml'
```

The hub branch above it has no version slot and must stay that way — the
prod-hub is version-less.

### 3.2 `operators/templates/operators.yaml` — the preamble comment

```diff
      One derivation either way: strip the arch at the first '-' and use the
      rest verbatim (4.16.27-x86_64 -> 4.16.27). Version-pin layers are keyed
      by that exact version, so EVERY upgrade — z-streams included — needs its
-     operators/<chart>/versions/ocp-<v>/ folder created BEFORE day1 flips the
+     operators/<chart>/ocp-versions/<v>/ folder created BEFORE day1 flips the
      tag, or a pinned chart silently falls back to the team default. */ -}}
```

### 3.3 `operators/templates/operators.yaml` — the deploy-config stack

One line, in the leaf template's `valueFiles:`.

```diff
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
-              - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/versions/ocp-{{ $ocpVersion }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/ocp-versions/{{ $ocpVersion }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- if eq .Values.cluster "in-cluster" }}
               - '$values/defaults/mces/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
```

### 3.4 If you would rather not hand-edit

Same three hunks, mechanically:

```bash
cd <platform>
sed -i 's|/versions/ocp-{{ .Values.ocpVersion }}/|/ocp-versions/{{ .Values.ocpVersion }}/|' \
    deploy/templates/deployApp.yaml
sed -i 's|/versions/ocp-{{ $ocpVersion }}/|/ocp-versions/{{ $ocpVersion }}/|' \
    operators/templates/operators.yaml
sed -i 's|operators/<chart>/versions/ocp-<v>/ folder created|operators/<chart>/ocp-versions/<v>/ folder created|' \
    operators/templates/operators.yaml
git diff --stat        # must be exactly: 2 files changed, 3 insertions, 3 deletions
```

(On macOS use `sed -i ''`.)

### 3.5 Untouched by this change

`mces/templates/mcesAppset.yaml`, `mces/templates/inClusterAppset.yaml`,
`mces/templates/appProjectAppset.yaml`, `clusters/templates/clustersAppset.yaml`,
`clusters/templates/inClusterApp.yaml`, `groups/templates/groupsAppset.yaml`,
and `tools/render-verify/render_chain.py` — the harness renders the templates
rather than hardcoding the path, so it needs no change.

---

## 4. Sigs repos

### 4.1 The one repo that has `versions/`

Find it first, across all five:

```bash
for r in <sigs-1> <sigs-2> <sigs-3> <sigs-4> <sigs-5>; do
  printf '%-24s ' "$r"
  git -C "$r" ls-files -- 'operators/*/versions/*' | wc -l
done
```

In the repo that reports a non-zero count, on a branch off `main`:

```bash
cd <sigs>

# Look before you move — every folder that is about to be renamed:
git ls-files -- 'operators/*/versions/*'

# Anything under versions/ NOT named ocp-* is not handled by the loop below.
# Expect no output; if there is any, decide what it is before continuing.
ls -d operators/*/versions/*/ 2>/dev/null | grep -v '/ocp-[0-9]'

# The move. Run under sh/bash, not zsh.
for d in operators/*/versions/ocp-*/; do
  d=${d%/}
  chart=${d%/versions/ocp-*}     # -> operators/<chart>
  v=${d##*/ocp-}                 # -> <v>, e.g. 4.16.27
  mkdir -p "$chart/ocp-versions"
  git mv "$d" "$chart/ocp-versions/$v"
done
find operators -type d -name versions -empty -delete
```

Then confirm before committing — **every line must start with `R`**, meaning
git recorded a pure rename and no file content changed:

```bash
git status --short
git ls-files -- 'operators/*/versions/*'    # -> nothing left
git ls-files -- 'operators/*/ocp-versions/*'
```

Commit as one commit. A version folder that is copied rather than moved leaves
the old path in git; harmless after §3 lands, but it will confuse the next
person.

**Production variant (copy-first, per §2).** Replace the move loop with:

```bash
for d in operators/*/versions/ocp-*/; do
  d=${d%/}; chart=${d%/versions/ocp-*}; v=${d##*/ocp-}
  mkdir -p "$chart/ocp-versions/$v"
  cp -a "$d/." "$chart/ocp-versions/$v/"
  git add "$chart/ocp-versions/$v"
done
```

Merge that, then §3, then `git rm -r operators/*/versions` in a third MR.

### 4.2 Every other sigs repo

**Nothing to do.** A repo with no `versions/` folder has no version layer to
rename, and the slot has always been optional — `ignoreMissingValueFiles`
resolves the new path to nothing exactly as it resolved the old one. Do not
create empty `ocp-versions/` folders to "prepare"; git does not track empty
directories and an empty layer is indistinguishable from no layer.

### 4.3 What the teams need to be told

One line, and it only matters to teams that pin charts per OCP version:

> The version-pin folder is now `operators/<chart>/ocp-versions/<v>/`, with
> `<v>` the full patch version on its own (`4.16.27`). Same contents, same
> rules, same create-it-before-day1-flips-the-tag discipline.

---

## 5. Docs

Already updated in this repo, for reference when you diff yours:

| File | What changed |
|---|---|
| `CHANGES.md` | every phase hunk folded to the new spelling + a note in the header block |
| `APPLY-EXCLUSIONS.md` | the precondition grep at §Preconditions — `'^./operators/.*ocp-versions/'` |
| `ARCHITECTURE.md` | §1 tree, §3 stack tables, §4.2–4.3, §5 upgrade runbooks, glossary |
| `argocd-day2-platform/README.md` | the two stack tables, the chart-pinning section |
| `sigs/redbull/README.md` | the tree, the three-lever table, the version-key note |
| `sigs/redbull/defaults/{mces,hosted-clusters,hub}/README.md` | the value-stack lists |

`REFACTOR-PLAN.md` is deliberately **not** updated — it is the design record of
the decisions as they were made, not a live reference.

---

## 6. Verify

The harness lives in the **platform** repo (`<platform>/tools/render-verify/`)
and a sigs checkout does not have it — the three repos are separate GitLab
projects here, so every invocation needs the explicit flags. This is the same
form the CI fragments in `tools/ci/` use:

```bash
RENDER=<platform>/tools/render-verify/render_chain.py

# BEFORE any edit, with BOTH repos still at main:
python3 "$RENDER" snapshot --out /tmp/rv-before \
    --group <team> --sigs <sigs> --platform <platform> --day1 <day1>

# ... apply §3 in <platform> and §4 in <sigs> ...

python3 "$RENDER" snapshot --out /tmp/rv-after \
    --group <team> --sigs <sigs> --platform <platform> --day1 <day1>

python3 "$RENDER" compare /tmp/rv-before /tmp/rv-after
```

`<day1>` is a `gitops-day1/platform-config` checkout. Run the pair **once per
sigs repo you touched**, varying `--group` and `--sigs` and writing to
different `--out` directories; `--platform` and `--day1` stay the same. Because
§3 changes the platform repo, the "before" snapshots must all be taken before
you edit either repo.

### What a correct result looks like

The mock run, for the shape (your app count will differ):

```
snapshot: 33 apps, 12 appset CRs -> /tmp/rv-before
snapshot: 33 apps, 12 appset CRs -> /tmp/rv-after
== compare /tmp/rv-before -> /tmp/rv-after ==
apps: 33 -> 33
  [info] <mce>:<team>-<cluster>-<chart>: valueFiles list changed (resolution verified separately)
  [info] <mce>:<team>-<cluster>-<chart>-deploy: valueFiles list changed (resolution verified separately)
  ... two INFO lines per chart+cluster: the config stack and the workload stack ...
IDENTITY OK: names, destinations, releaseNames, syncPolicies and resolved value-file contents are unchanged.
```

Read it as three assertions:

- **app count identical, no `APPS DISAPPEARED`** — confirms §1.1, that no
  generator sees `operators/`;
- **INFO only, on `valueFiles list changed`** — the expected diff, and the only
  expected diff. Not every app appears: hub apps and the discovery apps carry no
  version slot, so they are silent here. The mock's run showed 22 INFO lines
  across 33 apps;
- **`IDENTITY OK`** including *resolved value-file contents* — this is the one
  that proves the layer did not silently vanish. If a version folder failed to
  move, the resolved content sequence for that chart loses an entry and you get
  a **HARD** `resolved sigs value-file content sequence changed`, naming the
  app and the missing path.

Anything HARD means stop and read it; nothing in this change can legitimately
produce one.

### Positive test (recommended, ~2 minutes)

The compare above proves nothing *broke*. This proves the new path is actually
*read* — worth doing once, in the repo that has a version layer, since a typo
in §3 fails silently in exactly the same way as success:

```bash
V=<the full version of a cluster in this repo, e.g. 4.16.27>
C=<a chart deployed to that cluster>

mkdir -p <sigs>/operators/$C/ocp-versions/$V
echo 'probeMarker: reads-new-path' > <sigs>/operators/$C/ocp-versions/$V/values.yaml

python3 "$RENDER" snapshot --out /tmp/rv-probe \
    --group <team> --sigs <sigs> --platform <platform> --day1 <day1>
python3 "$RENDER" compare /tmp/rv-after /tmp/rv-probe

rm -rf <sigs>/operators/$C/ocp-versions/$V      # leave no trace
```

The probe file only has to exist in the working tree — the harness reads the
checkout, not git, so there is nothing to commit or revert.

Expected: **HARD** `resolved sigs value-file content sequence changed` naming
`operators/$C/ocp-versions/$V/values.yaml`, and **only** on that chart's apps
on clusters whose day1 `mastertag` is `$V`. Same chart on a cluster at another
version must be untouched — that is the version selectivity surviving the
rename. (Here the HARD failure is the pass condition; you are deleting the
probe immediately after.)

---

## 7. Final gate

Across both repos, after everything has merged. Three checks, in decreasing
severity:

```bash
# 1. BLOCKING — no template still emits the old path
grep -rn 'versions/ocp-' <platform>/*/templates/

# 2. BLOCKING — no version folder is still at the old path
for r in <sigs-1> <sigs-2> <sigs-3> <sigs-4> <sigs-5>; do
  git -C "$r" ls-files -- 'operators/*/versions/*'
done

# 3. COSMETIC — prose still using the old spelling
grep -rn 'versions/ocp-' <platform> <sigs-1> <sigs-2> <sigs-3> <sigs-4> <sigs-5> \
  --exclude-dir=.git
```

1 and 2 must be empty: a hit in 1 is a missed §3 edit, a hit in 2 is a missed
§4 move. Either one means some chart is silently resolving to the team default
right now.

3 is a documentation sweep, and it has **legitimate hits** — any line that
quotes the old spelling in order to contrast it with the new one, such as the
rename note in `CHANGES.md`'s header. Read each hit; fix the ones that describe
the old path as if it were current.
