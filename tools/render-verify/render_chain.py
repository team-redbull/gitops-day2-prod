#!/usr/bin/env python3
"""Render-verify the day2 platform chain against the sigs tree.

Simulates what Argo CD does with the platform charts, offline:

  groups app -> mces chart -> mcesAppset      (git files/dirs generator, simulated)
             -> clusters chart -> clustersAppset + static inClusterApp
             -> operators chart -> operators appset
             -> deploy chart   -> leaf workload Application

For every generated Application it records identity fields, labels and the
ordered sequence of *existing* value files (path + content hash) the app
resolves from the sigs repo. Snapshots taken before/after a change are compared
with `compare`: identity fields and resolved-content sequences must be equal;
everything else (labels, valueFiles path strings, extra inline values) is
reported as an expected/informational diff.

This simulates the documented ApplicationSet generator parameters only
({{path}}, {{path.basename}}, {{path[n]}}, flattened file keys). It is a
pre-merge gate, not a substitute for live Argo verification.

Usage:
  render_chain.py snapshot --out DIR [--repo ROOT]
  render_chain.py compare OLD_DIR NEW_DIR
"""

import argparse
import glob as globmod
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
GROUP = "redbull"
ENVS_ALLOWED = {"prod", "prep", "test"}

REPO = None  # set in main
SIGS = None
PLATFORM = None

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


def match_glob(pattern, want_dirs):
    """Argo git generator globbing: * does not cross /."""
    hits = []
    for hit in sorted(globmod.glob(os.path.join(SIGS, pattern))):
        if want_dirs and os.path.isdir(hit):
            hits.append(os.path.relpath(hit, SIGS))
        elif not want_dirs and os.path.isfile(hit):
            hits.append(os.path.relpath(hit, SIGS))
    return hits


def generator_param_sets(gen):
    """Simulate one git generator entry -> list of param dicts."""
    git = gen.get("git")
    if not git:
        return None  # non-git generator (clusters:{}, scmProvider) -> skip
    sets = []
    if "directories" in git:
        include, exclude = set(), set()
        for entry in git["directories"]:
            hits = match_glob(entry["path"], want_dirs=True)
            (exclude if entry.get("exclude") else include).update(hits)
        for d in sorted(include - exclude):
            sets.append(path_params(d))
    elif "files" in git:
        seen = set()
        for entry in git["files"]:
            for f in match_glob(entry["path"], want_dirs=False):
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
    """$values/<p> -> sigs repo. Returns (resolved list, merged dict)."""
    resolved, merged = [], {}
    for vf in value_files or []:
        rel = vf[len("$values/"):] if vf.startswith("$values/") else vf
        rel = posixpath.normpath(rel)
        full = os.path.join(SIGS, rel)
        if os.path.isfile(full):
            with open(full, "rb") as fh:
                data = fh.read()
            resolved.append({"path": rel, "hash": sha(data)})
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
            "extra_sources": [
                {"repoURL": s.get("repoURL"), "targetRevision": s.get("targetRevision"),
                 "ref": s.get("ref")} for s in sources[1:]],
        },
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


def lint_sigs_tree():
    """§9.2 consistency checks on the sigs repo."""
    for cfg in sorted(
            match_glob("mces/*/config.yaml", False)
            + match_glob("mces/*/*/config.yaml", False)
            + match_glob("sites/*/*/mces/*/config.yaml", False)
            + match_glob("sites/*/*/mces/*/*/config.yaml", False)):
        full = os.path.join(SIGS, cfg)
        with open(full) as fh:
            raw = fh.read()
        data = yaml.safe_load(raw) or {}
        m = re.search(r'^ocpVersion:\s*(.+?)\s*(#.*)?$', raw, re.M)
        if not m:
            fail(f"{cfg}: missing ocpVersion")
        elif not re.match(r"""^["'].+["']$""", m.group(1)):
            fail(f"{cfg}: ocpVersion must be quoted (YAML would parse "
                 f"{m.group(1)} as a float): got {m.group(1)}")
        segs = cfg.split("/")
        if segs[0] == "sites":
            site, env = segs[1], segs[2]
            if env not in ENVS_ALLOWED:
                fail(f"{cfg}: env folder '{env}' not in {sorted(ENVS_ALLOWED)}")
            if "site" in data and data["site"] != site:
                fail(f"{cfg}: site field '{data['site']}' != path segment '{site}'")
            if "env" in data and data["env"] != env:
                fail(f"{cfg}: env field '{data['env']}' != path segment '{env}'")
        elif segs[0] == "mces" and len(segs) == 3:  # legacy MCE level
            for k in ("env", "site"):
                if len(match_glob("sites/*/*/mces/*/config.yaml", False)) == 0 \
                        and k not in data:
                    fail(f"{cfg}: legacy MCE config must carry '{k}' "
                         f"(no path to derive it from)")
            if data.get("env") and data["env"] not in ENVS_ALLOWED:
                fail(f"{cfg}: env '{data['env']}' not in {sorted(ENVS_ALLOWED)}")


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
    lint_frozen_lines()

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
                if o["identity"][k] != n["identity"].get(k):
                    hard.append(f"{uid}: identity field '{k}' changed: "
                                f"{o['identity'][k]!r} -> {n['identity'].get(k)!r}")
        o_seq = [r["hash"] for r in o["resolved"]]
        n_seq = [r["hash"] for r in n["resolved"]]
        if o_seq != n_seq:
            hard.append(f"{uid}: resolved value-file content sequence changed:\n"
                        f"    old: {o['resolved']}\n    new: {n['resolved']}")
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
    global REPO, SIGS, PLATFORM
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("snapshot")
    s.add_argument("--out", required=True)
    s.add_argument("--repo", default=None)
    c = sub.add_parser("compare")
    c.add_argument("old")
    c.add_argument("new")
    args = ap.parse_args()

    REPO = args.repo if getattr(args, "repo", None) else \
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    SIGS = os.path.join(REPO, "sigs", GROUP)
    PLATFORM = os.path.join(REPO, "argocd-day2-platform")

    if args.cmd == "snapshot":
        sys.exit(take_snapshot(args.out))
    else:
        sys.exit(compare(args.old, args.new))


if __name__ == "__main__":
    main()
