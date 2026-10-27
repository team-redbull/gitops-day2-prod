#!/bin/bash
# kv-vmedia-parallel-test.sh — enroll every host of one BMH chart into the
# InfraEnv on the MCE hub at once, and record on both clusters when each host
# got its ISO URL, when its InsertMedia reached kubevirt-redfish, and when its
# copy-iso pod was created, started and finished. The report says where the
# hosts got serialized: before kubevirt-redfish (BMO / Ironic / InfraEnv),
# inside it, or after it (scheduling, image pull, storage).
#
# Usage:
#   ./kv-vmedia-parallel-test.sh [-f <values-file>] preflight
#   ./kv-vmedia-parallel-test.sh [-f <values-file>] [-y] run
#   ./kv-vmedia-parallel-test.sh analyze <results-dir>
#     preflight  render the chart and check the VMs and the hub; changes nothing
#     run        preflight, then one `helm install` of the chart, watch both
#                clusters until every host has an Agent (or MAX_WAIT), analyze
#     analyze    rebuild report.txt from the raw data of an earlier run
#     -f  values file (default: kv-vmedia-parallel-test.values.sh next to this script)
#     -y  do not ask before the helm install
#
# Assumes: the VMs already exist in VM_NS, powered off, with the MACs the chart
# puts on the BMHs; the chart creates the BMHs, NMStateConfigs and BMC Secrets
# without any values. The BMH's Redfish system ID is <vm> or <VM_NS>.<vm>.
# Needs on this host: oc, helm, jq (1.6+), GNU coreutils/sed/awk, pgrep, column.
#
# Nothing secret is written to the results: image URLs (they carry the image
# service token) are stored as a 12-char sha256 prefix, logs pass through a
# URL and password redaction, and the BMC Secret is never read back.
#
# Results: $RESULTS_DIR/kv-vmedia-<UTC time>/report.txt, timeline.tsv, raw/*.jsonl
# (watch events), redfish.log, logs/ (hub logs since the start of the run).
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
VALUES=$SELF_DIR/kv-vmedia-parallel-test.values.sh
ASSUME_YES=0

