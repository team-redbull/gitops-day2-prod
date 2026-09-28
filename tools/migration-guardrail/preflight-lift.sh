#!/usr/bin/env bash
# PRE-LIFT SAFETY SWEEP — run on every cluster BEFORE removing the guard rail.
# The guard rail DEFERS deletions; it does not cancel them. Anything Argo still
# wants to delete executes within seconds of the lift. This finds those.
set -uo pipefail
NS_FILTER="${1:-}"          # optional: restrict to one Argo namespace
hazards=0

echo "=== HAZARD 1: Applications stuck in Deleting (cascade will COMPLETE on lift) ==="
out=$(oc get applications.argoproj.io -A -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i in d["items"]:
    m=i["metadata"]
    if m.get("deletionTimestamp"):
        print("  !! %s/%s  deletionTimestamp=%s finalizers=%s" % (
            m["namespace"], m["name"], m["deletionTimestamp"], m.get("finalizers")))')
if [ -n "$out" ]; then echo "$out"; hazards=$((hazards+1)); else echo "  none"; fi

echo
echo "=== HAZARD 2: OutOfSync apps with automated prune (pending prune fires on lift) ==="
out=$(oc get applications.argoproj.io -A -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i in d["items"]:
    m=i["metadata"]; s=i.get("status",{}); sp=i.get("spec",{})
    auto=(sp.get("syncPolicy") or {}).get("automated") or {}
    if not auto.get("prune"): continue
    if (s.get("sync") or {}).get("status") == "OutOfSync":
        print("  !! %s/%s  OutOfSync + prune:true" % (m["namespace"], m["name"]))')
if [ -n "$out" ]; then echo "$out"; hazards=$((hazards+1)); else echo "  none"; fi

echo
echo "=== HAZARD 3: failed sync operations whose error is a denied delete ==="
out=$(oc get applications.argoproj.io -A -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i in d["items"]:
    m=i["metadata"]; st=(i.get("status") or {}).get("operationState") or {}
    msg=st.get("message") or ""
    if "cannot delete resource" in msg or "forbidden" in msg and "delete" in msg:
        print("  !! %s/%s  %s" % (m["namespace"], m["name"], msg[:150]))')
if [ -n "$out" ]; then echo "$out"; hazards=$((hazards+1)); else echo "  none"; fi

echo
if [ $hazards -eq 0 ]; then
  echo "SAFE TO LIFT — no pending deletions found."
else
  echo "DO NOT LIFT — $hazards hazard class(es) present. Resolve first:"
  echo "  H1: oc patch application <n> -n <ns> --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
  echo "      (removes the App CR, orphans resources in place — the safe outcome)"
  echo "  H2/H3: make git match live state, or set syncPolicy.automated.prune=false,"
  echo "      and confirm the app reports Synced BEFORE lifting."
  exit 1
fi
