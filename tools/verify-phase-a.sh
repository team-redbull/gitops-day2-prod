#!/usr/bin/env bash
#
# verify-phase-a.sh — is Phase A complete, and ONLY Phase A?
#
# Phase A (CHANGES.md) adds two marker files to a sigs repo and changes nothing
# else:
#
#   mces/<mce>/mce.yaml         env: prod|prep|test, site: <site>, ocpVersion: "<v>"
#   mces/<mce>/<cluster>/hc.yaml                                   ocpVersion: "<v>"
#
# It is a HARD PRECONDITION for Phase B: at the moment Phase B merges, an MCE or
# hosted cluster whose folder has no marker loses its Application (workloads
# orphaned in place, unmanaged until the marker is added and the same-named app
# recreates and re-adopts).
#
# The authoritative set of things that need a marker is not a guess — it is what
# the CURRENT directories: generators emit today:
#
#   mcesAppset      directories: mces/*            exclude mces/in-cluster-defaults
#   clustersAppset  directories: mces/<mce>/*      exclude <mce>/in-cluster
#
# So: every folder under mces/ except in-cluster-defaults needs mce.yaml, and
# every folder under an MCE except in-cluster needs hc.yaml. This script derives
# both sets from git's index (not the shell's view of the filesystem) and checks
# coverage, placement, marker content and the git-pathspec parity rule of §0.3.
#
# Runs against the legacy mces/ layout, the sites/ layout, or a mix of the two
# (the Phase C window), so it stays valid from the first Phase A commit until
# E.3 deletes the markers again.
#
# Usage:
#   ./verify-phase-a.sh /root/projects/sigs/<team> [more repos ...]
#   ./verify-phase-a.sh --day1 /root/projects/day1/platform-config /root/projects/sigs/*
#   ./verify-phase-a.sh --base origin/main /root/projects/sigs/<team>
#
#   --day1 PATH   cross-check every MCE/cluster against day1's version files
#                 (WARN-level here; E.0.2's parity gate is the real one)
#   --base REF    assert the REF..HEAD range is additive: markers added, nothing
#                 else touched
#   --strict      warnings count as failures
#
# Exit: 0 all checks pass, 1 one or more FAILs, 2 usage/precondition error.
#
# Read-only. Never fetches, never writes to the repo.

set -uo pipefail

ENVS_ALLOWED="prod prep test"
# k8s label value: <=63 chars, alnum at both ends, [-_.] inside. env, site and
# ocpVersion all become label values in Phase B's templates.
LABEL_RE='^(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])?$'
MASTERTAG_RE='^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$'

DAY1=""; BASE=""; STRICT=0
REPOS=()

# ── reporting ────────────────────────────────────────────────────────────────
C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_BLD=""; C_OFF=""
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
  C_DIM=$'\033[2m';  C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
fi

repo_fails=0; repo_warns=0; total_fails=0; total_warns=0

section() { printf '\n%s── %s%s\n' "$C_BLD" "$1" "$C_OFF"; }
pass()    { printf '  %s[ OK ]%s %s\n'   "$C_GRN" "$C_OFF" "$1"; }
info()    { printf '  %s[ -- ]%s %s\n'   "$C_DIM" "$C_OFF" "$1"; }
# Totals accumulate here, not at the end of check_repo — an early return
# (unreadable dir, not a git repo, not a sigs tree) must still count.
warn()    { printf '  %s[WARN]%s %s\n'   "$C_YEL" "$C_OFF" "$1"
            repo_warns=$((repo_warns+1)); total_warns=$((total_warns+1)); }
fail()    { printf '  %s[FAIL]%s %s\n'   "$C_RED" "$C_OFF" "$1"
            repo_fails=$((repo_fails+1)); total_fails=$((total_fails+1)); }
detail()  { printf '         %s%s%s\n'   "$C_DIM" "$1" "$C_OFF"; }
die()     { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 2; }

