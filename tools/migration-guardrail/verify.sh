#!/usr/bin/env bash
# Verification — read-only. Run on every cluster after apply-local.sh, and with
# --sa <remote-sa> on every DESTINATION cluster after Step 2b. The remote run is
# the one that actually proves identities #2/#4 are covered.
#
#   ./verify.sh [--instance NAME] [--namespace NS] [--context CTX]
#   ./verify.sh --sa system:serviceaccount:open-cluster-management-agent-addon:argocd-manager
set -uo pipefail

INSTANCE=openshift-gitops
NAMESPACE=openshift-gitops
CTX=""
SA_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)  INSTANCE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --context)   CTX="$2"; shift 2 ;;
    --sa)        SA_OVERRIDE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

OC=(oc)
[[ -n "$CTX" ]] && OC=(oc --context "$CTX")

SA="${SA_OVERRIDE:-system:serviceaccount:${NAMESPACE}:${INSTANCE}-argocd-application-controller}"
ASC="system:serviceaccount:${NAMESPACE}:${INSTANCE}-argocd-applicationset-controller"

fails=0
check() { # check <expected yes|no> <label> <can-i args...>
  local want="$1" label="$2"; shift 2
  local got
  got="$("${OC[@]}" auth can-i "$@" --as="$SA" 2>/dev/null || true)"
  [[ "$got" != "yes" ]] && got="no"
  if [[ "$got" == "$want" ]]; then
    printf '  \033[32mok\033[0m   %-46s %s\n' "$label" "$got"
  else
    printf '  \033[31mFAIL\033[0m %-46s got=%s want=%s\n' "$label" "$got" "$want"
    fails=$((fails+1))
  fi
}

printf '\033[1mverify guardrail on %s\033[0m\n' "$("${OC[@]}" config current-context 2>/dev/null)"
printf 'identity: %s\n\n' "$SA"

echo "MUST BE NO — the whole point:"
check no "delete deployments"            delete deployments -A
check no "delete namespaces"             delete namespaces
check no "delete secrets"                delete secrets -A
check no "delete statefulsets"           delete statefulsets -A
check no "delete persistentvolumeclaims" delete persistentvolumeclaims -A
check no "deletecollection pods"         deletecollection pods -A

echo
echo "MUST BE YES — apps/appsets stay recreatable:"
check yes "delete applications"          delete applications.argoproj.io -A
check yes "delete applicationsets"       delete applicationsets.argoproj.io -A

echo
echo "MUST BE YES — normal operation:"
check yes "create deployments"           create deployments -A
check yes "patch  deployments"           patch  deployments -A
check yes "update applications/status"   update applications.argoproj.io/status -A
check yes "get    customresourcedefs"    get customresourcedefinitions

if [[ -z "$SA_OVERRIDE" ]]; then
  echo
  echo "INFORMATIONAL — appset controller must keep generating through Phase C."
  echo "This fleet runs apps in gitops-<group> namespaces, so the appset"
  echo "controller's grants are most likely NAMESPACE-scoped and untouched by"
  echo "defaultClusterScopedRoleDisabled. A 'no' here is therefore NOT proof of a"
  echo "regression, and is deliberately not counted as a failure — cluster-scoped"
  echo "answer 'no' is the normal state for a namespace-scoped install."
  echo "The real test is: SAME ANSWER AS BEFORE THE FLIP. discover.sh prints the"
  echo "pre-flip baseline; compare against that, and confirm apps still generate."
  got="$("${OC[@]}" auth can-i create applications.argoproj.io --as="$ASC" -A 2>/dev/null || true)"
  [[ "$got" != "yes" ]] && got="no"
  printf '  \033[36minfo\033[0m %-46s %s   (baseline from discover.sh?)\n' \
    "appset-controller create applications (-A)" "$got"

  echo
  echo "Roles/bindings remaining after the flip (informational):"
  "${OC[@]}" get clusterrole,clusterrolebinding -o name 2>/dev/null \
    | grep -i -e argocd -e gitops | sed 's/^/  /'
fi

echo
if [[ $fails -eq 0 ]]; then
  printf '\033[32mALL CHECKS PASSED\033[0m\n'
else
  printf '\033[31m%d CHECK(S) FAILED\033[0m — do not proceed to the next cluster.\n' "$fails"
  exit 1
fi
