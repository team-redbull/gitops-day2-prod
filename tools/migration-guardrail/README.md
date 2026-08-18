# Migration guard rail — Argo CD may delete apps, not resources

A temporary RBAC change for the Phase C → Phase E window. Argo keeps full
control of `Application` and `ApplicationSet` CRs, so the tree moves can delete
and recreate them freely, but loses `delete` on everything else — so a mistake
during the moves costs cruft, never a client outage.

**Nothing here is deployed by Argo.** These are cluster manifests applied by
hand, out of band, on top of the fleet. No chart, template or value file in this
repo changes; `render_chain.py` snapshots must stay byte-identical.

---

## Read this before you decide it is worth doing

The repo is already designed for this failure mode, and the guard rail is
defense-in-depth on top of that, not the primary mechanism:

- **No `resources-finalizer` on any Application.** A dropped generator entry
  deletes the Application CR and orphans the workloads in place
  (ARCHITECTURE.md §6, REFACTOR-PLAN.md §3.3).
- **App names are basenames only** — a one-commit `git mv` is an *in-place
  update*, not delete + recreate.
- **Every platform appset is `prune: false`**; leaf workload apps are manual-sync.

What the guard rail actually closes:

1. `defaults/mces/dhcp-api-token` — the only `prune: true` in the repo.
2. A human cascade-deleting an app from the UI/CLI during the churn.
3. The design assumption turning out wrong (a chart or Argo version that adds a
   finalizer, a `Replace=true` sync path, an operator upgrade changing behaviour).

---

## Four identities, not one

Applying this only to prod-hub's local ServiceAccount protects essentially
nothing. Tracing `groupsAppset → mcesAppset → clustersAppset → operators.yaml →
deployApp`, four distinct API identities can delete something:

| # | Identity | Reaches | Workload surface |
|---|---|---|---|
| 1 | hub Argo app-controller **local SA** | prod-hub itself | `defaults/hub/*` charts |
| 2 | hub Argo's **cluster-secret credential on each MCE** | each MCE | only `argoproj.io` CRs + the `gitops-<group>` ns |
| 3 | MCE Argo app-controller **local SA** | the MCE itself | `operators/`, `defaults/mces/`, per-MCE `in-cluster/` — **large** |
| 4 | MCE Argo's **cluster-secret credential on each hosted cluster** | each hosted cluster | every hosted-cluster workload — **largest** |

`mcesAppset` sets `destination.name: {{path.basename}}` (the MCE);
`clustersAppset` / `operators.yaml` set `in-cluster`; `deployApp` sets
`{{.Values.cluster}}`. That is what splits the fleet across identities 2/3/4.

`apply-local.sh` covers #1 and #3. **#2 and #4 are manual (Step 2b) and are
where most of the workload surface lives — do not stop after the script.**

---

## Files

| File | What it is |
|---|---|
| `discover.sh` | Step 0. Read-only preconditions + rollback capture. |
| `01-clusterrole-no-delete.yaml` | The guard rail role. Three rules. |
| `02-clusterrolebinding-no-delete.yaml.tmpl` | Binding template; `__INSTANCE__`/`__NAMESPACE__` filled by `apply-local.sh`. |
| `03-argocd-cr-patch.yaml` | `defaultClusterScopedRoleDisabled: true` merge patch. |
| `04-breakglass.yaml` | Temporary `escalate`/`bind`/`use`. Bind for one sync, then delete. |
| `apply-local.sh` | Step 2a, one cluster. |
| `verify.sh` | Per-cluster checks. Exits non-zero on any failure. |

> **On the appset-controller line in `verify.sh`:** it is *informational*, not a
> gate. This fleet runs apps in `gitops-<group>` namespaces, so that controller's
> grants are most likely namespace-scoped and untouched by
> `defaultClusterScopedRoleDisabled` — a cluster-scoped `no` is the normal answer,
> not a regression. The real test is that it reads the **same as the pre-flip
> baseline** `discover.sh` prints, and that apps still generate.

