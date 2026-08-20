#!/usr/bin/env python3
"""Render-verify the day2 platform chain against the sigs tree.

Simulates what Argo CD does with the platform charts, offline:

  groups app -> mces chart -> mcesAppset      (git files/dirs generator, simulated)
             -> clusters chart -> clustersAppset + static inClusterApp
             -> operators chart -> operators appset
             -> deploy chart   -> leaf workload Application

For every generated Application it records identity fields, labels and the
ordered sequence of *existing* value files (path + content hash) the app
resolves. Value files come from TWO repos: the sigs repo ($values) and the
day1 platform-config repo ($day1), which owns every cluster's OCP version as
`mastertag`. Resolved files land in one of THREE buckets:

  sigs     workload config -> a change here changes what a workload renders
                              -> HARD
  day1     cluster OCP versions -> this is where versions are SUPPOSED to
                              change -> INFO
  control  CONTROL_FILES: the fleet-default exclusion matrices, which decide
                              whether an Application EXISTS rather than what it
                              renders. Hashing them into the sigs sequence
                              would raise a HARD diff on every app in the team
                              for a change whose real effect is a two-line
                              APPS DISAPPEARED -> INFO

Snapshots taken before/after a change are compared with `compare`: identity
fields and the sigs-resolved content sequence must be equal; everything else
(labels, valueFiles path strings, extra ref sources, day1 versions, control
files) is reported as an expected/informational diff.

This simulates the documented ApplicationSet generator parameters only
({{path}}, {{path.basename}}, {{path[n]}}, flattened file keys). It is a
pre-merge gate, not a substitute for live Argo verification.

Usage:
  render_chain.py snapshot --out DIR [--repo ROOT] [--group NAME]
                           [--sigs ROOT] [--platform ROOT] [--day1 ROOT]
  render_chain.py compare OLD_DIR NEW_DIR

In this mock the three repos are subdirectories of one checkout, which is what
the flag defaults describe. In the air-gapped env they are three separate
GitLab projects, so CI passes --sigs / --platform / --day1 explicitly and
--group $CI_PROJECT_NAME. Reference pipeline fragments: tools/ci/.
"""

import argparse
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

PLATFORM_MARKER = "argocd-day2-platform.git"
SIGS_MARKER = "/sigs/"
# Fleet-default opt-out matrices: inputs to GENERATION, not to a workload's
# values — they decide whether an Application is created at all. One fixed
# path per scope, because the template that consumes them (the operators
# chart) only ever sees Helm values: chart folder names are discovered from
# git at generator time and never reach it. Bucketed away from the sigs
# sequence in compare — see the module docstring.
CONTROL_FILES = {"defaults/hosted-clusters/exclusions.yaml",
                 "defaults/mces/exclusions.yaml"}
ENVS_ALLOWED = {"prod", "prep", "test"}

# All four are set in main(). In this mock the three repos are subdirectories
# of one checkout; in the air-gapped env they are three separate GitLab
# projects, so every one of them is a flag with a mock-shaped default. GROUP is
# the team name, which in a sigs pipeline is $CI_PROJECT_NAME — the scmProvider
# generator names teams by repo, so the two are the same string by
# construction.
GROUP = None
REPO = None
SIGS = None
PLATFORM = None
DAY1 = None  # gitops-day1/platform-config checkout: the version source of truth

CHECK_FAILURES = []


def fail(msg):
    CHECK_FAILURES.append(msg)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def deep_merge(base, over):
    """Helm-style merge: maps merge recursively, everything else replaces."""
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = deep_merge(out.get(k), v) if k in out else v
        return out
    return over if over is not None else base


def helm_template(chart_dir, values: dict):
    """Render a platform chart (empty Chart.yaml in-repo -> synthesize one)."""
    tmp = tempfile.mkdtemp(prefix="rv-")
    try:
        dst = os.path.join(tmp, "chart")
        shutil.copytree(chart_dir, dst)
        name = os.path.basename(chart_dir.rstrip("/"))
        with open(os.path.join(dst, "Chart.yaml"), "w") as f:
            f.write(f"apiVersion: v2\nname: {name}\nversion: 0.1.0\n")
        vf = os.path.join(tmp, "vals.yaml")
        with open(vf, "w") as f:
            yaml.safe_dump(values or {}, f)
        res = subprocess.run(
            ["helm", "template", "x", dst, "-f", vf],
            capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"helm template {name} failed:\n{res.stderr}")
        return [d for d in yaml.safe_load_all(res.stdout) if d]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def flatten(d, prefix=""):
    out = {}
    for k, v in (d or {}).items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            out.update(flatten(v, key + "."))
        elif isinstance(v, bool):
            out[key] = "true" if v else "false"
        else:
            out[key] = str(v)
    return out


