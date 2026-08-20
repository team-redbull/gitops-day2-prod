# APPLY-EXCLUSIONS — you already finished the migration

**Use this document if your air-gapped repos are already at the end state of
the `sites/` refactor** (Phases A → E of `CHANGES.md` applied: the `sites/`
tree, no marker files, discovery by `directories:`, versions from the day1
repo's `mastertag`).

It is the standalone, per-file apply guide for **Phase F** (the structural
opt-out for fleet-default charts) and **Phase G** (every consistency check
behind one CI command). Both were added after the migration and neither is a
migration step — F is a new capability, G is tooling — so they apply cleanly
on their own, in this order, with nothing from C/C'/D/E re-run.

*Why* each change looks the way it does is in `CHANGES.md` §Phase F and
§Phase G. *What to type* is here. Don't read both to apply it; read this one.

## Preconditions

```bash
# 1. You are at the post-migration end state. All four must hold, per sigs repo:
git ls-files -- 'mces/*/mce.yaml' 'mces/*/*/hc.yaml'   # -> nothing (legacy layout gone)
git ls-files -- 'sites/*/*/mces/*/mce.yaml'            # -> nothing (markers deleted, Phase E.3)
ls sites/                                              # -> the sites/ tree exists
grep -rn 'ocpVersion' --include='*.yaml' . | grep -v '^./operators/.*versions/'
                                                       # -> nothing: no sigs repo declares a version

# 2. Clean baseline, on main, before touching anything:
python3 tools/render-verify/render_chain.py snapshot --out /tmp/rv-before
#    Must print "N apps" and exit 0. If it reports CONSISTENCY CHECK FAILURES,
#    stop and fix those first — they are pre-existing and unrelated to F/G.
```

**Nothing in F or G deletes a workload.** Phase F prevents apps from being
generated; it never uninstalls anything already running (see F.4). Phase G
only adds flags and files.

---

# Phase F — the structural opt-out

Four files change in the **platform** repo, then one optional file appears per
**sigs** repo. Push order matters: **platform first** (F.5).

Untouched by this whole phase: `mces/templates/mcesAppset.yaml`,
`mces/templates/appProjectAppset.yaml`, `mces/templates/inClusterAppset.yaml`,
`deploy/templates/deployApp.yaml`, `groups/templates/groupsAppset.yaml`.

> In the hunks below `<GITLAB>` stands for your GitLab host — copy the URL
> from the neighbouring lines in the same file rather than typing it.

## F.1 — `operators/templates/operators.yaml` (two sections, three hunks)

**F.1a — the preamble.** Insert directly after the existing `$ocpVersion`
line, before `apiVersion:`. Nothing above it changes.

```diff
 {{- $mastertag := required "mastertag missing: no day1 platform-config entry for this destination" .Values.mastertag | toString -}}
 {{- $ocpVersion := $mastertag | splitList "-" | first -}}
+{{- /* Fleet-default exclusions — the one structural opt-out from
+     defaults/mces/ and defaults/hosted-clusters/.
+     The data CANNOT live per-chart: chart folders are discovered from git at
+     generator time, and this template only ever sees Helm VALUES. So it
+     arrives from ONE fixed-path file per scope, defaults/<scope>/
+     exclusions.yaml, resolved by the parent Application (clustersAppset /
+     inClusterApp) through its $values ref source. Absent file -> empty dict
+     -> zero exclude entries -> byte-identical output to before this feature,
+     which is the permanent state of any team that never writes one.
+     A key naming a chart that does not exist, or a name that is not a real
+     cluster, is INERT and silent here — that is what render_chain.py's
+     lint_exclusions() exists to catch, in CI. */ -}}
+{{- $exclusions := .Values.exclusions | default dict -}}
+{{- if not (kindIs "map" $exclusions) -}}
+{{-   fail (printf "defaults/<scope>/exclusions.yaml: `exclusions` must be a map of <chart> -> [names], got %s" (kindOf $exclusions)) -}}
+{{- end -}}
+{{- $isMce := eq .Values.cluster "in-cluster" -}}
+{{- /* MCE hubs key on the MCE name (.Values.cluster is the literal
+     "in-cluster" for every one of them); hosted clusters on the folder name. */ -}}
+{{- $exKey := $isMce | ternary .Values.mce .Values.cluster -}}
+{{- $excluded := list -}}
+{{- range $chart, $names := $exclusions -}}
+{{-   if $names -}}
+{{-     if not (kindIs "slice" $names) -}}
+{{-       fail (printf "exclusions.%s must be a list of names, got %s" $chart (kindOf $names)) -}}
+{{-     end -}}
+{{-     if has $exKey $names -}}
+{{-       $excluded = append $excluded $chart -}}
+{{-     end -}}
+{{-   end -}}
+{{- end -}}
 apiVersion: argoproj.io/v1alpha1
 kind: ApplicationSet
```

**F.1b — the MCE defaults generator** (`spec.generators`, the
`{{- if eq .Values.cluster "in-cluster" }}` branch):

```diff
     - git:
         repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
         revision: main
+        # `exclude:` entries MUST sit in THIS generator's directories list and
+        # must match the include glob's output byte-for-byte. The controller
+        # computes include && !exclude PER GENERATOR, over the same path
+        # strings: an exclude in the sibling <clusterPath>/* generator is a
+        # no-op, and a deeper path removes nothing.
         directories:
           - path: "defaults/mces/*"
+          {{- range $chart := $excluded }}
+          - path: "defaults/mces/{{ $chart }}"
+            exclude: true
+          {{- end }}
     {{- else if not .Values.hub }}
```

**F.1c — the hosted-clusters defaults generator** (the `{{- else if not
.Values.hub }}` branch, same file):

```diff
     - git:
         repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
         revision: main
+        # Same two constraints as the MCE generator above: same block, and
+        # byte-for-byte equal to what the include glob emits.
         directories:
           - path: "defaults/hosted-clusters/*"
+          {{- range $chart := $excluded }}
+          - path: "defaults/hosted-clusters/{{ $chart }}"
+            exclude: true
+          {{- end }}
     {{- end }}
```

> **Do NOT touch `spec.template`.** The `{{ "{{" }}` escaping dance applies
> only there. These hunks are in `generators:`, which never reaches
> fasttemplate, so plain `{{ $chart }}` is correct — escaping it here would
> emit a literal `{{ $chart }}` into the CR.

> **Both generators, not one.** A `$excluded` entry that has nowhere to land
> is silently ignored, so patching only the MCE branch produces a feature that
> works on hubs and does nothing on hosted clusters — with no error anywhere.

## F.2 — `clusters/templates/clustersAppset.yaml` (two hunks)

**F.2a — the valueFile, FIRST in the list**
(`spec.template.spec.sources[0].helm.valueFiles`). Order is load-bearing: day1
must outrank a stray `mastertag` in the exclusions file.

```diff
             valueFiles:
+              # Generation input, not workload config: the team's fleet-default
+              # opt-out matrix. FIRST on purpose — day1 must outrank it.
+              - '$values/defaults/hosted-clusters/exclusions.yaml'
               - '$day1/sites/{{ .Values.site }}/mces/{{ .Values.mce }}/hostedClusters/{{ "{{" }}path.basename{{ "}}" }}.yaml'
             values: |
```

**F.2b — a third source, appended after `ref: day1`** (`spec.template.spec.sources`).
`sources[0]` must stay the platform source — append, never prepend:

```diff
         - repoURL: 'https://<GITLAB>/redbull/gitops-day1/platform-config.git'
           targetRevision: main
           ref: day1
+        - repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+          targetRevision: main
+          ref: values
       destination:
```

## F.3 — `clusters/templates/inClusterApp.yaml` (two hunks)

This app gains its **first ever** `$values` reference. That makes it the live
checkpoint in F.5.

**F.3a — a new `valueFiles` field** (`spec.sources[0].helm`). The field does
not exist in this file yet; `ignoreMissingValueFiles: true` already does. It
goes **above** the inline `values: |`:

```diff
       helm:
         ignoreMissingValueFiles: true
+        # This app's FIRST $values reference. The team's fleet-default opt-out
+        # matrix is a generation input, not workload config — the operators
+        # chart turns it into `exclude:` entries in its defaults/mces
+        # generator. Absent file -> nothing resolves (ignoreMissingValueFiles)
+        # -> no exclusions, which is the normal state. The inline values below
+        # are applied after valueFiles, so `mastertag` cannot be shadowed from
+        # here.
+        valueFiles:
+          - '$values/defaults/mces/exclusions.yaml'
         values: |
           group: '{{ .Values.group }}'
```

**F.3b — a second source** (`spec.sources`), after the inline block ends:

```diff
           mastertag: '{{ $mastertag }}'
+    - repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+      targetRevision: main
+      ref: values
   destination:
     name: in-cluster
```

> Note the indentation difference between F.2b and F.3b: `clustersAppset`'s
> sources are nested under `spec.template.spec` (8 spaces), `inClusterApp`'s
> under `spec` (4 spaces). Copy the indentation of the source above it.

## F.4 — `tools/render-verify/render_chain.py` (four edits)

Easiest path: **copy the whole updated file across** rather than hand-patching
— it is a self-contained tool, and the F and G changes to it are large. If you
must patch by hand, the four edits are:

1. **`CONTROL_FILES`**, beside `SIGS_MARKER` near the top:

   ```python
   CONTROL_FILES = {"defaults/hosted-clusters/exclusions.yaml",
                    "defaults/mces/exclusions.yaml"}
   ```

2. **`lint_exclusions()`** — a new function, defined just before
   `lint_frozen_lines()`, enforcing the four rules per scope and skipping
   silently when the file is absent:

   | rule | check |
   |---|---|
   | 0 | `exclusions` is the **only** top-level key; its value is a map; each entry is a list of strings or null |
   | 1 | every key is a directory in that same `defaults/<scope>/` |
   | 2 | every listed name is a real folder basename — MCEs `sites/*/*/mces/*`, hosted clusters `<mce>/*` minus `in-cluster` |
   | 3 | `defaults/hub/exclusions.yaml` must not exist |

   Called from `take_snapshot` **immediately after `lint_sigs_tree()` and
   before the render `try:`** — a malformed file makes `helm_template` raise,
   which collapses into one `render aborted:` line, so the precise rule message
   must already be in `CHECK_FAILURES` by then.

3. **Re-bucket the control files** in `resolve_value_files`, right after
   `rel = posixpath.normpath(rel)`:

   ```python
   if repo == "sigs" and rel in CONTROL_FILES:
       repo = "control"
   ```

4. **Report the control bucket** in `compare`, next to the existing day1 block,
   as INFO. Without this, adding one exclusion raises a HARD diff on **every**
   app in the team, because the file's hash is in every app's resolved
   sequence.

## F.5 — apply order and gates

**The platform change is inert on its own**: with no `exclusions.yaml` anywhere,
`$excluded` is empty and both generators chomp to exactly their pre-change
YAML. So platform goes first, and gets verified before any data exists.

```bash
# 1. Platform MR, F.1–F.4. Gate:
python3 tools/render-verify/render_chain.py snapshot --out /tmp/rv-plat
python3 tools/render-verify/render_chain.py compare /tmp/rv-before /tmp/rv-plat
```

**Required:** `apps: N -> N` (same count), `IDENTITY OK`, **zero HARD**.
Expected INFO: **exactly the discovery apps** — every hosted-cluster app and
every static `<team>-in-cluster` app, each reporting `ref sources added` and
`valueFiles list changed`, and nothing else. (In the mock that is 6 apps: 4
hosted clusters + 2 MCE hubs. Yours scales with your fleet.) **Any other app in
the INFO list, any HARD line, or any `apps added` is a stop.**

```
# 2. Merge and push the PLATFORM repo. Then, on ONE MCE, confirm that
#    <team>-in-cluster and one <team>-<hosted-cluster> reach Synced/Healthy.
```

That step is not optional and cannot be simulated: `inClusterApp` has never
carried a `$values` reference before, and this is the only thing that exercises
the missing-`$values`-file path against a live repo-server. **Do it before
pushing any sigs data.**

```bash
# 3. Only then, per sigs repo that wants an exclusion:
#    create defaults/mces/exclusions.yaml (and/or the hosted-clusters one)
python3 tools/render-verify/render_chain.py snapshot --out /tmp/rv-data
python3 tools/render-verify/render_chain.py compare /tmp/rv-plat /tmp/rv-data
```

**This compare exits 1, and that is the pass condition** — a deliberate
exclusion *is* an `APPS DISAPPEARED`. What you are checking is that the list is
exactly what you asked for:

```
apps: N -> N-2
  [info] <mce>:<team>-in-cluster: exclusion control file [] -> [('defaults/mces/exclusions.yaml', '<hash>')]
HARD FAILURES:
  [FAIL] APPS DISAPPEARED: ['<mce>:<team>-in-cluster-<chart>',
                            '<mce>:<team>-in-cluster-<chart>-deploy']
```

**Two entries per exclusion** — the wrapper *and* its `-deploy` leaf, because
the harness renders the whole chain. One `[info] exclusion control file` line
per app that resolves the file. **No `valueFiles list changed` lines** — those
paths changed in step 1; only resolution changes now. Anything else in the
disappeared list, or any `resolved sigs value-file content sequence changed`,
is a **stop**.

## F.6 — the data file

Create only where an exception is actually wanted. **Absent is the normal
state** — do not seed empty template files into every repo. A file in
`defaults/hosted-clusters/` is invalid until that folder has at least one chart
folder (Rule 1 would fail), so a team with an empty `defaults/hosted-clusters/`
gets documentation, not a file.

```yaml
# sigs/<team>/defaults/mces/exclusions.yaml
exclusions:
  dhcp-api-token:
    - ocp4-prep-mce-site1-a
```

Ship it with a header carrying the four rules, "excluded everywhere → delete
the folder instead", "a new fleet chart plus its exclusion entry land in the
**same commit**", "values differences belong in `values-<mce>.yaml`", and the
warning that this does **not** tear down an existing deployment. Copy the
header from the mock's file rather than rewriting it.

## F.7 — documentation to update

| File | What |
|---|---|
| `sigs/<team>/defaults/hosted-clusters/README.md` | **Rule 4 says the opposite of this feature and must be rewritten** ("There is no structural opt-out" → values vs. presence, two files). Rule 1 (XOR) gains the exclusion carve-out. Rule 3 names `exclusions.yaml` as a safe plain file. New `## Structural opt-out` section |
| `sigs/<team>/defaults/mces/README.md` | mirror of the above, keys are MCE names |
| `sigs/<team>/defaults/hub/README.md` | one rule: no exclusions here, single cluster, Rule 3 fails if you create the file |
| `sigs/<team>/README.md` | the two `exclusions.yaml` entries in the tree diagram; a short section pointing at the per-folder READMEs |
| `ARCHITECTURE.md` | §2 chain table rows; new §2.2; §6-4 XOR carve-out; §6-5 control bucket + exclusion lints; invariants checklist; **runbook R10** |
| `argocd-day2-platform/README.md` | §3 chain table; §4 (it says "No registries, no exclude lists" — now false); §6.5/§6.6 valueFiles and sources; §6.7 structural-opt-out block; §15 harness notes |

## F.8 — negative tests (run, confirm, revert — never commit)

Each one takes a minute and each proves a different thing. Do them on one repo,
not all of them.

| # | Change | Expect |
|---|---|---|
| 1 | chart key typo (`dhcp-api-tokn`) | Rule 1 fails. **Then bypass the lint** and confirm the render succeeds and the chart *still deploys* — the proof that the lint is the enforcement, not hygiene |
| 2 | cluster name typo | Rule 2 fails; bypassed, **no exclude entry is emitted anywhere at all** |
| 3 | stray `mastertag: 9.9.9` in a `defaults/hosted-clusters/exclusions.yaml` | Rule 0 fails; bypassed, the `ocp-version` labels are unchanged — day1 still outranks it (this only proves anything in the *hosted-cluster* scope; on the MCE hub the inline values always win) |
| 4 | create `defaults/hub/exclusions.yaml` | Rule 3 fails |
| 5 | scalar instead of list; list instead of map | Rule 0 fails **and**, bypassed, the Helm `fail` fires loudly with the file named |

Confirm `git status` is clean afterwards.

---

# Phase G — every check in CI

Independent of F, and applies to the same three repos. Nothing here changes
what renders.

## G.1 — `tools/render-verify/render_chain.py` (already copied in F.4)

`GROUP` was a module constant and `SIGS` / `PLATFORM` were derived from a
single-checkout layout. Air-gapped, those are three separate GitLab projects.
Three changes:

1. `--group` (default `redbull`) replaces the constant. In a sigs pipeline this
   is `$CI_PROJECT_NAME`, which **is** the team name — the `scmProvider`
   generator names teams by repo, so the two are the same string by
   construction.
2. `--sigs` and `--platform` path flags, defaulting to the mock-derived values,
   so nothing changes for a local run.
3. All three checkouts validated up front: a missing one exits 2 naming the
   flag to pass, never a traceback.

**No new subcommand is needed for a lint job** — `snapshot` already exits 1 on
any check failure, so a lint job is `snapshot` with the output discarded.

Confirm the flags are behaviour-neutral before wiring any pipeline:

```bash
python3 tools/render-verify/render_chain.py snapshot --out /tmp/rv-flags \
  --group <team> --sigs <sigs-checkout> \
  --platform <platform-checkout> --day1 <day1-checkout>
python3 tools/render-verify/render_chain.py compare /tmp/rv-data /tmp/rv-flags
# -> apps: N -> N, IDENTITY OK
```

## G.2 — where the harness lives

`render_chain.py` **moves to, or is mirrored into, the platform repo**. It is
platform tooling that sigs pipelines consume, and both pipelines below clone
the platform repo anyway.

## G.3 — the pipelines

Copy `tools/ci/sigs-mr.gitlab-ci.yml` and `tools/ci/platform-mr.gitlab-ci.yml`
and adapt the host/group variables. Each defines two jobs:

- **`lint` — blocking.** `snapshot` the MR branch. This is the gate.
- **`review` — informational (`allow_failure: true`).** `snapshot` the target
  branch too, then `compare`.

**Do not invert those.** A deliberate exclusion or decommission *is* an `APPS
DISAPPEARED`, so a blocking `compare` makes every intentional removal
unmergeable; a non-blocking `lint` lets a silent typo through, which is the
exact failure mode Phase F introduced.

Roles: a **sigs MR** clones platform@main + day1@main and renders its own
branch. A **platform MR** clones day1@main plus one or more representative sigs
repos and renders platform@MR against platform@target — that is the job that
proves a platform change is inert where it should be.

## G.4 — preconditions to confirm before adopting

Neither can be checked offline:

1. **`helm` on the runners** — the harness shells out to `helm template`.
   Also `python3` with `PyYAML`. Either the runner image ships them or the job
   installs them.
2. **Read tokens for cross-project clones** — every job clones the other two
   projects. A CI job token reaches another project only if that project
   allow-lists it (Settings → CI/CD → Token Access).

**If cross-project cloning is unavailable**, the `lint` job still works
standalone on a sigs repo for the exclusion rules and the env allow-list — but
day1 parity, the duplicate-app check and `compare` all need the other
checkouts. Do not treat a standalone run as the full gate.

---

# After both phases

Day-to-day use is **runbook R10** in `ARCHITECTURE.md`: how to add an
exclusion, what to expect from `compare`, the manual teardown (an exclusion
orphans the workload in place — it never uninstalls anything), the undo, and
the full-override escape hatch.

The one thing worth re-reading before the first real exclusion: **a typo on
either axis is silent everywhere except CI.** Helm renders, Argo generates, and
the chart keeps deploying to the cluster someone asked to opt out.