# ── args ─────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --day1)   [ $# -ge 2 ] || die "--day1 needs a path"; DAY1="$2"; shift 2 ;;
    --base)   [ $# -ge 2 ] || die "--base needs a ref";  BASE="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    -*)       die "unknown option: $1" ;;
    *)        REPOS+=("$1"); shift ;;
  esac
done
[ ${#REPOS[@]} -gt 0 ] || die "usage: $0 [--day1 PATH] [--base REF] [--strict] <sigs-repo> [...]"
if [ -n "$DAY1" ] && [ ! -d "$DAY1" ]; then die "--day1 path is not a directory: $DAY1"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────

# Unique tracked child directories of $1, one segment down. Reads $TMP/tracked.
# Derived from the git index, because a folder git does not track does not exist
# for Argo either (git cannot track an empty folder — hence the .gitkeep rule).
child_dirs() {
  awk -F/ -v p="$1" '
    index($0, p "/") == 1 {
      n = split(p, a, "/"); d = n + 1
      if (NF > d) { q = $1; for (i = 2; i <= d; i++) q = q "/" $i; print q }
    }' "$TMP/tracked" | sort -u
}

# On-disk child directories of $1 (absolute repo path in $ROOT), one level down.
disk_dirs() {
  [ -d "$ROOT/$1" ] || return 0
  find "$ROOT/$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' \
    | sed "s|^$ROOT/||" | sort
}

# Right-hand side of a top-level `key:` line, trailing comment and blanks
# stripped. Mirrors render_chain.py's `^key:\s*(.+?)\s*(#.*)?$`.
yaml_rhs() {
  sed -n -E "s/^$2:[[:space:]]*(.*)\$/\1/p" "$1" 2>/dev/null | head -1 \
    | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//'
}
yaml_has_key() { grep -qE "^$2:" "$1" 2>/dev/null; }
unquote()      { printf '%s' "$1" | sed -E 's/^["'"'"']//; s/["'"'"']$//'; }

# ── content of one marker file ───────────────────────────────────────────────
# $1 repo-relative path, $2 = mce|hc
check_marker_content() {
  local rel="$1" kind="$2" f="$ROOT/$1" keys v raw

  if [ ! -s "$f" ]; then
    fail "$rel: marker file is EMPTY"
    detail "an empty marker yields zero generator params — every {{env}}/{{site}}/{{ocpVersion}}"
    detail "placeholder in Phase B's templates stays unsubstituted and the Application breaks"
    return
  fi

  case "$kind" in
    mce) keys="env site ocpVersion" ;;
    hc)  keys="ocpVersion" ;;
  esac

  for k in $keys; do
    if ! yaml_has_key "$f" "$k"; then
      fail "$rel: no top-level '$k:'"
      detail "Phase B renders {{$k}} into a label value; a missing key leaves the"
      detail "placeholder unsubstituted and the generated Application is rejected"
      continue
    fi
    raw="$(yaml_rhs "$f" "$k")"
    if [ -z "$raw" ]; then
      fail "$rel: '$k:' is present but has no value"
      continue
    fi
    v="$(unquote "$raw")"

    # ocpVersion must be quoted — 4.20 unquoted is the float 4.2 (render_chain.py:502)
    if [ "$k" = ocpVersion ] && ! printf '%s' "$raw" | grep -qE '^".+"$|^'"'"'.+'"'"'$'; then
      fail "$rel: ocpVersion must be quoted (YAML parses $raw as a float): got $raw"
    fi
    if [ "$k" = env ] && ! printf ' %s ' "$ENVS_ALLOWED" | grep -q " $v "; then
      fail "$rel: env '$v' is not one of: $ENVS_ALLOWED"
    fi
    if [ "${#v}" -gt 63 ] || ! printf '%s' "$v" | grep -qE "$LABEL_RE"; then
      fail "$rel: $k value '$v' is not a valid Kubernetes label value"
      detail "Phase B puts it in day2.gitops/$k — the Application would be rejected"
    fi
  done

  # hc.yaml carries ocpVersion and nothing else; env/site are inherited from the
  # MCE via Helm values, so these are inert — but they are not the contract.
  if [ "$kind" = hc ]; then
    for k in env site; do
      yaml_has_key "$f" "$k" && warn "$rel: carries '$k:' — hc.yaml is ocpVersion only (env/site are inherited from the MCE)"
    done
  fi
}

