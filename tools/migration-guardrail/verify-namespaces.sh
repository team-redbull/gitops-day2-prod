#!/usr/bin/env bash
# THE CHECK verify.sh MISSES.
#
# verify.sh asks `oc auth can-i delete <res> -A`, which answers the
# CLUSTER-SCOPED question only. The gitops-operator ALSO creates a namespaced
# Role + RoleBinding in every namespace labelled
# `argocd.argoproj.io/managed-by=<argo-ns>`, granting full delete on
# deployments, statefulsets, pods, secrets, configmaps, PVCs, services, routes,
# jobs, roles/rolebindings and `projects`.
#
# `defaultClusterScopedRoleDisabled: true` does NOT touch those RoleBindings.
# So the guard rail can look perfect cluster-wide and still leave Argo able to
# delete every workload it actually manages. Verified on OpenShift GitOps 1.18.6.
#
#   ./verify-namespaces.sh [--instance NAME] [--namespace NS]
set -uo pipefail
INSTANCE=openshift-gitops
NAMESPACE=openshift-gitops
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)  INSTANCE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
SA="system:serviceaccount:${NAMESPACE}:${INSTANCE}-argocd-application-controller"
fails=0

echo "identity: $SA"
echo
echo "Namespaces with argocd.argoproj.io/managed-by=${NAMESPACE} (operator grants delete in these):"
# portable: no mapfile (bash 3.2 on macOS lacks it). Filter on the label VALUE,
# so a multi-instance cluster only reports this instance's namespaces.
NSES="$(oc get ns -l "argocd.argoproj.io/managed-by=${NAMESPACE}" \
        --no-headers -o custom-columns=N:.metadata.name 2>/dev/null)"
if [[ -z "${NSES// /}" ]]; then
  echo "  (none)"
else
  echo "$NSES" | sed 's/^/  /'
fi
echo
echo "Per-namespace delete check — every answer MUST be 'no':"
for ns in $NSES; do
  for res in deployments statefulsets secrets configmaps persistentvolumeclaims pods; do
    got="$(oc auth can-i delete "$res" -n "$ns" --as="$SA" 2>/dev/null || true)"
    [[ "$got" != "yes" ]] && got="no"
    if [[ "$got" == "no" ]]; then
      printf '  \033[32mok\033[0m   %-28s %-26s no\n' "$ns" "$res"
    else
      printf '  \033[31mFAIL\033[0m %-28s %-26s YES  <-- guard rail defeated here\n' "$ns" "$res"
      fails=$((fails+1))
    fi
  done
done

echo
echo "Subject sweep — EVERY binding naming this instance's SAs, cluster-wide."
echo "Catches admin-added grants in namespaces that carry no managed-by label,"
echo "which neither verify.sh (-A, cluster-scoped) nor the label check above sees."
SWEEP_OUT="$(python3 - "$INSTANCE" "$NAMESPACE" <<'PYEOF'
import json, subprocess, sys
inst, ns = sys.argv[1], sys.argv[2]
SAS = {f"{inst}-argocd-application-controller", f"{inst}-argocd-server"}

def oc(*a):
    try:
        return json.loads(subprocess.run(["oc",*a,"-o","json"],
               capture_output=True, text=True, check=True).stdout)
    except Exception:
        return {"items": []}

croles = {r["metadata"]["name"]: r for r in oc("get","clusterrole").get("items",[])}
nroles = {(r["metadata"]["namespace"], r["metadata"]["name"]): r
          for r in oc("get","role","-A").get("items",[])}

def offending(rules):
    out = []
    for r in (rules or []):
        vs = r.get("verbs") or []
        if not ({"delete","deletecollection","*"} & set(vs)):
            continue
        ag = r.get("apiGroups") or []
        if ag == ["argoproj.io"]:      # apps/appsets are deliberately deletable
            continue
        out.append("apiGroups=%s resources=%s verbs=%s"
                   % (ag, r.get("resources"), vs))
    return out

findings = 0
for kind, args in (("ClusterRoleBinding", ("get","clusterrolebinding")),
                   ("RoleBinding",        ("get","rolebinding","-A"))):
    for b in oc(*args).get("items", []):
        subs = b.get("subjects") or []
        if not any(x.get("kind")=="ServiceAccount" and x.get("name") in SAS
                   and x.get("namespace")==ns for x in subs):
            continue
        rr = b["roleRef"]; bns = b["metadata"].get("namespace")
        role = croles.get(rr["name"]) if rr["kind"]=="ClusterRole" \
               else nroles.get((bns, rr["name"]))
        if not role:
            continue
        bad = offending(role.get("rules"))
        if bad:
            findings += 1
            where = f"{bns}/" if bns else ""
            print(f"  !! {kind} {where}{b['metadata']['name']} -> "
                  f"{rr['kind']}/{rr['name']} grants delete:")
            for line in bad[:4]:
                print(f"       {line}")
            if len(bad) > 4:
                print(f"       ... and {len(bad)-4} more rule(s)")
sys.exit(min(findings, 100))
PYEOF
)"
sweep_rc=$?
if [[ -n "$SWEEP_OUT" ]]; then
  echo "$SWEEP_OUT"
  printf '  \033[31m%d delete-granting binding(s) found\033[0m — the guard rail is defeated by these.\n' "$sweep_rc"
  fails=$((fails + sweep_rc))
else
  printf '  \033[32mok\033[0m   no delete-granting bindings outside argoproj.io\n'
fi

echo
if [[ $fails -eq 0 ]]; then
  printf '\033[32mNAMESPACE-SCOPED CHECKS PASSED\033[0m\n'
else
  printf '\033[31m%d NAMESPACE-SCOPED CHECK(S) FAILED\033[0m\n' "$fails"
  echo
  echo "Fix for the migration window — drop the label so the operator removes its"
  echo "Role/RoleBinding. Argo keeps get/list/watch/create/update/patch cluster-wide"
  echo "from argocd-no-delete-role, so it can still sync; it just cannot delete:"
  echo "  oc label ns <ns> argocd.argoproj.io/managed-by-"
  echo "Restore after the window:  oc label ns <ns> argocd.argoproj.io/managed-by=${NAMESPACE}"
  exit 1
fi