def path_params(rel_dir):
    p = {"path": rel_dir, "path.basename": posixpath.basename(rel_dir)}
    for i, seg in enumerate(rel_dir.split("/")):
        p[f"path[{i}]"] = seg
    return p


# Argo's two git generators use two DIFFERENT glob engines. Do not assume
# either one; the difference is what broke prod at Phase B (CHANGES.md §0).
#
#   directories:  repo-server lists directories, the controller filters them
#                 with Go path.Match  ->  '*' matches exactly ONE path segment.
#   files:        repo-server runs `git ls-files -- <pattern>`; a git pathspec
#                 is matched with wildmatch *without* WM_PATHNAME
#                 ->  '*' CROSSES '/' and therefore matches at ANY depth.
#
# `files:` only becomes depth-exact (doublestar) when the applicationset
# controller runs with applicationsetcontroller.enable.new.git.file.globbing=
# "true". That is off by default and would have to be on for every Argo in the
# fleet, so the simulation models the default and never relies on it.

_PATHS = None


def _tree():
    """(files, dirs) as sorted repo-relative posix paths under SIGS."""
    global _PATHS
    if _PATHS is None:
        files, dirs = [], []
        for root, dnames, fnames in os.walk(SIGS):
            dnames[:] = sorted(d for d in dnames if not d.startswith("."))
            rel = os.path.relpath(root, SIGS)
            base = "" if rel == "." else rel.replace(os.sep, "/") + "/"
            dirs.extend(base + d for d in dnames)
            files.extend(base + f for f in sorted(fnames) if not f.startswith("."))
        _PATHS = (sorted(files), sorted(dirs))
    return _PATHS


def _wildmatch_re(pattern, cross_slash):
    """Compile a glob to a regex. cross_slash=True is git-pathspec/wildmatch
    semantics (* eats '/'); False is Go path.Match semantics (* stops at '/')."""
    star = ".*" if cross_slash else "[^/]*"
    any_one = "." if cross_slash else "[^/]"
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            while i + 1 < len(pattern) and pattern[i + 1] == "*":
                i += 1  # ** is not special without WM_PATHNAME
            out.append(star)
        elif c == "?":
            out.append(any_one)
        elif c == "[":
            j = i + 1
            if j < len(pattern) and pattern[j] in "!^":
                j += 1
            if j < len(pattern) and pattern[j] == "]":
                j += 1
            while j < len(pattern) and pattern[j] != "]":
                j += 1
            if j >= len(pattern):
                out.append(re.escape(c))
            else:
                cls = pattern[i + 1:j]
                out.append("[" + ("^" + cls[1:] if cls.startswith("!") else cls) + "]")
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def _match(pattern, want_dirs, cross_slash):
    rx = _wildmatch_re(pattern, cross_slash)
    files, dirs = _tree()
    return [p for p in (dirs if want_dirs else files) if rx.match(p)]


def match_dirs(pattern):
    """directories: generator -> Go path.Match, depth-exact."""
    return _match(pattern, want_dirs=True, cross_slash=False)


def git_ls(pattern):
    """Raw `git ls-files -- <pattern>` semantics: * crosses '/'."""
    return _match(pattern, want_dirs=False, cross_slash=True)


def match_files(pattern):
    """files: generator, plus a guard against depth-ambiguous globs.

    A files: glob whose git-pathspec matches differ from its depth-exact
    matches is the Phase B production bug: the extra hits become real
    Applications pointing at whatever {{path.basename}} happens to be. Fix it
    with a marker filename that is unique to the intended depth, not by
    assuming the glob is anchored."""
    loose = git_ls(pattern)
    strict = _match(pattern, want_dirs=False, cross_slash=False)
    extra = sorted(set(loose) - set(strict))
    if extra:
        fail(f"DEPTH-AMBIGUOUS files: glob {pattern!r} — git pathspec also "
             f"matches {extra}, which a depth-exact reading would not. Under "
             f"the default Argo config every extra hit becomes an Application. "
             f"Use a marker filename unique to that depth.")
    return loose