# ── one repo ─────────────────────────────────────────────────────────────────
check_repo() {
  local raw_path="$1"
  repo_fails=0; repo_warns=0

  [ -d "$raw_path" ] || { printf '\n%s=== %s ===%s\n' "$C_BLD" "$raw_path" "$C_OFF"
                          fail "not a directory"; return; }
  local top gerr
  gerr="$(git -C "$raw_path" rev-parse --show-toplevel 2>&1 >/dev/null)"
  top="$(git -C "$raw_path" rev-parse --show-toplevel 2>/dev/null)"
  if [ -z "$top" ]; then
    printf '\n%s=== %s ===%s\n' "$C_BLD" "$raw_path" "$C_OFF"
    fail "git cannot read this directory"
    [ -n "$gerr" ] && detail "$gerr"
    case "$gerr" in *"dubious ownership"*)
      detail "fix: git config --global --add safe.directory $raw_path" ;;
    esac
    return
  fi
  # The sigs tree is the given path, which is normally the repo root. Every git
  # call below runs with -C "$ROOT" and so is already scoped and relative to it.
  ROOT="$(cd "$raw_path" && pwd -P)"

  printf '\n%s================================================================%s\n' "$C_BLD" "$C_OFF"
  printf '%s%s%s\n' "$C_BLD" "$ROOT" "$C_OFF"
  printf '%s================================================================%s\n' "$C_BLD" "$C_OFF"

  git -C "$ROOT" ls-files > "$TMP/tracked"
  [ "$ROOT" = "$top" ] || printf '  %s[ -- ]%s not the repo root (%s) — checking this subtree only\n' "$C_DIM" "$C_OFF" "$top"

  # ── layout ──────────────────────────────────────────────────────────────
  section "layout"
  local have_legacy=0 have_sites=0
  grep -q '^mces/'  "$TMP/tracked" && have_legacy=1
  grep -q '^sites/' "$TMP/tracked" && have_sites=1
  if [ $have_legacy -eq 1 ] && [ $have_sites -eq 1 ]; then
    info "MIXED — mces/ and sites/ both present (the Phase C window). Both are checked."
  elif [ $have_legacy -eq 1 ]; then
    info "legacy mces/ layout (pre-Phase-C). This is the state Phase A targets."
  elif [ $have_sites -eq 1 ]; then
    info "sites/ layout (Phase C complete)."
  else
    fail "neither mces/ nor sites/ found — is this a sigs repo?"
    return
  fi

  local up
  up="$(git -C "$ROOT" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"
  if [ -n "$up" ] && [ "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" != "$(git -C "$ROOT" rev-parse "$up" 2>/dev/null)" ]; then
    info "HEAD differs from $up — Argo reads the pushed branch, this script reads your index."
  fi

  # ── discover what needs a marker ────────────────────────────────────────
  # Exactly the set the current directories: generators emit today.
  : > "$TMP/mce_dirs"; : > "$TMP/hc_dirs"; : > "$TMP/expected"
  local m e s mce hc

  if [ $have_legacy -eq 1 ]; then
    child_dirs "mces" | grep -v '^mces/in-cluster-defaults$' >> "$TMP/mce_dirs"
  fi
  if [ $have_sites -eq 1 ]; then
    for s in $(child_dirs "sites"); do
      for e in $(child_dirs "$s"); do
        child_dirs "$e/mces" >> "$TMP/mce_dirs"
      done
    done
  fi
  sort -u -o "$TMP/mce_dirs" "$TMP/mce_dirs"

  while read -r m; do
    [ -n "$m" ] || continue
    printf '%s/mce.yaml\n' "$m" >> "$TMP/expected"
    child_dirs "$m" | grep -v "^$m/in-cluster\$" >> "$TMP/hc_dirs"
  done < "$TMP/mce_dirs"
  sort -u -o "$TMP/hc_dirs" "$TMP/hc_dirs"
  while read -r hc; do
    [ -n "$hc" ] || continue
    printf '%s/hc.yaml\n' "$hc" >> "$TMP/expected"
  done < "$TMP/hc_dirs"
  sort -u -o "$TMP/expected" "$TMP/expected"

  grep -E '(^|/)(mce|hc)\.yaml$' "$TMP/tracked" | sort -u > "$TMP/actual"

  section "inventory"
  info "$(wc -l < "$TMP/mce_dirs" | tr -d ' ') MCE folder(s), $(wc -l < "$TMP/hc_dirs" | tr -d ' ') hosted-cluster folder(s) → $(wc -l < "$TMP/expected" | tr -d ' ') marker(s) required"
  while read -r m; do
    [ -n "$m" ] || continue
    printf '         %s%s%s\n' "$C_DIM" "$m" "$C_OFF"
    child_dirs "$m" | sed "s|\$|/|; s|/in-cluster/\$|/in-cluster   (the MCE hub — excluded, no hc.yaml)|" \
      | sed "s|^|           $C_DIM|; s|\$|$C_OFF|"
  done < "$TMP/mce_dirs"

  # ── 1. coverage ─────────────────────────────────────────────────────────
  section "1. coverage — every generated MCE / hosted cluster has its marker"
  comm -23 "$TMP/expected" "$TMP/actual" > "$TMP/missing"
  if [ -s "$TMP/missing" ]; then
    fail "$(wc -l < "$TMP/missing" | tr -d ' ') marker(s) MISSING — Phase B deletes these Applications"
    while read -r m; do detail "$m"; done < "$TMP/missing"
    if [ ! -s "$TMP/actual" ] && [ $have_legacy -eq 0 ]; then
      detail ""
      detail "NOTE: sites/ layout with no markers at all. If E.3 has already run here the"
      detail "markers were deleted on purpose (the platform reads day1) and Phase A no"
      detail "longer applies — this check is only meaningful between Phase A and E.3."
    fi
    if grep -qE '(^|/)config\.yaml$' "$TMP/tracked"; then
      detail ""
      detail "NOTE: this repo has config.yaml file(s). The marker names are mce.yaml and"
      detail "hc.yaml — one shared name over-matches the files: glob (CHANGES.md §0.1)."
    fi
  else
    pass "all $(wc -l < "$TMP/expected" | tr -d ' ') required markers present and tracked"
  fi

  # ── 2. placement ────────────────────────────────────────────────────────
  section "2. placement — no marker anywhere else (§0.2 hard rule)"
  comm -13 "$TMP/expected" "$TMP/actual" > "$TMP/extra"
  if [ -s "$TMP/extra" ]; then
    fail "$(wc -l < "$TMP/extra" | tr -d ' ') marker(s) at a location no generator expects"
    while read -r m; do
      case "$m" in
        */in-cluster/*)          detail "$m   <-- in an in-cluster/ folder: resolves to a REAL cluster" ;;
        mces/in-cluster-defaults/*) detail "$m   <-- under in-cluster-defaults/: not an MCE" ;;
        */mce.yaml)              detail "$m   <-- mce.yaml at the wrong depth" ;;
        */hc.yaml)               detail "$m   <-- hc.yaml at the wrong depth (chart folder?)" ;;
        *)                       detail "$m" ;;
      esac
    done < "$TMP/extra"
    detail ""
    detail "A files: glob's '*' crosses '/', so a stray marker generates a phantom app."
    detail "One inside in-cluster/ does not fail safe: prod-hub would sync the clusters"
    detail "chart against itself with a hosted-cluster path."
  else
    pass "no markers outside the two expected depths"
  fi

  # ── 3. git-pathspec parity (§0.3 standing rule) ──────────────────────────
  section "3. glob parity — what the repo-server actually sees (§0.3)"
  local glob want got
  for glob in "mces/*/mce.yaml" "mces/*/*/hc.yaml" \
              "sites/*/*/mces/*/mce.yaml" "sites/*/*/mces/*/*/hc.yaml"; do
    case "$glob" in
      mces/*)  [ $have_legacy -eq 1 ] || continue ;;
      sites/*) [ $have_sites  -eq 1 ] || continue ;;
    esac
    git -C "$ROOT" ls-files -- "$glob" | sort -u > "$TMP/got"
    # depth-exact reading of the same glob
    awk -F/ -v g="$glob" 'BEGIN { n = split(g, p, "/") }
      NF == n {
        for (i = 1; i <= n; i++) if (p[i] != "*" && p[i] != $i) next
        print
      }' "$TMP/tracked" | sort -u > "$TMP/want"
    if cmp -s "$TMP/want" "$TMP/got"; then
      pass "git ls-files -- '$glob'  == depth-exact ($(wc -l < "$TMP/got" | tr -d ' ') file(s))"
    else
      fail "git ls-files -- '$glob' DISAGREES with a depth-exact read"
      detail "git's pathspec matched extra paths — each one is a phantom Application:"
      comm -13 "$TMP/want" "$TMP/got" | while read -r m; do detail "  + $m"; done
    fi
  done

  # ── 4. marker content ───────────────────────────────────────────────────
  section "4. marker content"
  local before=$repo_fails
  while read -r m; do
    [ -n "$m" ] || continue
    case "$m" in
      */mce.yaml) check_marker_content "$m" mce ;;
      */hc.yaml)  check_marker_content "$m" hc ;;
    esac
  done < "$TMP/actual"
  [ "$repo_fails" -eq "$before" ] && pass "every marker carries its required keys, quoted and label-safe"

  # ── 5. tracked-ness ─────────────────────────────────────────────────────
  section "5. tracked in git — Argo reads the pushed tree, not your worktree"
  git -C "$ROOT" status --porcelain --untracked-files=all 2>/dev/null \
    | grep -E '(mce|hc)\.yaml$' > "$TMP/dirty"
  if [ -s "$TMP/dirty" ]; then
    warn "marker file(s) uncommitted — invisible to Argo until committed and pushed"
    while read -r m; do detail "$m"; done < "$TMP/dirty"
  else
    pass "no uncommitted marker files"
  fi

  # a folder git does not track is invisible to the generator entirely
  local d untracked=0
  {
    [ $have_legacy -eq 1 ] && disk_dirs "mces" | grep -v '^mces/in-cluster-defaults$'
    for m in $(sed -E 's|/[^/]+$||' "$TMP/mce_dirs" | sort -u); do disk_dirs "$m"; done
    while read -r m; do [ -n "$m" ] && disk_dirs "$m" | grep -v "^$m/in-cluster\$"; done < "$TMP/mce_dirs"
  } 2>/dev/null | grep -v '^mces/in-cluster-defaults$' | sort -u > "$TMP/disk"
  if [ -s "$TMP/disk" ]; then
    while read -r d; do
      [ -n "$d" ] || continue
      if ! grep -qxF "$d" "$TMP/mce_dirs" && ! grep -qxF "$d" "$TMP/hc_dirs"; then
        fail "$d/ exists on disk but git tracks nothing under it — invisible to Argo"
        detail "needs its Phase A marker (which is also the tracked content it lacks)"
        untracked=1
      fi
    done < "$TMP/disk"
  fi
  [ $untracked -eq 0 ] && pass "every MCE and hosted-cluster folder on disk is tracked by git"

  # ── 6. naming convention (advisory) ─────────────────────────────────────
  section "6. naming convention (advisory — the convention is undocumented)"
  local nfails=0 base benv bsite denv dsite
  while read -r m; do
    [ -n "$m" ] || continue
    [ -f "$ROOT/$m/mce.yaml" ] || continue
    base="$(basename "$m")"
    denv="$(unquote "$(yaml_rhs "$ROOT/$m/mce.yaml" env)")"
    dsite="$(unquote "$(yaml_rhs "$ROOT/$m/mce.yaml" site)")"
    if printf '%s' "$base" | grep -qE '^ocp4-[a-z0-9]+-mce-.+-[a-z0-9]+$'; then
      benv="$(printf '%s' "$base"  | sed -E 's/^ocp4-([a-z0-9]+)-mce-.*/\1/')"
      bsite="$(printf '%s' "$base" | sed -E 's/^ocp4-[a-z0-9]+-mce-(.+)-[a-z0-9]+$/\1/')"
      [ "$benv"  = "$denv"  ] || { warn "$m/mce.yaml: env '$denv' but the folder name says '$benv'"; nfails=1; }
      [ "$bsite" = "$dsite" ] || { warn "$m/mce.yaml: site '$dsite' but the folder name says '$bsite'"; nfails=1; }
    fi
    case "$m" in
      sites/*)
        s="$(printf '%s' "$m" | cut -d/ -f2)"; e="$(printf '%s' "$m" | cut -d/ -f3)"
        [ "$e" = "$denv"  ] || { fail "$m/mce.yaml: env '$denv' contradicts its path segment '$e'";  nfails=1; }
        [ "$s" = "$dsite" ] || { fail "$m/mce.yaml: site '$dsite' contradicts its path segment '$s'"; nfails=1; }
        ;;
    esac
  done < "$TMP/mce_dirs"
  [ $nfails -eq 0 ] && pass "env/site agree with folder names and path segments"

  # ── 7. day1 parity (optional) ───────────────────────────────────────────
  if [ -n "$DAY1" ]; then
    section "7. day1 parity (--day1) — WARN only; E.0.2 is the real gate"
    local d1 tag stream declared dfails=0
    while read -r m; do
      [ -n "$m" ] || continue
      mce="$(basename "$m")"
      case "$m" in
        sites/*) s="$(printf '%s' "$m" | cut -d/ -f2)" ;;
        *)       s="$(unquote "$(yaml_rhs "$ROOT/$m/mce.yaml" site)")" ;;
      esac
      [ -n "$s" ] || { warn "$m: no site — cannot locate its day1 file"; dfails=1; continue; }
      d1_check "sites/$s/mces/$mce/version.yaml" "$m" "$ROOT/$m/mce.yaml" || dfails=1
      while read -r hc; do
        case "$hc" in "$m"/*) ;; *) continue ;; esac
        d1_check "sites/$s/mces/$mce/hostedClusters/$(basename "$hc").yaml" "$hc" "$ROOT/$hc/hc.yaml" || dfails=1
      done < "$TMP/hc_dirs"
    done < "$TMP/mce_dirs"
    [ $dfails -eq 0 ] && pass "every MCE and hosted cluster has a day1 mastertag agreeing with its marker"
  fi

  # ── 8. additive-only (optional) ─────────────────────────────────────────
  if [ -n "$BASE" ]; then
    section "8. additive-only — $BASE..HEAD"
    if ! git -C "$ROOT" rev-parse --verify --quiet "$BASE" >/dev/null; then
      warn "ref '$BASE' does not resolve — skipping"
    else
      git -C "$ROOT" diff --no-renames --name-status "$BASE..HEAD" > "$TMP/diff"
      local bad=0
      grep -E '(mce|hc)\.yaml$' "$TMP/diff" | grep -v '^A' > "$TMP/badmark"
      if [ -s "$TMP/badmark" ]; then
        fail "marker file(s) modified or deleted — Phase A only ADDS"
        while read -r m; do detail "$m"; done < "$TMP/badmark"; bad=1
      fi
      grep -vE '(mce|hc)\.yaml$' "$TMP/diff" > "$TMP/other"
      if [ -s "$TMP/other" ]; then
        warn "$(wc -l < "$TMP/other" | tr -d ' ') non-marker change(s) in this range — Phase A is additive; confirm each is intended"
        while read -r m; do detail "$m"; done < "$TMP/other"
      fi
      [ $bad -eq 0 ] && [ ! -s "$TMP/other" ] && pass "range adds marker files and nothing else"
    fi
  fi

  # ── verdict ─────────────────────────────────────────────────────────────
  printf '\n'
  if [ "$repo_fails" -eq 0 ] && { [ "$repo_warns" -eq 0 ] || [ $STRICT -eq 0 ]; }; then
    printf '  %sPHASE A COMPLETE%s for %s  (%d warning(s))\n' "$C_GRN" "$C_OFF" "$(basename "$ROOT")" "$repo_warns"
  else
    printf '  %sPHASE A INCOMPLETE%s for %s  (%d failure(s), %d warning(s))\n' \
      "$C_RED" "$C_OFF" "$(basename "$ROOT")" "$repo_fails" "$repo_warns"
  fi
}

# day1 file check. $1 = day1-relative path, $2 = the day2 folder needing it,
# $3 = the marker whose ocpVersion is compared. Returns 1 on any finding.
d1_check() {
  local rel="$1" needed_by="$2" marker="$3" full="$DAY1/$1" tag base stream declared
  if [ ! -f "$full" ]; then
    warn "$needed_by: no day1 version file at $rel"
    detail "either day1 has not provisioned this cluster, or this folder is not a cluster"
    return 1
  fi
  tag="$(yaml_rhs "$full" mastertag)"; tag="$(unquote "$tag")"
  if [ -z "$tag" ]; then
    warn "$rel: no top-level mastertag (required by $needed_by)"; return 1
  fi
  if ! printf '%s' "$tag" | grep -qE "$MASTERTAG_RE"; then
    warn "$rel: mastertag '$tag' is not <major>.<minor>.<patch>[-<arch>]"; return 1
  fi
  # Two spellings of the same version both agree with day1, and both are in the
  # docs: Phase A's example writes the STREAM ("4.20"), decision 9 makes
  # ocpVersion the FULL PATCH version ("4.16.27"). Accept either — only a marker
  # naming a different version than day1 provisioned is a finding.
  declared="$(unquote "$(yaml_rhs "$marker" ocpVersion)")"
  base="$(printf '%s' "$tag" | cut -d- -f1)"                 # 4.16.27-x86_64 -> 4.16.27
  stream="$(printf '%s' "$base" | cut -d. -f1,2)"            #                -> 4.16
  if [ -n "$declared" ] && [ "$declared" != "$base" ] && [ "$declared" != "$stream" ]; then
    warn "$needed_by: marker ocpVersion '$declared' matches neither the day1 tag '$base' nor its stream '$stream' (mastertag: $tag)"
    detail "day1 is the source of truth; Phase E stops reading the marker entirely"
    return 1
  fi
  return 0
}

for r in "${REPOS[@]}"; do check_repo "$r"; done

printf '\n%s================================================================%s\n' "$C_BLD" "$C_OFF"
if [ "$total_fails" -gt 0 ]; then
  printf '%sFAILED%s — %d failure(s), %d warning(s) across %d repo(s)\n' \
    "$C_RED" "$C_OFF" "$total_fails" "$total_warns" "${#REPOS[@]}"
  exit 1
fi
if [ "$total_warns" -gt 0 ] && [ $STRICT -eq 1 ]; then
  printf '%sFAILED (--strict)%s — 0 failures, %d warning(s) across %d repo(s)\n' \
    "$C_RED" "$C_OFF" "$total_warns" "${#REPOS[@]}"
  exit 1
fi
printf '%sPASSED%s — 0 failures, %d warning(s) across %d repo(s)\n' \
  "$C_GRN" "$C_OFF" "$total_warns" "${#REPOS[@]}"
exit 0
