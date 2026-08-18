#!/usr/bin/env bash
# Step 0 — preconditions. Read-only: makes no change to any cluster.
#
# Run once per cluster that will carry the guard rail (prod-hub, every MCE).
# Writes a rollback copy of the current app-controller binding to ./rollback/.
#
#   ./discover.sh                 # current oc context
#   ./discover.sh <context-name>  # a named kubeconfig context
set -uo pipefail

CTX="${1:-}"
OC=(oc)
[[ -n "$CTX" ]] && OC=(oc --context "$CTX")

CLUSTER="$("${OC[@]}" config current-context 2>/dev/null || echo unknown)"
ROLLBACK_DIR="$(dirname "$0")/rollback"
mkdir -p "$ROLLBACK_DIR"

hdr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }

printf '\033[1mmigration guardrail — discovery on %s\033[0m\n' "$CLUSTER"

# ---------------------------------------------------------------- a. operator
hdr "a. Operator support for defaultClusterScopedRoleDisabled"
if "${OC[@]}" explain argocd.spec 2>/dev/null | grep -qi 'defaultClusterScopedRoleDisabled'; then
  note "SUPPORTED"
else
  note "NOT FOUND in argocd.spec — this operator version cannot hand over the"
  note "cluster-scoped role. Without it the operator reconciles its default role"
  note "back and the guard does nothing. STOP and upgrade (need GitOps >= 1.11)."
fi
"${OC[@]}" get csv -A 2>/dev/null | grep -i 'gitops-operator' | head -5

# ------------------------------------------------------- b. current binding(s)
hdr "b. Current app-controller binding (captured for rollback)"
"${OC[@]}" get clusterrolebinding -o json 2>/dev/null \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)
hits=[i for i in d["items"]
      if "argocd-application-controller" in i["metadata"]["name"]
      or any("argocd" in (s.get("name") or "") for s in (i.get("subjects") or []))]
for i in hits:
    subs=", ".join("{}/{}".format(s.get("namespace","-"), s.get("name","-"))
                   for s in (i.get("subjects") or []))
    print("   {:<60} -> {:<45} [{}]".format(i["metadata"]["name"], i["roleRef"]["name"], subs))
if not hits: print("   (none found — check the instance namespace)")
' 2>/dev/null || "${OC[@]}" get clusterrolebinding -o wide | grep -i argocd

SAFE_CLUSTER="${CLUSTER//[^A-Za-z0-9._-]/_}"
ROLLBACK_FILE="$ROLLBACK_DIR/${SAFE_CLUSTER}-argocd-rbac.yaml"
"${OC[@]}" get clusterrolebinding,clusterrole -l 'app.kubernetes.io/part-of=argocd' -o yaml \
  > "$ROLLBACK_FILE" 2>/dev/null || true

# The label filter is a guess about this operator version. If it matched nothing
# the file is `items: []` and you have NO rollback for the remote identities —
# say so loudly rather than printing a reassuring "captured".
CAPTURED="$(python3 - "$ROLLBACK_FILE" <<'PYEOF' 2>/dev/null || echo 0
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print(0); raise SystemExit
print(len(d.get("items") or []))
PYEOF
)"
if [[ "${CAPTURED:-0}" -gt 0 ]]; then
  note "rollback copy -> $ROLLBACK_FILE  (${CAPTURED} objects)"
else
  printf '   \033[31m!! ROLLBACK CAPTURE IS EMPTY\033[0m — the label selector\n'
  printf '      app.kubernetes.io/part-of=argocd matched nothing on this cluster.\n'
  printf '      Capture by name from the b. listing above BEFORE applying anything:\n'
  printf '        oc get clusterrole,clusterrolebinding <names> -o yaml > %s\n' "$ROLLBACK_FILE"
fi

hdr "b2. ArgoCD instances on this cluster (SA names derive from these)"
"${OC[@]}" get argocd -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null

# ------------------------------------------------------- c. cluster registration
hdr "b3. PRE-FLIP BASELINE for the appset controller"
note "verify.sh compares against this. A cluster-scoped 'no' is normal when the"
note "appset controller's grants are namespace-scoped (apps live in gitops-<group>);"
note "what matters is that the answer is UNCHANGED after the flip."
for inst in $("${OC[@]}" get argocd -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null); do
  ns="${inst%%/*}"; name="${inst##*/}"
  asc="system:serviceaccount:${ns}:${name}-argocd-applicationset-controller"
  ans="$("${OC[@]}" auth can-i create applications.argoproj.io --as="$asc" -A 2>/dev/null || true)"
  [[ "$ans" != "yes" ]] && ans="no"
  printf '   %-70s %s\n' "$asc" "$ans"
done

hdr "c. How destination clusters are registered (decides where 2b lands)"
"${OC[@]}" get secret -A -l argocd.argoproj.io/secret-type=cluster \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null

note ""
note "Decode one cluster secret's bearer token to find the remote SA:"
note "  oc get secret -n <ns> <secret> -o jsonpath='{.data.config}' | base64 -d \\"
note "    | jq -r .bearerToken | cut -d. -f2 | base64 -d 2>/dev/null | jq ."
note "then ON THE DESTINATION cluster find what that SA is bound to:"
note "  oc get clusterrolebinding -o json | jq -r '.items[]"
note "    | select(.subjects[]?.name==\"<sa>\") | .metadata.name+\" -> \"+.roleRef.name'"

hdr "c2. ACM declarative path present?"
for kind in clusterpermission managedserviceaccount gitopscluster; do
  n="$("${OC[@]}" get "$kind" -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  printf '   %-24s %s\n' "$kind" "${n:-0}"
done
note ""
note "non-zero clusterpermission/managedserviceaccount => ACM path: put the"
note "  guard rules in the ClusterPermission CR's clusterRole.rules on the hub."
note "all zero => classic path: replace argocd-manager-role on each destination."

printf '\n\033[1mdone — nothing was modified.\033[0m\n'