def generator_param_sets(gen):
    """Simulate one git generator entry -> list of param dicts."""
    git = gen.get("git")
    if not git:
        return None  # non-git generator (clusters:{}, scmProvider) -> skip
    sets = []
    if "directories" in git:
        include, exclude = set(), set()
        for entry in git["directories"]:
            hits = match_dirs(entry["path"])
            (exclude if entry.get("exclude") else include).update(hits)
        for d in sorted(include - exclude):
            sets.append(path_params(d))
    elif "files" in git:
        seen = set()
        for entry in git["files"]:
            for f in match_files(entry["path"]):
                if f in seen:
                    continue
                seen.add(f)
                rel_dir = posixpath.dirname(f)
                with open(os.path.join(SIGS, f)) as fh:
                    content = yaml.safe_load(fh) or {}
                params = path_params(rel_dir)
                params["path.filename"] = posixpath.basename(f)
                params.update(flatten(content))
                sets.append(params)
    return sets


def fasttemplate(text, params):
    for k, v in params.items():
        text = text.replace("{{" + k + "}}", v)
    return text


def resolve_value_files(value_files):
    """Resolve a valueFiles list across both ref'd repos.

    $values/<p> -> sigs repo, $day1/<p> -> day1 platform-config. Each resolved
    entry is tagged with its repo: compare treats the sigs sequence as
    load-bearing (a change there changes what a workload renders) and the day1
    sequence as informational (that is where versions are SUPPOSED to change).

    Returns (resolved list, merged dict).
    """
    resolved, merged = [], {}
    for vf in value_files or []:
        if vf.startswith("$day1/"):
            root, rel, repo = DAY1, vf[len("$day1/"):], "day1"
        elif vf.startswith("$values/"):
            root, rel, repo = SIGS, vf[len("$values/"):], "sigs"
        elif vf.startswith("$"):
            fail(f"value file with unknown $ref prefix: {vf} "
                 f"(known refs: $values -> sigs, $day1 -> platform-config)")
            continue
        else:
            root, rel, repo = SIGS, vf, "sigs"
        rel = posixpath.normpath(rel)
        if repo == "sigs" and rel in CONTROL_FILES:
            repo = "control"
        full = os.path.join(root, rel)
        if os.path.isfile(full):
            with open(full, "rb") as fh:
                data = fh.read()
            resolved.append({"path": rel, "hash": sha(data), "repo": repo})
            merged = deep_merge(merged, yaml.safe_load(data) or {})
    return resolved, merged


def record_app(snapshot, argo, layer, app, resolved):
    name = app["metadata"]["name"]
    uid = f"{argo}:{name}"
    if uid in snapshot["apps"]:
        fail(f"DUPLICATE app generated: {uid} (the ONE INVARIANT is violated)")
    spec = app.get("spec", {})
    sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
    src = sources[0] if sources else {}
    snapshot["apps"][uid] = {
        "layer": layer,
        "argo": argo,
        "identity": {
            "name": name,
            "namespace": app["metadata"].get("namespace"),
            "project": spec.get("project"),
            "destination": spec.get("destination"),
            "source_repoURL": src.get("repoURL"),
            "source_targetRevision": src.get("targetRevision"),
            "source_path": src.get("path"),
            "releaseName": (src.get("helm") or {}).get("releaseName"),
            "syncPolicy": spec.get("syncPolicy"),
            "ignoreDifferences": spec.get("ignoreDifferences"),
        },
        # NOT identity: a value-only `ref:` source changes nothing Argo syncs —
        # what it resolves to is verified through "resolved" instead. Adding one
        # (e.g. the day1 version repo) must not read as an identity change.
        "extra_sources": [
            {"repoURL": s.get("repoURL"), "targetRevision": s.get("targetRevision"),
             "ref": s.get("ref")} for s in sources[1:]],
        "labels": app["metadata"].get("labels") or {},
        "valueFiles": (src.get("helm") or {}).get("valueFiles") or [],
        "resolved": resolved,
        "spec_hash": sha(json.dumps(app, sort_keys=True, default=str).encode()),
        "full": app,
    }
    return uid


