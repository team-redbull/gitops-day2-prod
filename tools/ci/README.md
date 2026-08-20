# Reference CI fragments

`tools/render-verify/render_chain.py` renders the whole day2 chain offline and
exits 1 on any consistency failure, so **one command is the entire lint job**.
These fragments wire it into GitLab CI for both repo roles.

The mock cannot host three real pipelines — three separate GitLab projects do
not exist here. **These fragments are the hand-off artifact**, not something
verified end to end. What *is* verified in the mock is the thing they invoke:
`snapshot` and `compare` run green with explicit `--group / --sigs /
--platform / --day1`, producing byte-identical results to the mock-derived
defaults.

## Preconditions (confirm before adopting — they cannot be checked from here)

1. **`helm` on the runner.** The harness shells out to `helm template`. Either
   the runner image ships it or the job installs it. `.gitlab-ci.yml` fragments
   below assume an image that has `helm` and `python3` with `PyYAML`.
2. **Read tokens for cross-project clones.** Every job clones the *other* two
   projects. A CI job token reaches other projects only if the target has that
   allow-listed (Settings → CI/CD → Token Access), otherwise use a group
   deploy token / `CI_JOB_TOKEN` alternative in `GIT_CREDS`.

**If cross-project cloning is not available**, the lint job still works
standalone on a sigs repo for the exclusion rules and the env allow-list — but
day1 parity, the duplicate-app check and `compare` all need the other
checkouts, so do not treat a standalone run as the full gate.

## The two jobs, and what each catches

`lint` renders the MR branch. `review` renders the target branch too and diffs
the two.

| check | what it catches |
|---|---|
| exclusion Rules 0–3 | a chart name or cluster name in `exclusions.yaml` that does not exist; a stray top-level key; a hub file |
| day1 parity | an MCE or hosted-cluster folder with no day1 `mastertag` — i.e. **a stray folder that would become a phantom Application** |
| DUPLICATE app | THE ONE INVARIANT — two generators emitting one app name (the XOR rule) |
| DEPTH-AMBIGUOUS `files:` glob | the Phase B prod incident — a `files:` glob matching deeper than intended |
| unsubstituted `{{ }}` | a placeholder that survived into a generated app |
| frozen lines | someone "fixing" `namespace: gitops-{{ .Values.repository }}`, which would rename every app |
| env allow-list / unknown `$ref` / render abort | a typo'd env folder; a bad `$values`/`$day1` prefix; a chart that will not render |

`compare` adds the second half: HARD on apps disappeared, identity changes
(name / namespace / project / destination / repoURL / releaseName /
syncPolicy), ref sources removed, or the resolved **sigs** value-file content
stack changing. That is what turns an exclusion MR into a reviewable two-line
`APPS DISAPPEARED` instead of a guess.

## Reading the result

`review` is **informational by design** (`allow_failure: true`): a deliberate
exclusion *is* an `APPS DISAPPEARED`, so a red X there is not automatically a
defect — it is the diff a human must read and approve. `lint` is the blocking
gate. Do not invert this: making `compare` blocking would make every
intentional removal unmergeable, and making `lint` non-blocking would let a
silent typo through.
