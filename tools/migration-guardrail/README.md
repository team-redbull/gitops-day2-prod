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
| `verify.sh` | Per-cluster **cluster-scoped** checks. Exits non-zero on any failure. |
| `verify-namespaces.sh` | Per-**namespace** checks + cluster-wide subject sweep for extra delete-granting bindings. Catches what `verify.sh` cannot see (Finding 1). |
| `preflight-lift.sh` | Run BEFORE lifting. Finds deletions that would fire on the lift (Finding 2). |

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

---

## Cluster-verified findings (2026-08-23, OpenShift GitOps 1.18.6)

Tested end-to-end on a live cluster against the `openshift-gitops` instance.
Two gaps were found that make the runbook above **insufficient on its own**.
Both are now covered by scripts in this directory.

### Finding 1 — `defaultClusterScopedRoleDisabled` does not cover managed namespaces

**This is the most likely reason a guard rail "did not work".**

The operator creates a namespaced `Role` + `RoleBinding` in every namespace
labelled `argocd.argoproj.io/managed-by=<argo-ns>`. On 1.18.6 that Role has 189
rules and grants full `delete`/`deletecollection` on `deployments`,
`statefulsets`, `pods`, `secrets`, `configmaps`, `persistentvolumeclaims`,
`services`, `routes`, `jobs`, `cronjobs`, `networkpolicies`, `roles`/`rolebindings`
and `projects` (the namespace itself).

`defaultClusterScopedRoleDisabled: true` removes only the **cluster-scoped**
role. The namespaced RoleBindings are untouched and are reconciled back by the
operator. Measured with the full guard rail applied:

| namespace | `delete deployments` as the app-controller |
|---|---|
| not labelled | `no` — guard rail holds |
| `managed-by` labelled | **`yes` — guard rail defeated** |

`verify.sh` cannot see this: it asks `oc auth can-i ... -A`, which answers the
cluster-scoped question and returns a reassuring `no`. **It is a false pass.**

- Detect: `./verify-namespaces.sh --instance <name> --namespace <ns>`
- Fix for the window: `oc label ns <ns> argocd.argoproj.io/managed-by-`
  Argo keeps `get/list/watch/create/update/patch` cluster-wide from
  `argocd-no-delete-role`, so it still syncs — it just cannot delete.
  Restore afterwards with `argocd.argoproj.io/managed-by=<argo-ns>`.

> Run `verify.sh` **and** `verify-namespaces.sh`. Neither is sufficient alone.

`verify-namespaces.sh` also runs a **subject sweep**: it enumerates every
RoleBinding and ClusterRoleBinding cluster-wide that names the instance's
ServiceAccounts, resolves each referenced Role/ClusterRole, and flags any
`delete`/`deletecollection`/`*` outside `argoproj.io`. That is what catches the
third shape of extra binding — one an admin added by hand in a namespace with
**no** `managed-by` label (e.g. `oc adm policy add-role-to-user admin -z <argo-sa>
-n <ns>`), which neither the cluster-scoped check nor the label check can see.

> **The Argo control namespace always carries one.** The operator creates a
> ~57-rule delete-granting Role/RoleBinding in the instance's own namespace
> (e.g. `openshift-gitops/openshift-gitops-argocd-application-controller`)
> regardless of any label. If workloads live in that namespace, the guard rail
> does not protect them. The sweep reports it.

### Finding 2 — the guard rail DEFERS deletions, it does not cancel them

Anything Argo still wants to delete executes within seconds of the lift.
Both were reproduced on-cluster:

| state when the guard rail is lifted | measured outcome |
|---|---|
| app OutOfSync with `prune: true`, prune denied and retrying | ConfigMap **deleted ~10s** after the lift |
| app left stuck in `Deleting` (finalizer still present) | **whole namespace gone in ~20s** |
| no pending deletions (all apps Synced, op `Succeeded`) | **survived 300s+** with delete fully restored |

So the lift is the dangerous moment, not the window. Before removing the guard
rail on any cluster:

```console
$ ./preflight-lift.sh          # exits non-zero while any hazard remains
```

It flags three classes: apps with a `deletionTimestamp`, OutOfSync apps with
automated prune, and sync operations whose error is a denied delete. Resolve
them **before** lifting:

- stuck delete → `oc patch application <n> -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'`
  (removes the App CR and orphans resources in place — the safe outcome)
- pending prune → make git match live state, or set `prune: false`, and confirm
  the app reports `Synced` with `operationState.phase=Succeeded` first.

> A wedged operation can sit in `phase=Running` while `sync=Synced`. Clear the
> finalizer first, then delete and recreate the Application, rather than
> reasoning about whether the queued operation will re-fire.

### Confirmed working, unchanged from the runbook

- Apply order (role → binding → CR patch) is load-bearing: the operator
  garbage-collects its own ClusterRole/Binding within seconds of the flip.
- Under the guard rail a cascade delete leaves the app stuck `Deleting` with
  every resource alive; the controller logs `cannot delete resource ... forbidden`.
- The documented finalizer-strip recovery removes the app and leaves resources intact.
- An app with **no** finalizer deletes instantly and orphans its resources
  (true with or without the guard rail — that is the repo's orphaning model).
- `prune: true` is denied and the app goes `OutOfSync` — expected, matches the
  `dhcp-api-token` row in the known-breakage table.
- Rollback restores the operator's default role within seconds.