def check_no_placeholders(app):
    txt = json.dumps(app, default=str)
    if "{{" in txt:
        fail(f"unsubstituted placeholder in generated app "
             f"{app['metadata'].get('name')}: ...{txt[max(0, txt.find('{{') - 40):txt.find('{{') + 40]}...")


def process_application(snapshot, argo, app, layer):
    """Record app; if it points at a platform chart, render it and recurse."""
    spec = app.get("spec", {})
    sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
    src = sources[0] if sources else {}
    helm = src.get("helm") or {}
    is_platform = PLATFORM_MARKER in (src.get("repoURL") or "")

    resolved, merged = resolve_value_files(helm.get("valueFiles"))
    inline = yaml.safe_load(helm.get("values") or "") or {}
    record_app(snapshot, argo, layer, app, resolved)
    if not is_platform:
        return  # leaf workload app

    values = deep_merge(merged, inline)
    chart_dir = os.path.join(PLATFORM, src.get("path"))
    docs = helm_template(chart_dir, values)

    dest = (spec.get("destination") or {}).get("name")
    child_argo = argo if dest in (None, "in-cluster") else dest

    for doc in docs:
        process_doc(snapshot, child_argo, doc, parent_layer=layer)


def process_doc(snapshot, argo, doc, parent_layer):
    kind = doc.get("kind")
    if kind == "Application":
        process_application(snapshot, argo, doc, layer=parent_layer + "/app")
    elif kind == "ApplicationSet":
        name = doc["metadata"]["name"]
        snapshot["appsets"][f"{argo}:{name}"] = {
            "argo": argo,
            "spec_hash": sha(json.dumps(doc, sort_keys=True, default=str).encode()),
            "full": doc,
        }
        template_txt = yaml.safe_dump(doc["spec"]["template"], sort_keys=False)
        for gen in doc["spec"].get("generators", []):
            sets = generator_param_sets(gen)
            if sets is None:
                continue  # non-git generator: recorded CR only
            for params in sets:
                app = yaml.safe_load(fasttemplate(template_txt, params))
                app.setdefault("apiVersion", "argoproj.io/v1alpha1")
                app.setdefault("kind", "Application")
                check_no_placeholders(app)
                process_application(snapshot, argo, app,
                                    layer=parent_layer + f"/{name}")
    else:
        snapshot["other"][f"{argo}:{kind}/{doc['metadata']['name']}"] = sha(
            json.dumps(doc, sort_keys=True, default=str).encode())


MASTERTAG_RE = re.compile(r"^\d+\.\d+\.\d+(-\S+)?$")


def day1_version_file(site, mce, hc=None):
    """The day1 file that owns this MCE's / hosted cluster's OCP version.

    The day1 tree has NO <env> level — env lives only inside the resource name:
      day2  sites/<site>/<env>/mces/<mce>[/<hc>]
      day1  sites/<site>/mces/<mce>/version.yaml
            sites/<site>/mces/<mce>/hostedClusters/<hc>.yaml
    Hosted-cluster names match exactly, folder name == file name minus .yaml.

    The two files are not the same kind of thing. A hosted cluster's file is
    day1's own provisioning input — day2 reads the tag day1 actually installed.
    version.yaml is day2-owned: day1's charts never consume it, and the MCE's
    values.yaml beside it is day1's *default HC version*, not the hub's own.
    """
    if hc is None:
        return f"sites/{site}/mces/{mce}/version.yaml"
    return f"sites/{site}/mces/{mce}/hostedClusters/{hc}.yaml"


def day1_mastertag(rel, needed_by):
    """Read + validate the mastertag out of a day1 file. None on any failure."""
    full = os.path.join(DAY1, rel)
    if not os.path.isfile(full):
        fail(f"{needed_by}: no day1 version file at {rel} — every MCE and "
             f"hosted-cluster folder resolves its OCP version from one. Either "
             f"day1 has not provisioned this cluster, or this folder is not a "
             f"cluster at all (a stray folder here becomes a phantom app)")
        return None
    with open(full) as fh:
        raw = fh.read()
    m = re.search(r'^mastertag:\s*["\']?([^\s"\']+)["\']?\s*(#.*)?$', raw, re.M)
    if not m:
        fail(f"{rel}: no top-level mastertag (required by {needed_by})")
        return None
    if not MASTERTAG_RE.match(m.group(1)):
        fail(f"{rel}: mastertag {m.group(1)!r} is not "
             f"<major>.<minor>.<patch>[-<arch>] — the platform strips the arch "
             f"at the first '-' and uses the rest verbatim as ocpVersion")
        return None
    return m.group(1)