usage(){ sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

#############################################################################
# jq programs. Kept in variables so the bash code around them stays readable.

# Reduces one watch event ({"type":..., "object":...}) to the fields the
# analysis needs. Output: "<url>\t<json with urlh placeholder>", hash_urls
# replaces the URL with its hash before anything is written.
read -r -d '' REDUCE_JQ <<'EOF'
def red: gsub("https?://[^ \"]+"; "<url>");
def cond($t): (.status.conditions // []) | map(select(.type == $t)) | .[0] // {};
def f_bmh: {
  name: .metadata.name, created: .metadata.creationTimestamp, del: .metadata.deletionTimestamp,
  state: .status.provisioning.state, op: .status.operationalStatus, on: .status.poweredOn,
  online: .spec.online, err: (.status.errorType // ""), errmsg: ((.status.errorMessage // "") | red | .[0:300]),
  ph: {reg: .status.operationHistory.register.start, prov: .status.operationHistory.provision.start,
       prov_end: .status.operationHistory.provision.end},
  detached: ((.metadata.annotations // {}) | has("baremetalhost.metal3.io/detached")),
  url: (.spec.image.url // "")
};
def f_ppi: {
  name: .metadata.name, created: .metadata.creationTimestamp,
  ready: (cond("Ready") | .status), reason: (cond("Ready") | .reason), url: (.status.imageUrl // "")
};
def f_infra: {
  name: .metadata.name, createdTime: .status.createdTime,
  img: (cond("ImageCreated") | {status, reason, lt: .lastTransitionTime, msg: ((.message // "") | red | .[0:200])}),
  url: (.status.isoDownloadURL // "")
};
def f_agent: {
  name: .metadata.name, created: .metadata.creationTimestamp,
  bmh: ((.metadata.labels // {})["agent-install.openshift.io/bmh"] // ""),
  approved: .spec.approved, state: (.status.debugInfo.state // ""), stage: (.status.progress.currentStage // ""),
  url: ""
};
def f_nms: {
  name: .metadata.name, created: .metadata.creationTimestamp,
  rel: ((.metadata.annotations // {})["meta.helm.sh/release-name"] // ""),
  macs: [.spec.interfaces[]?.macAddress // empty | ascii_downcase], url: ""
};
def f_pod: (.status.containerStatuses // [] | .[0] // {}) as $c | {
  name: .metadata.name, created: .metadata.creationTimestamp, del: .metadata.deletionTimestamp,
  vm: ((.metadata.labels // {})["vm.redfish"]), phase: .status.phase, node: .spec.nodeName,
  started: ($c.state.running.startedAt // $c.state.terminated.startedAt),
  finished: $c.state.terminated.finishedAt, exit: $c.state.terminated.exitCode,
  waiting: $c.state.waiting.reason,
  pvc: ([.spec.volumes[]? | .persistentVolumeClaim.claimName // empty] | .[0]), url: ""
};
def f_pvc: {
  name: .metadata.name, created: .metadata.creationTimestamp, del: .metadata.deletionTimestamp,
  phase: .status.phase, sc: .spec.storageClassName, url: ""
};
def f_vm: {
  name: .metadata.name, rs: .spec.runStrategy, status: .status.printableStatus,
  importing: ((.metadata.labels // {}) | to_entries | map(select(.key | startswith("importing.redfish/")) | .value) | join(",")),
  pai: ((.metadata.labels // {})["power-after-import.redfish"] // ""),
  failed: ((.metadata.annotations // {}) | to_entries | map(select(.key | startswith("import-failed.redfish/"))) | length > 0),
  cdrom: ([.spec.template.spec.volumes[]? | select(.name == "cdrom0") | .persistentVolumeClaim.claimName // "?"] | .[0] // ""),
  url: ((.metadata.annotations // {})["virtual-media.redfish/cdrom0"] // "")
};
def f_vmi: {
  name: .metadata.name, created: .metadata.creationTimestamp, del: .metadata.deletionTimestamp,
  phase: .status.phase, node: .status.nodeName,
  running: ((.status.phaseTransitionTimestamps // []) | map(select(.phase == "Running")) | .[0].phaseTransitionTimestamp),
  url: ""
};
def f_event: {
  name: .metadata.name, kind: .involvedObject.kind, obj: .involvedObject.name,
  reason: .reason, type: .type, count: .count,
  first: (.firstTimestamp // .eventTime), last: (.lastTimestamp // .series.lastObservedTime // .eventTime),
  msg: ((.message // "") | red | .[0:300]), url: ""
};
. as $e | $e.object as $o
| ($o | if $k == "bmh" then f_bmh elif $k == "ppi" then f_ppi elif $k == "infra" then f_infra
        elif $k == "agent" then f_agent elif $k == "nms" then f_nms elif $k == "pod" then f_pod
        elif $k == "pvc" then f_pvc elif $k == "vm" then f_vm elif $k == "vmi" then f_vmi
        elif $k == "event" then f_event else error("unknown kind " + $k) end) as $r
| (($r.url // "") | tostring) + "\u001f"
  + (({t: now, ev: ($e.type // "SNAP")} + ($r | del(.url)) + {urlh: "__URLH__"}) | tojson)
EOF

# Builds one record per host from all watch events and the redfish log, then
# either the timeline table ($mode == "table") or the summary text.
read -r -d '' ANALYZE_JQ <<'EOF'
def ts: if . == null or . == "" then null
  else ((sub("\\.[0-9]+"; "") | fromdateiso8601)
        + ((capture("\\.(?<f>[0-9]+)") | .f | ("0." + .) | tonumber) // 0)) end;
def nn: map(select(. != null));
def mn: nn | if length == 0 then null else min end;
def mx: nn | if length == 0 then null else max end;
def med: nn | sort | if length == 0 then null else .[length / 2 | floor] end;
def r1: if . == null then null else ((. * 10 + 0.5) | floor) / 10 end;
def rel: if . == null then "-" else ((. - $t0) | r1 | tostring) end;
def secs: if . == null then "-" else ((r1 | tostring) + " s") end;
def spanof(f): (map(f) | mx) as $a | (map(f) | mn) as $b | if $a == null then null else $a - $b end;
def lag(a; b): map(if (a) != null and (b) != null then (a) - (b) else null end);
def overlap($tend): [ .[] | select(.[0] != null) | ([.[0], 1], [(.[1] // $tend), -1]) ]
  | sort_by(.[0], .[1]) | reduce .[] as $e ({c: 0, m: 0}; .c += $e[1] | .m = ([.m, .c] | max)) | .m;
def runs: reduce .[] as $s ([]; if length > 0 and .[-1] == $s then . else . + [$s] end);

(($tend_arg | tonumber) as $te | if $te > 0 then $te else (([$bmh[], $pod[], $vmi[]] | map(.t) | mx) // now) end) as $tend
| ($rf | map(. + {tt: (.ts | ts)})) as $rfe
| [ $hosts[0][] | . as $h
    | ($bmh | map(select(.name == $h.bmh))) as $B
    | ($rfe | map(select(.vm == $h.vm))) as $R
    | ($pod | map(select(.vm == $h.vm)) | group_by(.name) | map(sort_by(.t) as $p | {
          name: $p[0].name,
          created: ($p | map(.created | ts) | mn),
          started: ($p | map(.started | ts) | mn),
          finished: ($p | map(.finished | ts) | mn),
          deleted: ($p | map(select(.ev == "DELETED") | .t) | mn),
          phase: ($p | map(.phase) | nn | last),
          waiting: ($p | map(.waiting) | nn | unique),
          node: ($p | map(.node) | nn | first)
        }) | sort_by(.created)) as $P
    | {
        bmh: $h.bmh, vm: $h.vm,
        bmh_created: ($B | map(.created | ts) | mn),
        nms_created: ($nms | map(select(any(.macs[]?; . == $h.mac))) | map(.created | ts) | mn),
        img_on_bmh: ($B | map(select(.urlh != null and .urlh != "-") | .t) | mn),
        bmh_urls: ($B | map(.urlh) | nn | map(select(. != "-")) | unique | length),
        delayed: ($B | any(.[]; .op == "delayed")),
        prov_start: ([($B | map(.ph.prov | ts) | mn), ($B | map(select(.state == "provisioning") | .t) | mn)] | mn),
        provisioned: ([($B | map(.ph.prov_end | ts) | mn), ($B | map(select(.state == "provisioned") | .t) | mn)] | mn),
        states: ($B | sort_by(.t) | map(.state // "-") | runs | join(">")),
        err: ($B | sort_by(.t) | map(.errmsg) | nn | map(select(. != "")) | last // ""),
        ppi_ready: ($ppi | map(select(.name == $h.bmh and .ready == "True") | .t) | mn),
        rf_post: ($R | map(select(.k == "POST") | .tt) | mn),
        gets: ($R | map(select(.k == "GET")) | length),
        rf_insert: ($R | map(select(.k == "MARK") | .tt) | mn),
        inserts: ($R | map(select(.k == "MARK")) | length),
        rf_job: ($R | map(select(.k == "JOB") | .tt) | mn),
        rf_pod: ($R | map(select(.k == "POD") | .tt) | mn),
        rf_defer: ($R | map(select(.k == "DEFER") | .tt) | mn),
        rf_on: ($R | map(select(.k == "ON" or .k == "RUNDEF") | .tt) | mn),
        ejects: ($R | map(select(.k == "EJECT")) | length),
        rf_errors: ($R | map(select(.k == "ERROR")) | length),
        pods: ($P | length),
        pod_created: ($P | map(.created) | mn),
        pod_started: ($P | map(.started) | mn),
        pod_finished: ($P | map(.finished) | mn),
        pod_result: (if ($P | length) == 0 then "-"
                     else ($P[0] | (.phase // "?") + (if .deleted != null and .finished == null then "/deleted" else "" end)) end),
        waiting: ($P | map(.waiting[]) | unique | join(",")),
        vmi_running: ([($vmi | map(select(.name == $h.vm) | .running | ts) | mn),
                       ($vmi | map(select(.name == $h.vm and .phase == "Running") | .t) | mn)] | mn),
        agent: ($agent | map(select(.bmh == $h.bmh) | .created | ts) | mn),
        _pods: $P
      }
  ] as $H
| {
    hosts: ($H | length),
    with_insert: ($H | map(select(.rf_insert != null)) | length),
    with_pod: ($H | map(select(.pod_created != null)) | length),
    with_agent: ($H | map(select(.agent != null)) | length),
    span_bmh: ($H | spanof(.bmh_created)),
    span_img: ($H | spanof(.img_on_bmh)),
    span_prov: ($H | spanof(.prov_start)),
    span_insert: ($H | spanof(.rf_insert)),
    span_pod: ($H | spanof(.pod_created)),
    span_start: ($H | spanof(.pod_started)),
    lag_pod: ($H | lag(.pod_created; .rf_insert)),
    lag_start: ($H | lag(.pod_started; .pod_created)),
    download: ($H | lag(.pod_finished; .pod_started)),
    lag_on: ($H | lag(.rf_on; .pod_finished)),
    max_pods: ([$H[]._pods[] | [.created, (.finished // .deleted)]] | overlap($tend)),
    max_running: ([$H[]._pods[] | select(.started != null) | [.started, (.finished // .deleted)]] | overlap($tend)),
    max_prov: ([$H[] | [.prov_start, .provisioned]] | overlap($tend)),
    delayed: ($H | map(select(.delayed) | .bmh)),
    multi_insert: ($H | map(select(.inserts > 1) | "\(.vm)=\(.inserts)")),
    multi_pod: ($H | map(select(.pods > 1) | "\(.vm)=\(.pods)")),
    ejects: ($H | map(select(.ejects > 0) | "\(.vm)=\(.ejects)")),
    failed_pods: ([$H[]._pods[] | select(.phase == "Failed")] | length),
    deleted_early: ([$H[]._pods[] | select(.deleted != null and .finished == null)] | length),
    waiting: ([$H[]._pods[].waiting[]] | group_by(.) | map("\(.[0])=\(length)")),
    iso_urls: ($infra | map(select(.name == $infraenv and .urlh != null and .urlh != "-"))
               | group_by(.urlh) | map({h: .[0].urlh, first: (map(.t) | mn)}) | sort_by(.first)),
    iso_created: ($infra | map(select(.name == $infraenv) | .createdTime | ts) | nn | unique | map(select(. >= $t0 - 5))),
    bmh_errors: ($H | map(select(.err != "") | "\(.bmh): \(.err)")),
    warnings: ($ev | map(select(.type == "Warning")) | group_by(.reason)
               | map({reason: .[0].reason, objects: (map(.obj) | unique | length), msg: (sort_by(.t) | last | .msg)}))
  } as $A
| if $mode == "table" then
    (["HOST", "VM", "BMH", "NMSTATE", "ISO_URL", "PROV", "POST", "INSERT", "JOB", "POD", "POD_RUN", "POD_DONE",
      "RESULT", "DEFER", "ON", "VMI_RUN", "AGENT", "INS", "EJ", "BMH_STATES"] | @tsv),
    ($H | sort_by(.rf_insert // 1e12, .pod_created // 1e12)[]
        | [.bmh, .vm, (.bmh_created | rel), (.nms_created | rel), (.img_on_bmh | rel), (.prov_start | rel),
           (.rf_post | rel), (.rf_insert | rel), (.rf_job | rel), (.pod_created | rel), (.pod_started | rel),
           (.pod_finished | rel), .pod_result, (.rf_defer | rel), (.rf_on | rel), (.vmi_running | rel),
           (.agent | rel), (.inserts | tostring), (.ejects | tostring), .states] | @tsv)
  else
    "hosts in chart:                 \($A.hosts)",
    "InsertMedia seen (hosts):       \($A.with_insert)",
    "copy-iso pod seen (hosts):      \($A.with_pod)",
    "Agent registered (hosts):       \($A.with_agent)",
    "",
    "spread first..last host (how serialized each stage is):",
    "  BMH created                   \($A.span_bmh | secs)",
    "  ISO URL set on BMH            \($A.span_img | secs)",
    "  BMO provisioning started      \($A.span_prov | secs)",
    "  InsertMedia reached redfish   \($A.span_insert | secs)",
    "  copy-iso pod created          \($A.span_pod | secs)",
    "  copy-iso container started    \($A.span_start | secs)",
    "per host (median / max):",
    "  InsertMedia -> pod created    \($A.lag_pod | med | secs) / \($A.lag_pod | mx | secs)",
    "  pod created -> running        \($A.lag_start | med | secs) / \($A.lag_start | mx | secs)",
    "  download (running -> done)    \($A.download | med | secs) / \($A.download | mx | secs)",
    "  pod done -> VM started        \($A.lag_on | med | secs) / \($A.lag_on | mx | secs)",
    "at the same time (max):",
    "  copy-iso pods existing        \($A.max_pods)",
    "  copy-iso pods running         \($A.max_running)",
    "  BMHs in provisioning          \($A.max_prov)",
    "",
    "InfraEnv \($infraenv): \($A.iso_urls | length) distinct ISO URLs seen, \($A.iso_created | length) image creations during the run"
      + (if ($A.iso_created | length) > 0 then " at +" + ($A.iso_created | map(rel) | join(", +")) + " s" else "" end),
    "BMHs delayed by BMO:            \(if ($A.delayed | length) == 0 then "none" else ($A.delayed | join(" ")) end)",
    "hosts with >1 InsertMedia:      \(if ($A.multi_insert | length) == 0 then "none" else ($A.multi_insert | join(" ")) end)",
    "hosts with >1 copy-iso pod:     \(if ($A.multi_pod | length) == 0 then "none" else ($A.multi_pod | join(" ")) end)",
    "hosts with ejects:              \(if ($A.ejects | length) == 0 then "none" else ($A.ejects | join(" ")) end)",
    "copy-iso pods failed:           \($A.failed_pods)   deleted before finishing: \($A.deleted_early)",
    "pod waiting reasons seen:       \(if ($A.waiting | length) == 0 then "none" else ($A.waiting | join(" ")) end)",
    "",
    "=== VERDICT (mechanical; read with the timeline) ===",
    ( [ (if $A.with_insert == 0 then
           "No InsertMedia reached kubevirt-redfish. Look at the BMH states and errors below and at logs/mce-*ironic*."
         else empty end),
        (if $A.with_insert > 0 and $A.with_insert < $A.hosts then
           "\($A.hosts - $A.with_insert) of \($A.hosts) hosts never sent InsertMedia during the run."
         else empty end),
        (if ($A.span_insert // 0) > 60 and (($A.lag_pod | mx) // 0) < 15 then
           "SERIALIZED BEFORE kubevirt-redfish: InsertMedia arrived spread over \($A.span_insert | secs), and kubevirt-redfish created each copy-iso pod within \($A.lag_pod | mx | secs) of its request. The pacing is upstream (BMO / Ironic / InfraEnv)."
         else empty end),
        (if ($A.span_insert // 0) > 60 and ($A.span_img // 0) > (($A.span_insert // 0) * 0.5) then
           "  The ISO URL itself reached the BMHs spread over \($A.span_img | secs): the hosts waited for the InfraEnv image (\($A.iso_created | length) image creations during the run)."
         else empty end),
        (if ($A.span_insert // 0) > 60 and ($A.delayed | length) > 0 then
           "  BMO marked \($A.delayed | length) hosts as delayed: the BMO provisioning limit throttled them (see PROVISIONING_LIMIT in config-before.txt)."
         else empty end),
        (if ($A.span_insert // 0) > 60 and ($A.span_prov // 0) > (($A.span_insert // 0) * 0.5) then
           "  BMO started provisioning spread over \($A.span_prov | secs), at most \($A.max_prov) hosts in provisioning at once."
         else empty end),
        (if (($A.lag_pod | mx) // 0) >= 15 then
           "SLOW INSIDE kubevirt-redfish: some copy-iso pods were created up to \($A.lag_pod | mx | secs) after their InsertMedia. Send redfish.log."
         else empty end),
        (if (($A.lag_start | mx) // 0) > 60 then
           "PODS STARTED LATE: up to \($A.lag_start | mx | secs) between pod creation and container start (scheduling, PVC attach or image pull). Waiting reasons: \($A.waiting | join(" ")). See the Warning events below."
         else empty end),
        (if $A.with_pod > 1 and $A.max_running <= 1 then
           "Only one copy-iso pod was running at any moment."
         else empty end),
        (if ($A.multi_insert | length) > 0 then
           "Some hosts got InsertMedia more than once: Ironic retried virtual media. Check the BMH errors below and the Ironic log."
         else empty end),
        (if $A.failed_pods > 0 or $A.deleted_early > 0 then
           "\($A.failed_pods) copy-iso pods failed and \($A.deleted_early) were deleted before finishing (an eject during the import deletes the pod)."
         else empty end)
      ] | if length == 0 then ["no serialization signal found: inserts and pods were close together."] else . end | .[] ),
    "",
    "=== Warning events in the VM namespace ===",
    (if ($A.warnings | length) == 0 then "none"
     else ($A.warnings[] | "  \(.reason) (\(.objects) objects): \(.msg)") end),
    "",
    "=== BMH errors (last seen per host) ===",
    (if ($A.bmh_errors | length) == 0 then "none" else ($A.bmh_errors[] | "  " + .) end)
  end
EOF

#############################################################################
# helpers

load_values(){
  [ -r "$VALUES" ] || die "values file not found: $VALUES"
  # shellcheck disable=SC1090
  source "$VALUES"
  local v
  for v in KC_ROOT MCE_CLUSTER KV_CLUSTER BMH_CHART RELEASE HELM_NS VM_NS RF_NS RF_DEPLOY \
           BMO_NS ASSISTED_NS RESULTS_DIR POLL MAX_WAIT POST_WAIT; do
    [[ -n ${!v:-} && ${!v} != CHANGE-ME ]] || die "set $v in $VALUES"
  done
  KC_MCE=$KC_ROOT/$MCE_CLUSTER/auth/kubeconfig
  KC_KV=$KC_ROOT/$KV_CLUSTER/auth/kubeconfig
  local kc; for kc in "$KC_MCE" "$KC_KV"; do
    [ -r "$kc" ] || die "kubeconfig not found: $kc — check the cluster names in $VALUES"
  done
  local t; for t in oc helm jq sha256sum pgrep column awk sed; do
    command -v "$t" >/dev/null || die "$t not found on this host"
  done
  date -d "2000-01-01T00:00:00Z" +%s >/dev/null 2>&1 || die "GNU date is required"
}

mce(){ oc --kubeconfig="$KC_MCE" "$@"; }
kv(){ oc --kubeconfig="$KC_KV" "$@"; }

redact(){ # stdin -> stdout, line buffered
  sed -u -E \
    -e 's#(https?://[^ "?]*)\?[^ "]*#\1?<redacted>#g' \
    -e 's#/(byapikey|bytoken)/[^/ "]+#/\1/<redacted>#g' \
    -e 's#([Pp]assword"?[[:space:]]*[:=][[:space:]]*"?)[^", }]+#\1<redacted>#g'
}

hash_urls(){ # "<url>\x1f<json>" lines -> json lines with the URL replaced by its hash
  local url json h
  while IFS=$'\x1f' read -r url json; do
    h=-
    [ -n "$url" ] && h=$(printf %s "$url" | sha256sum | cut -c1-12)
    printf '%s\n' "${json/__URLH__/$h}"
  done
}

reduce_stream(){ # kind — watch events (or {"type":"SNAP","object":..}) on stdin -> JSONL
  jq --unbuffered -r --arg k "$1" "$REDUCE_JQ" | hash_urls
}

kill_tree(){ # parent first, so a shell does not report its killed children
  local kids c; kids=$(pgrep -P "$1" 2>/dev/null); kill "$1" 2>/dev/null
  for c in $kids; do kill_tree "$c"; done
}

# kind  cluster(mce|kv)  namespace  resource  [label-selector]
watcher(){
  local kind=$1 cl=$2 ns=$3 res=$4 sel=${5:-} kc
  [ "$cl" = mce ] && kc=$KC_MCE || kc=$KC_KV
  local args=(get "$res" -n "$ns" -w --output-watch-events -o json)
  [ -n "$sel" ] && args+=(-l "$sel")
  # The API server ends a watch after a while; restart it. The restart lists
  # every object again, which the analysis tolerates (it takes min/max times).
  while [ ! -e "$RES/.stop" ]; do
    oc --kubeconfig="$kc" "${args[@]}" 2>>"$RES/watch-errors.log" | reduce_stream "$kind" >> "$RES/raw/$kind.jsonl"
    [ -e "$RES/.stop" ] || sleep 2
  done
}

snapshot(){ # kind cluster namespace resource [selector] — final state of every object
  local kind=$1 cl=$2 ns=$3 res=$4 sel=${5:-}
  local args=(get "$res" -n "$ns" -o json); [ -n "$sel" ] && args+=(-l "$sel")
  "$cl" "${args[@]}" 2>>"$RES/watch-errors.log" | jq -c '.items[] | {type: "SNAP", object: .}' \
    | reduce_stream "$kind" >> "$RES/raw/$kind.jsonl"
}

#############################################################################
# preflight: render the chart, map BMHs to VMs, check both clusters

render_chart(){ # -> $RES/hosts.tsv, hosts.json, rendered-objects.txt, BMH_NS, INFRAENV
  local tmp; tmp=$(mktemp -d)
  if ! helm template "$RELEASE" "$BMH_CHART" -n "$HELM_NS" ${HELM_ARGS[@]+"${HELM_ARGS[@]}"} > "$tmp/r.yaml" 2> "$tmp/err"; then
    sed 's/^/  /' "$tmp/err"; rm -rf "$tmp"; return 1
  fi
  # The client dry run turns the YAML into JSON; it needs the hub only for the
  # BMH/NMStateConfig CRDs. The rendered BMC Secret stays in $tmp and is deleted.
  if ! mce create --dry-run=client -o json -f "$tmp/r.yaml" 2> "$tmp/err" \
       | jq -c 'if .kind == "List" then .items[] else . end' > "$tmp/r.jsonl"; then
    sed 's/^/  /' "$tmp/err"; rm -rf "$tmp"; return 1
  fi
  jq -r --arg ns "$HELM_NS" '"\(.kind) \(.metadata.namespace // $ns)/\(.metadata.name)"' "$tmp/r.jsonl" > "$RES/rendered-objects.txt"
  jq -c --arg ns "$HELM_NS" --arg pfx "$VM_NS." 'select(.kind == "BareMetalHost")
      | (.spec.bmc.address // "" | split("/") | last) as $sys
      | {bmh: .metadata.name, bmh_ns: (.metadata.namespace // $ns), mac: ((.spec.bootMACAddress // "") | ascii_downcase),
         sys: $sys, vm: (if ($sys | startswith($pfx)) then $sys[($pfx | length):] else $sys end),
         bmc_host: (.spec.bmc.address // "" | sub("^[^/]*//"; "") | split("/")[0]),
         infraenv: ((.metadata.labels // {})["infraenvs.agent-install.openshift.io"] // "")}' \
      "$tmp/r.jsonl" | jq -s 'sort_by(.bmh)' > "$RES/hosts.json"
  jq -s -c '[.[] | select(.kind == "NMStateConfig") | [.spec.interfaces[]?.macAddress // empty | ascii_downcase]] | add // []' \
      "$tmp/r.jsonl" > "$RES/nms-macs.json"
  rm -rf "$tmp"
  jq -r '.[] | [.bmh, .vm, .mac, .sys] | @tsv' "$RES/hosts.json" > "$RES/hosts.tsv"
  NHOSTS=$(jq length "$RES/hosts.json")
  BMH_NS=$(jq -r '[.[].bmh_ns] | unique | join(",")' "$RES/hosts.json")
  INFRAENV=$(jq -r '[.[].infraenv] | unique | join(",")' "$RES/hosts.json")
  NAMES_JSON=$(jq -c '[.[].bmh]' "$RES/hosts.json")
}

preflight(){ # returns 1 on any blocking problem; output also in $RES/preflight.txt
  local rc
  preflight_body > >(tee "$RES/preflight.txt") 2>&1; rc=$?
  wait $! 2>/dev/null
  return $rc
}

preflight_body(){
  local bad=0
  log "preflight — MCE=$MCE_CLUSTER  KubeVirt=$KV_CLUSTER  chart=$BMH_CHART  release=$RELEASE (ns $HELM_NS)"
  mce whoami >/dev/null 2>&1 || { echo "!! cannot reach the MCE cluster with $KC_MCE"; return 1; }
  kv whoami >/dev/null 2>&1 || { echo "!! cannot reach the KubeVirt cluster with $KC_KV"; return 1; }
  [ -d "$BMH_CHART" ] || { echo "!! chart directory not found: $BMH_CHART"; return 1; }
  render_chart || { echo "!! helm template / dry run of the chart failed (output above)"; return 1; }

  echo "chart renders $(wc -l < "$RES/rendered-objects.txt") objects:"
  awk '{print $1}' "$RES/rendered-objects.txt" | sort | uniq -c | sed 's/^/  /'
  (( NHOSTS > 0 )) || { echo "!! the chart renders no BareMetalHost"; return 1; }
  [[ $BMH_NS != *,* ]] || { echo "!! BMHs in several namespaces ($BMH_NS); the script expects one"; bad=1; }
  [[ -n $INFRAENV && $INFRAENV != *,* ]] || { echo "!! BMHs carry no single infraenvs.agent-install.openshift.io label ('$INFRAENV')"; bad=1; }
  echo "BMH namespace: $BMH_NS   InfraEnv: $INFRAENV   hosts: $NHOSTS"

  # Hub: a fresh install only. Re-applying an existing BMH strips what BMAC
  # wrote on it and makes BMO deprovision the host, so never adopt one.
  if helm --kubeconfig="$KC_MCE" status "$RELEASE" -n "$HELM_NS" >/dev/null 2>&1; then
    echo "!! helm release $RELEASE already exists in $HELM_NS — uninstall it (and let the hosts deprovision) before a new run"; bad=1
  fi
  local existing
  existing=$(mce get bmh -n "$BMH_NS" -o json 2>/dev/null | jq -r --argjson n "$NAMES_JSON" '.items[].metadata.name | select(. as $x | any($n[]; . == $x))')
  [ -z "$existing" ] || { echo "!! these BMHs already exist in $BMH_NS: $(echo $existing)"; bad=1; }
  mce get infraenv "$INFRAENV" -n "$BMH_NS" >/dev/null 2>&1 || { echo "!! InfraEnv $INFRAENV not found in $BMH_NS"; bad=1; }
  local nomac
  nomac=$(jq -r --slurpfile m "$RES/nms-macs.json" '.[] | select(.mac as $x | any($m[0][]; . == $x) | not) | .bmh' "$RES/hosts.json")
  [ -z "$nomac" ] || echo "warning: no rendered NMStateConfig carries the MAC of: $(echo $nomac)"

  # KubeVirt: kubevirt-redfish up, every VM present, stopped, MAC matching, clean.
  local rf
  rf=$(kv get deploy "$RF_DEPLOY" -n "$RF_NS" -o json 2>/dev/null) || { echo "!! deployment $RF_DEPLOY not found in $RF_NS"; return 1; }
  [ "$(jq '.status.readyReplicas // 0' <<<"$rf")" -ge 1 ] || { echo "!! $RF_DEPLOY has no ready replica"; bad=1; }
  [ "$(jq '.spec.replicas // 1' <<<"$rf")" -le 1 ] || echo "warning: $RF_DEPLOY runs more than one replica (unsupported)"
  local routes; routes=$(kv get route -n "$RF_NS" -o jsonpath='{.items[*].spec.host}' 2>/dev/null)
  jq -r --arg r " $routes " '.[] | select(.bmc_host as $b | $r | contains(" " + $b + " ") | not) | "warning: BMC host \(.bmc_host) of \(.bmh) is not a Route in the redfish namespace"' "$RES/hosts.json" | sort -u | head -3

  local vms vmis
  vms=$(kv get vm -n "$VM_NS" -o json 2>/dev/null) || { echo "!! cannot list VMs in $VM_NS"; return 1; }
  vmis=$(kv get vmi -n "$VM_NS" -o json 2>/dev/null || echo '{"items":[]}')
  echo
  local table
  table=$(jq -r --argjson vms "$vms" --argjson vmis "$vmis" '
    ($vms.items | map({key: .metadata.name, value: .}) | from_entries) as $V
    | ($vmis.items | map(.metadata.name)) as $running
    | (["BMH", "VM", "MAC", "RUN_STRATEGY", "LEFTOVERS", "CHECK"] | @tsv),
      (.[] | . as $h | $V[$h.vm] as $vm
       | if $vm == null then [$h.bmh, $h.vm, "-", "-", "-", "FAIL: VM not found"]
         else ([$vm.spec.template.spec.domain.devices.interfaces[]?.macAddress // empty | ascii_downcase]) as $macs
         | ([($vm.metadata.labels // {} | keys[] | select(startswith("importing.redfish/") or . == "power-after-import.redfish")),
             ($vm.metadata.annotations // {} | keys[] | select(startswith("import-failed.redfish/") or startswith("virtual-media.redfish/"))),
             ($vm.spec.template.spec.volumes[]? | select(.name == "cdrom0") | "cdrom0-volume"),
             (if any($running[]; . == $h.vm) then "vmi-running" else empty end)] | join(",")) as $left
         | [$h.bmh, $h.vm,
            (if ($macs | length) == 0 then "none" elif any($macs[]; . == $h.mac) then "ok" else "MISMATCH" end),
            ($vm.spec.runStrategy // (if $vm.spec.running == true then "running=true" else "running=false" end)),
            (if $left == "" then "-" else $left end),
            (if ($macs | length) == 0 then "FAIL: no MAC in VM spec"
             elif any($macs[]; . == $h.mac) | not then "FAIL: BMH MAC \($h.mac) not on VM"
             elif $left != "" then "FAIL: clean the VM first"
             elif ($vm.spec.runStrategy // "Halted") != "Halted" then "warn: not Halted"
             else "ok" end)]
         end | @tsv)' "$RES/hosts.json")
  column -t -s $'\t' <<<"$table"
  if grep -q "FAIL" <<<"$table"; then
    echo "!! at least one VM is missing, has the wrong MAC or still carries virtual media state (table above)"; bad=1
  fi
  local left
  left=$(kv get pod,pvc -n "$VM_NS" -l vm.redfish --no-headers 2>/dev/null | wc -l)
  (( left == 0 )) || echo "warning: $left copy-iso pods/PVCs already exist in $VM_NS (from an earlier run?)"
  echo
  (( bad == 0 )) && log "preflight passed" || log "preflight FAILED — nothing was changed"
  return $bad
}

snapshot_config(){ # file — settings that decide concurrency, no secrets
  {
    echo "### $(date -u +%FT%TZ)"
    echo "## kubevirt-redfish ($KV_CLUSTER $RF_NS/$RF_DEPLOY)"
    kv get deploy "$RF_DEPLOY" -n "$RF_NS" -o json 2>/dev/null | jq -r '
      "replicas: \(.spec.replicas)  ready: \(.status.readyReplicas // 0)",
      (.spec.template.spec.containers[] | "image[\(.name)]: \(.image)",
        ((.env // [])[] | select(.name | test("PASS|TOKEN|SECRET|KEY"; "i") | not) | "env[\(.name)]=\(.value // "(from ref)")"))'
    kv get pod -n "$RF_NS" -l "$(rf_selector)" -o json 2>/dev/null | jq -r '.items[] |
      "pod \(.metadata.name) started \(.status.startTime) restarts \([.status.containerStatuses[]?.restartCount] | add) imageID \(.status.containerStatuses[0].imageID // "-")"'
    local sec; sec=$(kv get deploy "$RF_DEPLOY" -n "$RF_NS" -o jsonpath='{.spec.template.spec.volumes[?(@.secret)].secret.secretName}' 2>/dev/null | awk '{print $1}')
    if [ -n "$sec" ]; then
      echo "config.yaml in secret $sec (selected keys only):"
      kv get secret "$sec" -n "$RF_NS" -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d 2>/dev/null \
        | grep -E '^[[:space:]]*(workers|qps|burst|storage_class|storage_size|helper_image|allow_insecure_tls|iso_download_timeout|system_id_convention)[[:space:]]*:' \
        | sed 's/^[[:space:]]*/  /'
    fi
    echo "## BMO / Ironic ($MCE_CLUSTER $BMO_NS) — concurrency settings"
    local envs
    envs=$(mce get deploy -n "$BMO_NS" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | test("metal3|baremetal")) | .metadata.name as $d
      | .spec.template.spec.containers[] | .name as $c | (.env // [])[]
      | select(.name | test("LIMIT|CONCURREN|WORKER|MAX_|THREAD"))
      | "\($d)/\($c) \(.name)=\(.value // "(from ref)")"')
    [ -n "$envs" ] && echo "$envs" || echo "no PROVISIONING_LIMIT / concurrency env set on the metal3 deployments (BMO defaults apply)"
    mce get provisioning -o json 2>/dev/null | jq -r '.items[] | "provisioning \(.metadata.name): \(.spec | del(.preProvisioningOSDownloadURLs) | tojson)"'
    echo "## InfraEnv $INFRAENV"
    mce get infraenv "$INFRAENV" -n "$BMH_NS" -o json 2>/dev/null | jq -r '
      "createdTime: \(.status.createdTime // "-")",
      (.status.conditions // [] | .[] | "condition \(.type)=\(.status) \(.reason // "") \(.lastTransitionTime // "")")'
    echo "## versions"
    mce get clusterversion version -o jsonpath='hub OCP {.status.desired.version}{"\n"}' 2>/dev/null
    kv get clusterversion version -o jsonpath='kubevirt cluster OCP {.status.desired.version}{"\n"}' 2>/dev/null
    mce get csv -A -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | test("multicluster-engine|advanced-cluster")) | .metadata.name] | unique | "hub CSVs: " + join(" ")'
    kv get csv -A -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | test("kubevirt-hyperconverged")) | .metadata.name] | unique | "kubevirt CSVs: " + join(" ")'
  } >> "$1" 2>&1
}

rf_selector(){
  kv get deploy "$RF_DEPLOY" -n "$RF_NS" -o json 2>/dev/null \
    | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")'
}

#############################################################################
# run

PIDS=()
start_watchers(){
  local res kind
  watcher bmh mce "$BMH_NS" baremetalhosts.metal3.io 2>/dev/null & PIDS+=($!)
  watcher agent mce "$BMH_NS" agents.agent-install.openshift.io 2>/dev/null & PIDS+=($!)
  watcher nms mce "$BMH_NS" nmstateconfigs.agent-install.openshift.io 2>/dev/null & PIDS+=($!)
  watcher infra mce "$BMH_NS" infraenvs.agent-install.openshift.io 2>/dev/null & PIDS+=($!)
  if mce get preprovisioningimages.metal3.io -n "$BMH_NS" >/dev/null 2>&1; then
    watcher ppi mce "$BMH_NS" preprovisioningimages.metal3.io 2>/dev/null & PIDS+=($!)
  fi
  watcher pod kv "$VM_NS" pods vm.redfish 2>/dev/null & PIDS+=($!)
  watcher pvc kv "$VM_NS" persistentvolumeclaims 2>/dev/null & PIDS+=($!)
  watcher vm kv "$VM_NS" virtualmachines.kubevirt.io 2>/dev/null & PIDS+=($!)
  watcher vmi kv "$VM_NS" virtualmachineinstances.kubevirt.io 2>/dev/null & PIDS+=($!)
  watcher event kv "$VM_NS" events 2>/dev/null & PIDS+=($!)
  ( while [ ! -e "$RES/.stop" ]; do
      kv logs -f "deploy/$RF_DEPLOY" -n "$RF_NS" --since-time="$WATCH_ISO" 2>>"$RES/watch-errors.log" \
        | redact >> "$RES/raw/redfish-follow.log"
      [ -e "$RES/.stop" ] || sleep 2
    done ) 2>/dev/null & PIDS+=($!)
}

AGENTS=0
progress(){ # one status line; sets AGENTS
  local now b p a
  now=$(date +%s)
  b=$(mce get bmh -n "$BMH_NS" -o json 2>/dev/null | jq -r --argjson n "$NAMES_JSON" '
      [.items[] | select(.metadata.name as $x | any($n[]; . == $x))]
      | "BMH " + (if length == 0 then "none" else (group_by(.status.provisioning.state // "new")
          | map("\(.[0].status.provisioning.state // "new")=\(length)") | join(" ")) end)
      + "  delayed=\(map(select(.status.operationalStatus == "delayed")) | length)"')
  p=$(kv get pod -n "$VM_NS" -l vm.redfish -o json 2>/dev/null | jq -r '
      .items | "copy-iso pods=\(length)" + (if length == 0 then "" else " (" + (group_by(.status.phase)
        | map("\(.[0].status.phase)=\(length)") | join(" ")) + ")" end)')
  a=$(mce get agent -n "$BMH_NS" -o json 2>/dev/null | jq -r --argjson n "$NAMES_JSON" '
      [.items[] | (.metadata.labels // {})["agent-install.openshift.io/bmh"] // "" | select(. as $x | any($n[]; . == $x))] | unique | length')
  AGENTS=${a:-0}
  log "+$(( now - T0 ))s  ${b:-BMH ?} | ${p:-pods ?} | agents $AGENTS/$NHOSTS"
}

monitor(){
  local done_at="" now
  while :; do
    progress
    now=$(date +%s)
    if (( AGENTS >= NHOSTS )); then
      [ -n "$done_at" ] || { done_at=$now; log "every host has an Agent — recording $POST_WAIT s more"; }
      (( now - done_at >= POST_WAIT )) && return
    fi
    (( now - T0 >= MAX_WAIT )) && { log "MAX_WAIT ($MAX_WAIT s) reached — stopping"; return; }
    sleep "$POLL"
  done
}

final_fetch(){
  log "collecting final state and logs"
  local p c rc
  # kubevirt-redfish: every pod of the deployment, previous container too
  for p in $(kv get pod -n "$RF_NS" -l "$(rf_selector)" -o name 2>/dev/null); do
    kv logs -n "$RF_NS" "$p" --since-time="$WATCH_ISO" 2>>"$RES/watch-errors.log" | redact > "$RES/raw/redfish-${p##*/}.log"
    rc=$(kv get -n "$RF_NS" "$p" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
    (( ${rc:-0} > 0 )) && kv logs -n "$RF_NS" "$p" --previous 2>/dev/null | redact > "$RES/raw/redfish-${p##*/}-previous.log"
  done
  LC_ALL=C sort -u "$RES"/raw/redfish-*.log > "$RES/redfish.log" 2>/dev/null

  snapshot bmh mce "$BMH_NS" baremetalhosts.metal3.io
  snapshot agent mce "$BMH_NS" agents.agent-install.openshift.io
  snapshot nms mce "$BMH_NS" nmstateconfigs.agent-install.openshift.io
  snapshot infra mce "$BMH_NS" infraenvs.agent-install.openshift.io
  snapshot pod kv "$VM_NS" pods vm.redfish
  snapshot pvc kv "$VM_NS" persistentvolumeclaims
  snapshot vm kv "$VM_NS" virtualmachines.kubevirt.io
  snapshot vmi kv "$VM_NS" virtualmachineinstances.kubevirt.io
  snapshot event kv "$VM_NS" events

  # Hub logs since the start: Ironic and BMO in full, assisted-service only for our hosts.
  mkdir -p "$RES/logs"
  mce get pod -n "$BMO_NS" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | startswith("metal3"))
      | .metadata.name as $p | .spec.containers[] | select(.name | test("ironic|baremetal-operator")) | "\($p) \(.name)"' \
  | while read -r p c; do
      mce logs -n "$BMO_NS" "$p" -c "$c" --since-time="$WATCH_ISO" 2>/dev/null | redact | gzip > "$RES/logs/mce-$p-$c.log.gz"
    done
  jq -r '.[].bmh' "$RES/hosts.json" > "$RES/.patterns"; echo "$INFRAENV" >> "$RES/.patterns"
  for p in $(mce get pod -n "$ASSISTED_NS" -o name 2>/dev/null | grep '/assisted-service-'); do
    mce logs -n "$ASSISTED_NS" "$p" -c assisted-service --since-time="$WATCH_ISO" 2>/dev/null \
      | grep -F -f "$RES/.patterns" | redact > "$RES/logs/assisted-${p##*/}.log"
  done
  rm -f "$RES/.patterns"
}

FINISHED=""
finish(){
  [ -n "$FINISHED" ] && return; FINISHED=1
  log "stopping watchers"
  touch "$RES/.stop"
  local p; for p in "${PIDS[@]}"; do kill_tree "$p"; done
  wait 2>/dev/null
  rm -f "$RES/.stop"
  final_fetch
  echo "END=$(date +%s)" >> "$RES/meta.env"
  snapshot_config "$RES/config-after.txt"
  echo
  cmd_analyze "$RES"
  echo
  log "results in $RES"
  log "the hosts stay enrolled; removing them is a separate decision (helm uninstall $RELEASE -n $HELM_NS deprovisions them)"
}

cmd_preflight(){
  load_values
  RES=$(mktemp -d)
  preflight; local rc=$?
  rm -rf "$RES"
  return $rc
}

cmd_run(){
  load_values
  RES=$RESULTS_DIR/kv-vmedia-$(date -u +%Y%m%d-%H%M%S)
  mkdir -p "$RES/raw" || die "cannot create $RES"
  RES=$(cd "$RES" && pwd)
  preflight || die "preflight failed — nothing was installed (details in $RES/preflight.txt)"

  if (( ! ASSUME_YES )); then
    echo
    echo "About to run:  helm install $RELEASE $BMH_CHART -n $HELM_NS ${HELM_ARGS[*]:-}"
    echo "on $MCE_CLUSTER. It creates $NHOSTS BareMetalHosts in $BMH_NS; BMO/Ironic will insert"
    echo "the InfraEnv ISO into the VMs in $KV_CLUSTER/$VM_NS and power them on."
    local a=""; read -rp "type 'yes' to start: " a || die "no input"
    [ "$a" = yes ] || die "not started"
  fi

  snapshot_config "$RES/config-before.txt"
  WATCH_ISO=$(date -u +%FT%TZ)
  trap finish EXIT
  trap 'echo; log "interrupted"; exit 130' INT TERM
  start_watchers
  sleep 5   # let every watcher list its objects before anything changes

  T0=$(date +%s)
  {
    echo "T0=$T0"; echo "WATCH_ISO=$WATCH_ISO"; echo "VM_NS=$VM_NS"; echo "BMH_NS=$BMH_NS"
    echo "INFRAENV=$INFRAENV"; echo "NHOSTS=$NHOSTS"; echo "RELEASE=$RELEASE"
    echo "MCE_CLUSTER=$MCE_CLUSTER"; echo "KV_CLUSTER=$KV_CLUSTER"
  } > "$RES/meta.env"
  log "helm install $RELEASE ($NHOSTS hosts) — T0"
  if helm --kubeconfig="$KC_MCE" install "$RELEASE" "$BMH_CHART" -n "$HELM_NS" ${HELM_ARGS[@]+"${HELM_ARGS[@]}"} > "$RES/helm-install.log" 2>&1; then
    log "helm install done in $(( $(date +%s) - T0 )) s"
  else
    log "!! helm install failed — last lines of $RES/helm-install.log:"; tail -n 5 "$RES/helm-install.log" | sed 's/^/     /'
    local made
    made=$(mce get bmh -n "$BMH_NS" -o json 2>/dev/null | jq --argjson n "$NAMES_JSON" '[.items[] | select(.metadata.name as $x | any($n[]; . == $x))] | length')
    if (( ${made:-0} == 0 )); then log "no BMH was created — stopping"; return 1; fi
    log "$made BMHs exist anyway — recording"
  fi
  echo "HELM_DONE=$(date +%s)" >> "$RES/meta.env"
  monitor
}

#############################################################################
# analyze

parse_redfish_log(){ # redfish.log -> JSONL {ts, k, vm}
  awk -v ns="$VM_NS" -v pfx="$VM_NS." '
  {
    if (!match($0, /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z/)) next
    ts = substr($0, RSTART, RLENGTH)
    if (match($0, /Received [A-Z]+ request for VM [^ ]+/)) {
      n = split(substr($0, RSTART, RLENGTH), a, " ")
      vm = a[n]; if (index(vm, pfx) == 1) vm = substr(vm, length(pfx) + 1)
      print ts "\t" a[2] "\t" vm; next
    }
    k = ""
    if (index($0, "Marked import of ")) k = "MARK"
    else if (index($0, "Inserting virtual media ")) k = "JOB"
    else if (index($0, "Created helper pod ")) k = "POD"
    else if (index($0, "Set importing label ")) k = "LABEL"
    else if (index($0, " deferred for VM ")) k = "DEFER"
    else if (index($0, "Successfully started VM ")) k = "ON"
    else if (index($0, "All imports complete for VM ")) k = "RUNDEF"
    else if (index($0, "Import pod ") && index($0, " succeeded for VM ")) k = "PODOK"
    else if (index($0, "Import pod ") && index($0, " failed for VM ")) k = "PODFAIL"
    else if (index($0, "Removed importing label ")) k = "UNLBL"
    else if (index($0, "Ejecting virtual media ")) k = "EJECT"
    else if (index($0, "Withdrew deferred power command")) k = "WITHDRAW"
    else if (index($0, "ERROR")) k = "ERROR"
    if (k == "") next
    if (!match($0, /VM [a-z0-9][a-z0-9.-]*\/[a-z0-9][a-z0-9.-]*/)) next
    split(substr($0, RSTART + 3, RLENGTH - 3), a, "/")
    if (a[1] != ns) next
    vm = a[2]; sub(/[.]+$/, "", vm)
    print ts "\t" k "\t" vm
  }' "$1" | jq -R -c 'split("\t") | {ts: .[0], k: .[1], vm: .[2]}'
}

cmd_analyze(){
  local dir=${1:?results directory}
  [ -r "$dir/meta.env" ] && [ -r "$dir/hosts.json" ] || die "$dir does not look like a results directory"
  # shellcheck disable=SC1091
  source "$dir/meta.env"
  local k; for k in bmh ppi infra agent nms pod pvc vm vmi event; do touch "$dir/raw/$k.jsonl"; done
  touch "$dir/redfish.log"
  [ -s "$dir/redfish.log" ] || LC_ALL=C sort -u "$dir"/raw/redfish-*.log > "$dir/redfish.log" 2>/dev/null
  parse_redfish_log "$dir/redfish.log" > "$dir/raw/rf.jsonl"

  local args=(-n -r --argjson t0 "$T0" --arg tend_arg "${END:-0}" --arg infraenv "$INFRAENV"
              --slurpfile hosts "$dir/hosts.json" --slurpfile rf "$dir/raw/rf.jsonl")
  for k in bmh ppi infra agent nms pod vm vmi; do args+=(--slurpfile "$k" "$dir/raw/$k.jsonl"); done
  args+=(--slurpfile ev "$dir/raw/event.jsonl")

  {
    echo "kv-vmedia-parallel-test report — $NHOSTS hosts, release $RELEASE, hub $MCE_CLUSTER, KubeVirt $KV_CLUSTER"
    echo "times are seconds after the helm install (T0 = $(date -u -d "@$T0" +%FT%TZ)); - = never seen"
    echo
    echo "=== Settings at the start ==="
    sed -n '/^## /,$p' "$dir/config-before.txt" 2>/dev/null
    echo
    echo "=== Per-host timeline, sorted by InsertMedia arrival ==="
    jq "${args[@]}" --arg mode table "$ANALYZE_JQ" | tee "$dir/timeline.tsv" | column -t -s $'\t'
    echo
    echo "columns: BMH/NMSTATE created, ISO_URL first set on the BMH, PROV = BMO provisioning start,"
    echo "POST = first POST from Ironic, INSERT = InsertMedia accepted, JOB = worker picked it up,"
    echo "POD/POD_RUN/POD_DONE = copy-iso pod created/started/finished, DEFER = Power On deferred,"
    echo "ON = VM started, AGENT = Agent registered, INS/EJ = InsertMedia/eject count"
    echo
    echo "=== Summary ==="
    jq "${args[@]}" --arg mode summary "$ANALYZE_JQ"
  } > "$dir/report.txt"
  cat "$dir/report.txt"
}

#############################################################################
while getopts ":f:yh" o; do
  case $o in
    f) VALUES=$OPTARG ;;
    y) ASSUME_YES=1 ;;
    h) usage 0 ;;
    :) echo "option -$OPTARG needs a value" >&2; usage 1 ;;
    *) echo "unknown option -$OPTARG" >&2; usage 1 ;;
  esac
done
shift $((OPTIND-1))
CMD=${1:-}; shift || true

case $CMD in
  preflight) cmd_preflight ;;
  run) cmd_run ;;
  analyze) cmd_analyze "${1:-}" ;;
  _reduce) reduce_stream "${1:?kind}" ;;   # test hook: watch events on stdin -> JSONL
  *) usage 1 ;;
esac