---

## Runbook

### Step 0 — preconditions

```console
$ ./discover.sh                     # per cluster; writes rollback/<ctx>-argocd-rbac.yaml
```

Confirm all four:

1. `defaultClusterScopedRoleDisabled` exists in `oc explain argocd.spec`
   (OpenShift GitOps ≥ 1.11). **Without it the operator reconciles its default
   role back within seconds and the guard does nothing.**
2. The real ArgoCD instance name per cluster — ServiceAccounts are
   `<instance>-argocd-application-controller`. Do not assume `openshift-gitops`
   on the MCEs.
3. How destination clusters are registered, which decides where Step 2b lands:
   - **ACM** (`clusterpermission` / `managedserviceaccount` present) → put the
     rules in the `ClusterPermission` CR's `clusterRole.rules` on the hub. One
     declarative place per destination.
   - **Classic** (`argocd-manager` SA on each destination) → replace
     `argocd-manager-role` on each destination cluster. Nothing reconciles it
     back, so `oc apply` sticks.
4. **In every real sig repo** (the air-gapped ones, not this mock):
   ```console
   $ grep -rn "automated" .        # expect only defaults/mces/dhcp-api-token
   ```
   Anything auto-sync that ships RBAC breaks under the role — see
   "Escalation prevention" below.

### Step 1+2a — apply locally

```console
$ ./apply-local.sh --instance <name> --namespace <ns> --dry-run   # rehearse
$ ./apply-local.sh --instance <name> --namespace <ns>
$ ./verify.sh      --instance <name> --namespace <ns>
```

The script enforces the load-bearing ordering: **role and binding first, CR
patch last.** The operator garbage-collects its own binding on the flip; if the
replacement is not already there the controller ends up with zero cluster
permissions and the instance stops reconciling entirely.

### Step 2b — remote credentials

Per the Step 0 branch, using the rules from `01-clusterrole-no-delete.yaml`
verbatim. Then, **on each destination cluster**:

```console
$ ./verify.sh --sa system:serviceaccount:<ns>:<remote-sa>
```

That run is the one that proves identities #2 and #4 are covered.

### Rollout order

1. One prep MCE first — `ocp4-prep-mce-site1-a` + `ocp4-prep-eyal-site1`,
   `ocp4-prep-itay-site1`.
2. Soak one full sync cycle. Then **deliberately trigger the escalation edge**:
   click Sync on the prep `kyverno` app and confirm it fails with
   `attempting to grant RBAC permissions not currently held`. That proves the
   check fires on a no-op re-apply, which is why the freeze below exists. Do not
   take it on faith.
3. **Announce the freeze**: no manual syncs of RBAC-shipping charts, no new
   charts, for the duration.
4. Remaining prep MCEs → prod-hub → every prod MCE and hosted cluster.
   **Complete before the first Phase C `git mv` merges.**
5. Lift after Phase E is verified. This is a migration-window posture, not a
   permanent one.

### Rollback (seconds, any point)

```console
$ oc patch argocd <instance> -n <ns> --type=merge -p '{"spec":{"defaultClusterScopedRoleDisabled":false}}'
$ oc delete clusterrolebinding argocd-no-delete-binding
$ oc delete clusterrole argocd-no-delete-role
```

The operator recreates its default role. For remote identities, re-apply the
copies `discover.sh` captured in `rollback/`.

---

## Escalation prevention — why there is no `escalate`/`bind` rule

Kubernetes refuses to let a subject create *or update* a Role/ClusterRole
granting permissions it does not itself hold, or bind to a role it does not
fully hold. Under `cluster-admin` (`verbs: ["*"]`) this never fires. Under an
explicit verb list Argo no longer holds `delete`, `deletecollection`, `use`,
`escalate` or `bind`, so a chart shipping RBAC with `delete` verbs or an SCC
`use` grant is rejected:

```
clusterroles.rbac.authorization.k8s.io is forbidden: user
"system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
is attempting to grant RBAC permissions not currently held:
{APIGroups:["apps"], Resources:["deployments"], Verbs:["delete"]}
```