def lint_sigs_tree():
    """§9.2 consistency checks on the sigs repo.

    Discovery is by FOLDER (no marker files): an MCE is a folder under
    sites/<site>/<env>/mces/, a hosted cluster is any folder inside one except
    in-cluster/. Every such folder must have a day1 platform-config file
    carrying the `mastertag` its OCP version is rendered from — that parity
    check is also what catches a stray folder that is not a cluster, before it
    becomes a phantom Application.
    """
    if git_ls("mces/*/mce.yaml") or git_ls("mces/*/*/hc.yaml"):
        fail("legacy mces/ layout found: a day1 version file cannot be located "
             "without the sites/<site>/ path segment — finish the sites/ "
             "migration before the day1-version change")

    for mce_dir in sorted(match_dirs("sites/*/*/mces/*")):
        segs = mce_dir.split("/")          # sites/<site>/<env>/mces/<mce>
        site, env, mce = segs[1], segs[2], segs[4]
        if env not in ENVS_ALLOWED:
            fail(f"{mce_dir}: env folder '{env}' not in {sorted(ENVS_ALLOWED)}")
        day1_mastertag(day1_version_file(site, mce), mce_dir)

        for hc_dir in sorted(match_dirs(f"{mce_dir}/*")):
            hc = posixpath.basename(hc_dir)
            if hc == "in-cluster":
                continue               # the MCE hub itself, excluded by the appset
            day1_mastertag(day1_version_file(site, mce, hc), hc_dir)

    # Migration window: marker files are inert once the platform reads day1,
    # but while they still exist they must not contradict it. Legacy markers
    # carry the STREAM (4.16), day1 carries the full tag (4.16.27-x86_64).
    for cfg in sorted(set(git_ls("sites/*/*/mces/*/mce.yaml")
                          + git_ls("sites/*/*/mces/*/*/hc.yaml"))):
        with open(os.path.join(SIGS, cfg)) as fh:
            raw = fh.read()
        m = re.search(r'^ocpVersion:\s*(.+?)\s*(#.*)?$', raw, re.M)
        if not m:
            continue                   # presence-only marker: nothing to check
        declared = m.group(1)
        if not re.match(r"""^["'].+["']$""", declared):
            fail(f"{cfg}: ocpVersion must be quoted (YAML would parse "
                 f"{declared} as a float): got {declared}")
        segs = cfg.split("/")           # sites/<site>/<env>/mces/<mce>[/<hc>]/<marker>
        site, mce = segs[1], segs[4]
        hc = segs[5] if segs[-1] == "hc.yaml" else None
        tag = day1_mastertag(day1_version_file(site, mce, hc), cfg)
        if tag:
            stream = ".".join(tag.split("-")[0].split(".")[:2])
            if declared.strip("\"'") != stream:
                fail(f"{cfg}: declared ocpVersion {declared} disagrees with the "
                     f"day1 mastertag {tag} (stream {stream}) — day1 is the "
                     f"source of truth; delete the stale marker value")


