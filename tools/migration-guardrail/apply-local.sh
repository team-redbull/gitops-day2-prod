#!/usr/bin/env bash
# Step 2a — bind the guard rail to the LOCAL Argo identities on one cluster.
#
# This covers identities #1/#3 from the README table (the app-controller's own
# ServiceAccount). It does NOT cover the remote credentials Argo uses to reach
# other clusters — identities #2/#4, where most of the workload surface lives.
# Do Step 2b by hand per the discover.sh branch.
#
#   ./apply-local.sh [--instance NAME] [--namespace NS] [--context CTX] [--dry-run]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTANCE=openshift-gitops
NAMESPACE=openshift-gitops
CTX=""
DRY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)  INSTANCE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --context)   CTX="$2"; shift 2 ;;
    --dry-run)   DRY="--dry-run=server"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

OC=(oc)
[[ -n "$CTX" ]] && OC=(oc --context "$CTX")

SA_CTRL="${INSTANCE}-argocd-application-controller"
echo "cluster:   $("${OC[@]}" config current-context)"
echo "instance:  ${INSTANCE} (ns ${NAMESPACE})"
echo "subjects:  ${SA_CTRL}, ${INSTANCE}-argocd-server"
echo

# Fail early rather than half-way: a missing SA means the instance is named
# something else, and binding to a non-existent subject silently protects
# nothing while looking like it worked.
if ! "${OC[@]}" get sa "$SA_CTRL" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: ServiceAccount ${NAMESPACE}/${SA_CTRL} does not exist." >&2
  echo "       Run discover.sh and pass the real --instance/--namespace." >&2
  exit 1
fi

# ORDER IS LOAD-BEARING. The role and binding must exist BEFORE the operator is
# told to drop its default one — the operator garbage-collects its binding on
# the flip, and a gap leaves the controller with no cluster permissions at all.
echo "1/3  ClusterRole argocd-no-delete-role"
"${OC[@]}" apply ${DRY:+$DRY} -f "$HERE/01-clusterrole-no-delete.yaml"

echo "2/3  ClusterRoleBinding argocd-no-delete-binding"
sed "s/__INSTANCE__/${INSTANCE}/g; s/__NAMESPACE__/${NAMESPACE}/g" \
    "$HERE/02-clusterrolebinding-no-delete.yaml.tmpl" \
  | "${OC[@]}" apply ${DRY:+$DRY} -f -

echo "3/3  ArgoCD/${INSTANCE} defaultClusterScopedRoleDisabled=true"
"${OC[@]}" patch argocd "$INSTANCE" -n "$NAMESPACE" --type=merge \
  ${DRY:+$DRY} --patch-file "$HERE/03-argocd-cr-patch.yaml"

echo
echo "done. Now run:  ./verify.sh --instance ${INSTANCE} --namespace ${NAMESPACE}"