**It does not fire on the migration path**, because the check runs on writes and
the migration produces none for those charts:

- Every RBAC-shipping chart in the tree — `operators/cluster-roles`,
  `operators/kyverno`, `operators/bmhgen` — declares `syncPolicy` with only
  `syncOptions` and no `automated` block, so `deploy/templates/deployApp.yaml`
  renders them **manual-sync**. The single `automated` in the whole tree is
  `defaults/mces/dhcp-api-token`, which ships one Secret and no RBAC.
- A deleted-and-recreated Application re-renders, diffs against live state,
  finds it already matching, and reports Synced with **zero API writes**.

Leaving `escalate`/`bind` out is strictly better: without them Argo genuinely
cannot author a role granting itself `delete`, so this is a real boundary rather
than only an accident guard.

**The three edges where it does fire** — handled as procedure, not manifest:

1. A human clicks Sync on an RBAC-shipping chart. Argo applies *every* resource
   in an app by default (`ApplyOutOfSyncOnly=true` is opt-in), so even a no-op
   re-apply of an unchanged ClusterRole is an `update` call.
2. A new chart lands during the window.
3. Rendered RBAC genuinely changes because Phase C/C'/E shift which value files
   resolve — still gated behind a manual sync for these charts.

If one is unavoidable:

```console
$ oc apply -f 04-breakglass.yaml
$ oc adm policy add-cluster-role-to-user argocd-no-delete-breakglass \
    -z <instance>-argocd-application-controller -n <namespace>
# sync the ONE app, then immediately:
$ oc adm policy remove-cluster-role-from-user argocd-no-delete-breakglass \
    -z <instance>-argocd-application-controller -n <namespace>
$ oc delete -f 04-breakglass.yaml
$ oc get clusterrole argocd-no-delete-breakglass    # must be NotFound
```

While it is bound the guard is degraded to accident-only — `escalate` lets Argo
author a ClusterRole granting itself `delete`. Keep the window to the one sync.

---

## Known breakage — expect these, they are not bugs

| Symptom | Cause | Handling |
|---|---|---|
| Helm hook Jobs fail on re-sync | `hook-delete-policy: BeforeHookCreation` needs `delete` | expected; syncs cleanly once the guard is lifted |
| Sync fails on an immutable field | Argo falls back to delete + recreate (`Replace=true`/`Force=true`) | expected; fails loud instead of silently recreating |
| App stuck `Deleting` after a manual cascade delete | the finalizer cannot complete because resource deletes are denied | **resources are safe.** `oc patch application <n> -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'` |
| `dhcp-api-token` OutOfSync/Degraded | its `prune: true` can no longer prune | expected and intended |
| Manual sync of `kyverno`/`cluster-roles`/`bmhgen`: `attempting to grant RBAC permissions not currently held` | escalation prevention | **not a chart bug** — see above; use break-glass if unavoidable |

## Blind spots — do not over-trust this

- **`update`/`patch` are still fully allowed.** Scaling a Deployment to 0, or
  patching a Secret with wrong contents, is just as much an outage.
- **Garbage collection is not blocked.** If Argo patches an owner object, the
  kube-controller-manager deletes the children under *its* identity. RBAC on
  Argo does not see it.
- **Operator-driven deletes are not blocked.** A values change that makes an
  operator tear down a workload goes through the operator's SA.
- Only API-server-mediated deletes by the four identities above are covered.

## Fallback

Kyverno is already deployed fleet-wide (`operators/kyverno`). A `ClusterPolicy`
matching `operations: [DELETE]` from the Argo SA usernames, excluding
`argoproj.io`, gives the same guard with `validationFailureAction: Audit`
available first, and sidesteps the escalation-prevention collateral entirely.
Cost: it depends on a healthy webhook, and Kyverno is itself deployed by Argo.
Reach for it only if the breakage above proves worse than predicted on the prep
MCE.