def lint_exclusions():
    """Rules 0-3 on defaults/<scope>/exclusions.yaml — the structural opt-out.

    A typo here is SILENT everywhere else in the chain: Helm renders, the
    generator runs, and the chart keeps deploying. The two typo axes fail
    differently, which is why BOTH name rules exist —

      wrong CHART name   -> an `exclude:` path matching no folder. The include
                            glob still emits the real chart, so it DEPLOYS to
                            the cluster someone asked to opt out.  (Rule 1)
      wrong TARGET name  -> `has` is false for every cluster, so no exclude
                            entry is emitted anywhere at all.       (Rule 2)

    Absent is the normal state: most teams never write either file, and many
    sigs repos carry neither defaults folder. Skip silently.
    """
    # Rule 3 — the hub is not a fleet scope. A file here is inert: the hub flow
    # is mces/inClusterAppset -> deploy and never passes through the operators
    # chart, the only template that reads an exclusion matrix.
    if os.path.isfile(os.path.join(SIGS, "defaults/hub/exclusions.yaml")):
        fail("defaults/hub/exclusions.yaml: Rule 3 — there are no hub "
             "exclusions. The hub is a single cluster and its charts never "
             "flow through the operators chart, so nothing would ever read "
             "this file. To stop deploying a hub chart, delete its folder.")

    known = {
        "defaults/mces": ("MCE", sorted(
            posixpath.basename(d) for d in match_dirs("sites/*/*/mces/*"))),
        "defaults/hosted-clusters": ("hosted cluster", sorted(
            {posixpath.basename(d) for d in match_dirs("sites/*/*/mces/*/*")}
            - {"in-cluster"})),
    }

    for scope, (kind, names_known) in sorted(known.items()):
        rel = f"{scope}/exclusions.yaml"
        full = os.path.join(SIGS, rel)
        if not os.path.isfile(full):
            continue                     # absent is the normal state

        # Rule 0 — schema. This file is merged into the operators chart's
        # values, so a stray top-level key does not sit there as a comment: it
        # lands as a chart value (a stray `mastertag` would be an OCP version).
        try:
            with open(full) as fh:
                doc = yaml.safe_load(fh)
        except yaml.YAMLError as e:
            fail(f"{rel}: Rule 0 — not parseable as YAML: {e}")
            continue
        doc = doc if doc is not None else {}
        if not isinstance(doc, dict):
            fail(f"{rel}: Rule 0 — the top level must be a mapping carrying the "
                 f"single key `exclusions`, got {type(doc).__name__}")
            continue
        stray = sorted(set(doc) - {"exclusions"})
        if stray:
            fail(f"{rel}: Rule 0 — `exclusions` must be the ONLY top-level key; "
                 f"found {stray}. Every other key is merged into the operators "
                 f"chart's values, where it is a real chart value and not a "
                 f"comment.")
        ex = doc.get("exclusions")
        if ex is None:
            continue                     # declared but empty: legal and inert
        if not isinstance(ex, dict):
            fail(f"{rel}: Rule 0 — `exclusions` must be a map of <chart> -> "
                 f"[{kind} names], got {type(ex).__name__}")
            continue

        charts = sorted(posixpath.basename(d) for d in match_dirs(f"{scope}/*"))
        for chart, names in sorted(ex.items()):
            # Rule 1 — chart names.
            if chart not in charts:
                fail(f"{rel}: Rule 1 — key {chart!r} is not a chart folder in "
                     f"{scope}/ (have: {charts or 'none'}). It would render as "
                     f'an exclude of "{scope}/{chart}", match no folder and '
                     f"remove NOTHING, while the include glob still emits the "
                     f"real chart — so it keeps deploying to the cluster that "
                     f"asked to opt out. NOTE: a new fleet chart that ships "
                     f"WITH exclusions means the chart folder and this entry "
                     f"land in the SAME commit — chart-first deploys it to the "
                     f"excluded cluster for one sync interval, entry-first "
                     f"fails this rule.")
            if names is None:
                continue                 # listed, excluded nowhere: inert
            if not isinstance(names, list):
                fail(f"{rel}: Rule 0 — exclusions.{chart} must be a list of "
                     f"{kind} names, got {type(names).__name__}")
                continue
            # Rule 2 — target names.
            for n in names:
                if not isinstance(n, str):
                    fail(f"{rel}: Rule 0 — exclusions.{chart} entry {n!r} is a "
                         f"{type(n).__name__}; every entry must be a {kind} "
                         f"name (string)")
                    continue
                if n not in names_known:
                    fail(f"{rel}: Rule 2 — {n!r} under exclusions.{chart} is not "
                         f"a {kind} in this repo (have: {names_known or 'none'}). "
                         f"It matches no destination, so NO exclude entry is "
                         f"emitted anywhere at all and {chart} still deploys "
                         f"fleet-wide — the failure is completely silent "
                         f"without this rule.")


def lint_frozen_lines():
    for f in ("mces/templates/mcesAppset.yaml", "mces/templates/appProjectAppset.yaml"):
        p = os.path.join(PLATFORM, f)
        with open(p) as fh:
            txt = fh.read()
        if "namespace: gitops-{{ .Values.repository }}" not in txt:
            fail(f"{f}: FROZEN line 'namespace: gitops-{{{{ .Values.repository }}}}' "
                 f"is missing or altered")


def take_snapshot(out_dir):
    snapshot = {"apps": {}, "appsets": {}, "other": {}}
    lint_sigs_tree()
    # BEFORE the render: a malformed exclusions file makes the operators chart
    # `fail`, which collapses into a single `render aborted:` line. The precise
    # rule message has to already be in CHECK_FAILURES by then.
    lint_exclusions()
    lint_frozen_lines()

    # A chart that refuses to render (e.g. `required` on a version the day1
    # repo does not carry) is a CHECK FAILURE, not a crash: the negative tests
    # depend on it being reported like any other consistency failure.
    try:
        # groups chart: static render, record only (scmProvider generator).
        for doc in helm_template(os.path.join(PLATFORM, "groups"), {}):
            process_doc(snapshot, "prod-hub", doc, parent_layer="groups")

        # Seed: the groups app for this team -> platform mces chart on prod-hub.
        seed = {
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
            "metadata": {"name": GROUP, "namespace": f"gitops-{GROUP}"},
            "spec": {
                "project": "default",
                "source": {"repoURL": f"https://x/{PLATFORM_MARKER}",
                           "targetRevision": "main", "path": "mces",
                           "helm": {"values": f"group: '{GROUP}'\n"}},
                "destination": {"name": "in-cluster"},
            },
        }
        process_application(snapshot, "prod-hub", seed, layer="root")
    except RuntimeError as e:
        fail(f"render aborted: {e}")

    os.makedirs(out_dir, exist_ok=True)
    for uid, a in snapshot["apps"].items():
        a.pop("full", None)
    for uid, a in snapshot["appsets"].items():
        a.pop("full", None)
    snapshot["check_failures"] = CHECK_FAILURES
    with open(os.path.join(out_dir, "snapshot.json"), "w") as f:
        json.dump(snapshot, f, indent=1, sort_keys=True, default=str)

    print(f"snapshot: {len(snapshot['apps'])} apps, "
          f"{len(snapshot['appsets'])} appset CRs -> {out_dir}")
    if CHECK_FAILURES:
        print("CONSISTENCY CHECK FAILURES:")
        for c in CHECK_FAILURES:
            print("  -", c)
        return 1
    return 0


def compare(old_dir, new_dir):
    with open(os.path.join(old_dir, "snapshot.json")) as f:
        old = json.load(f)
    with open(os.path.join(new_dir, "snapshot.json")) as f:
        new = json.load(f)
    hard, info = [], []

    o_apps, n_apps = old["apps"], new["apps"]
    gone = sorted(set(o_apps) - set(n_apps))
    added = sorted(set(n_apps) - set(o_apps))
    if gone:
        hard.append(f"APPS DISAPPEARED: {gone}")
    if added:
        info.append(f"apps added: {added}")

    for uid in sorted(set(o_apps) & set(n_apps)):
        o, n = o_apps[uid], n_apps[uid]
        if o["identity"] != n["identity"]:
            for k in o["identity"]:
                if k == "extra_sources":
                    continue           # pre-day1 snapshots kept it under identity
                if o["identity"][k] != n["identity"].get(k):
                    hard.append(f"{uid}: identity field '{k}' changed: "
                                f"{o['identity'][k]!r} -> {n['identity'].get(k)!r}")
        # Value-only ref sources: losing one breaks resolution, gaining one
        # (the day1 version repo) is the expected shape of this change.
        o_x = o.get("extra_sources", o["identity"].get("extra_sources", []))
        n_x = n.get("extra_sources", n["identity"].get("extra_sources", []))
        if [s for s in o_x if s not in n_x]:
            hard.append(f"{uid}: ref sources removed/changed: "
                        f"{[s for s in o_x if s not in n_x]}")
        if [s for s in n_x if s not in o_x]:
            info.append(f"{uid}: ref sources added: "
                        f"{[s for s in n_x if s not in o_x]}")
        # The sigs sequence decides what a workload renders -> HARD.
        # The day1 sequence carries cluster versions, which are SUPPOSED to
        # change on an upgrade -> INFO.
        def _split(app, repo):
            return [(r["path"], r["hash"]) for r in app["resolved"]
                    if r.get("repo", "sigs") == repo]
        if _split(o, "sigs") != _split(n, "sigs"):
            hard.append(f"{uid}: resolved sigs value-file content sequence "
                        f"changed:\n    old: {_split(o, 'sigs')}"
                        f"\n    new: {_split(n, 'sigs')}")
        if _split(o, "day1") != _split(n, "day1"):
            info.append(f"{uid}: day1 version files {_split(o, 'day1')} -> "
                        f"{_split(n, 'day1')}")
        # The exclusion matrix decides whether apps EXIST, not what they
        # render. Its real effect shows up as APPS DISAPPEARED (HARD) on the
        # handful of apps actually excluded — reporting the file's own hash as
        # HARD would flag every app in the team for the same change.
        if _split(o, "control") != _split(n, "control"):
            info.append(f"{uid}: exclusion control file {_split(o, 'control')} "
                        f"-> {_split(n, 'control')}")
        if o["labels"] != n["labels"]:
            info.append(f"{uid}: labels {o['labels']} -> {n['labels']}")
        if o["valueFiles"] != n["valueFiles"]:
            info.append(f"{uid}: valueFiles list changed (resolution verified "
                        f"separately)")
        if o["spec_hash"] != n["spec_hash"] and o["identity"] == n["identity"]:
            pass  # covered by labels/valueFiles notes

    if new.get("check_failures"):
        hard.append(f"new snapshot has consistency failures: {new['check_failures']}")

    print(f"== compare {old_dir} -> {new_dir} ==")
    print(f"apps: {len(o_apps)} -> {len(n_apps)}")
    for line in info:
        print("  [info]", line)
    if hard:
        print("HARD FAILURES:")
        for line in hard:
            print("  [FAIL]", line)
        return 1
    print("IDENTITY OK: names, destinations, releaseNames, syncPolicies and "
          "resolved value-file contents are unchanged.")
    return 0


def main():
    global GROUP, REPO, SIGS, PLATFORM, DAY1
    ap = argparse.ArgumentParser(
        description="Render-verify the day2 platform chain. `snapshot` exits 1 "
                    "on any consistency failure, so a CI lint job is just "
                    "`snapshot` with the output discarded.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("snapshot")
    s.add_argument("--out", required=True)
    s.add_argument("--repo", default=None,
                   help="mock checkout holding all three repos; only used to "
                        "derive the defaults of --sigs and --platform")
    s.add_argument("--group", default="redbull",
                   help="team name. In a sigs pipeline this is $CI_PROJECT_NAME "
                        "— the scmProvider generator names teams by repo "
                        "(default: %(default)s)")
    s.add_argument("--sigs", default=None,
                   help="sigs repo checkout for --group (default: "
                        "<repo>/sigs/<group>)")
    s.add_argument("--platform", default=None,
                   help="argocd-day2-platform checkout (default: "
                        "<repo>/argocd-day2-platform)")
    s.add_argument("--day1", default=None,
                   help="gitops-day1/platform-config checkout (the OCP version "
                        "source of truth); defaults to ../gitops-day1/platform-config")
    c = sub.add_parser("compare")
    c.add_argument("old")
    c.add_argument("new")
    args = ap.parse_args()

    if args.cmd == "compare":
        sys.exit(compare(args.old, args.new))

    GROUP = args.group
    REPO = args.repo if args.repo else \
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    SIGS = os.path.abspath(args.sigs) if args.sigs \
        else os.path.join(REPO, "sigs", GROUP)
    PLATFORM = os.path.abspath(args.platform) if args.platform \
        else os.path.join(REPO, "argocd-day2-platform")
    DAY1 = os.path.abspath(args.day1) if args.day1 else os.path.normpath(
        os.path.join(REPO, "..", "gitops-day1", "platform-config"))

    for label, path, why in (
        ("sigs repo", SIGS, f"the team tree for group {GROUP!r} — pass --sigs ROOT"),
        ("platform repo", PLATFORM, "the day2 platform charts — pass --platform ROOT"),
        ("day1 platform-config", DAY1,
         "every cluster's OCP version (`mastertag`) is read from it — clone it "
         "next to this repo or pass --day1 ROOT"),
    ):
        if not os.path.isdir(path):
            print(f"{label} checkout not found: {path}\n{why}", file=sys.stderr)
            sys.exit(2)

    sys.exit(take_snapshot(args.out))


if __name__ == "__main__":
    main()
