# APPLY-UPI — UPI clusters as a fourth destination kind

Standalone apply guide for one additive change. Day2 today deploys to three
kinds of destination: prod-hub, MCE hubs and hosted clusters. This adds a
fourth, **UPI clusters**: standalone OpenShift clusters that are already
provisioned, sit under no MCE and run no Argo of their own. Every team gets
them through the same single `groups` configuration, with the same site/env
value layers and a new `defaults/upi/` fleet layer.

**Two Argo instances, one entry point.** The hub cluster runs two OpenShift
GitOps instances. Instance A (`openshift-gitops`) runs the day2 `groups`
appset. Instance B (`openshift-gitops-upi`) holds every UPI cluster secret and
keeps deploying the charts to UPI clusters. A hands over to B exactly the way
it hands over to an MCE's Argo today: one small wrapper app per UPI cluster
per team on A writes the `operators` ApplicationSet into B's namespace, and B
does everything below it with the cluster secrets it already has. No cluster
secret is copied anywhere.

```
instance A (openshift-gitops)                         instance B (openshift-gitops-upi)
groups → <team> → mces chart
   ├─ <team>-mces            → each MCE's Argo       (unchanged)
   ├─ <team>-in-cluster      → hub charts            (unchanged)
   ├─ <team>-app-projects    → AppProject per A cluster (unchanged)
   ├─ <team>-upi-app-project   NEW, static  ───────▶ AppProject <team>
   └─ <team>-upi               NEW appset, sites/*/*/upi/*
        └─ <team>-<cluster>    wrapper      ───────▶ ApplicationSet <team>-<cluster>-operators
                                                        └─ <team>-<cluster>-<chart>
                                                             └─ <team>-<cluster>-<chart>-deploy
                                                                  → destination.name: <cluster>
```

**What a team writes in its sigs repo:**

```
sites/<site>/<env>/
├── mces/…                          # unchanged
└── upi/                            # NEW sibling of mces/
    ├── values.yaml                 # optional: every UPI cluster at this site+env
    └── <cluster>/                  # THE FOLDER IS THE UPI CLUSTER (name == cluster secret name on B)
        ├── version.yaml            # optional: `mastertag: 4.16.27-x86_64`, nothing else
        ├── values.yaml             # optional: cluster-wide values
        └── <chart>/{<chart>.yaml, values.yaml}
defaults/upi/                       # NEW fleet layer: every UPI cluster of the team
```

**The day1 repo is not touched.** day1 manages MCEs and hosted clusters only.
A UPI cluster's OCP version is optional and lives in its own sigs folder.
Without `version.yaml` the cluster is version-less like prod-hub: no
`ocp-versions/<v>/` pins and no `ocp-version` label.

**This version is for a platform repo without Phase F and without `tools/`**,
which is the air-gap's state: `APPLY-EXCLUSIONS.md` (the structural opt-out,
`exclusions.yaml`) is not applied, and there is no render harness. The mock
repo does carry Phase F, so §4.1 and §4.3 are the mock's change with every
exclusions line taken out. All of §4 was applied to a copy of the mock with
Phase F removed and render-verified there (§7.4). Every offline check below
needs only `git` and `helm` (§5). For a platform that has Phase F, use the
earlier version of this guide: `git show 32b36c6:APPLY-UPI.md`.

> `<platform>` below is an `argocd-day2-platform` checkout, `<sigs>` a
> `sigs/<team>` checkout, `<day1>` a `gitops-day1/platform-config` checkout.
> `<GITLAB>` is your GitLab host. `<team>` is a sigs repo name, which is also
> the team's group value and its Argo project name. The two instances are
> called **A** (`openshift-gitops`) and **B** (`openshift-gitops-upi`).

---

## 1. Before you start — checks to run in the air-gap

Run every check before you change anything. Each one says what to run, what a
good result looks like, and what to do otherwise. **Do not start §3 until all
eleven are green or have their fix applied.** Checks 5 to 9 are the ones this
repo cannot answer for you.

### 1.1 Repos

**Check 1 — confirm the checkout is the one this guide is written for.** UPI
builds on the end state of `CHANGES.md` (Phases A→E) and
`APPLY-OCP-VERSIONS.md`, **without** `APPLY-EXCLUSIONS.md` (Phase F). The §4
patches use that state as context and will not apply to anything else.

```bash
cd <platform>
grep -c 'sites/\*/\*/mces/\*' mces/templates/mcesAppset.yaml            # -> 1   (sites/ tree live)
grep -c 'ocp-versions/' deploy/templates/deployApp.yaml                 # -> 1   (rename applied)
grep -cF 'ocp-versions/{{ $ocpVersion }}/' operators/templates/operators.yaml   # -> 1   (rename applied: the valueFiles line)
grep -cF 'ocp-versions/<v>/ folder created' operators/templates/operators.yaml  # -> 1   (the preamble comment)
grep -c 'Values.exclusions' operators/templates/operators.yaml          # -> 0   (Phase F not applied)
grep -c 'ref: values' clusters/templates/inClusterApp.yaml              # -> 0   (Phase F not applied)
grep -c 'argoNamespace' operators/templates/operators.yaml deploy/templates/deployApp.yaml
                                                                        # -> 0 and 0 (this guide not applied yet)
ls mces/templates/upiAppset.yaml                                        # -> No such file
```

| Output | What it means | What to do |
|---|---|---|
| all as shown | the expected state | continue |
| the first, second or third is `0` | this is not the migrated platform repo: an old clone, or a branch cut before the migration | switch to the migrated `main` and re-run |
| only the preamble-comment line is `0` | the rename landed on the live line, but the comment still has the old wording (`APPLY-OCP-VERSIONS.md` §3.2 is comment-only, so nothing caught it). Rendering is fine. The first hunk of §4.3 uses that comment line as context, so `git apply --check` will reject it | run `grep -n 'folder created' operators/templates/operators.yaml` and make that line read exactly `     operators/<chart>/ocp-versions/<v>/ folder created BEFORE day1 flips the`, then re-run |
| `Values.exclusions` or `ref: values` is `1` | Phase F is applied, fully or partly. §4.3 below will not apply | both `1`: use the Phase F version of this guide, `git show 32b36c6:APPLY-UPI.md`. Only one: F is half-applied; finish or revert it (`APPLY-EXCLUSIONS.md` F.1–F.3) first |
| `argoNamespace` non-zero, or the file exists | this guide was already (partly) applied | compare with §4 file by file |

**Check 2 — the offline render check can run.** The air-gap has no `tools/`
render harness. §5 replaces it with a short script that renders the platform
charts with `helm template`, once from `origin/main` and once from your branch,
and compares the two. It needs:

```bash
helm version --short                          # -> v3.x or later
cd <platform> && git fetch && git rev-parse origin/main   # -> a commit hash
```

### 1.2 Instance B

**Check 3 — B's namespace is `openshift-gitops-upi`.** The platform hardcodes
that string in two templates.

```bash
oc get argocd -A                                   # -> a row in namespace openshift-gitops-upi
oc get applicationsets -n openshift-gitops-upi     # -> the gitops-upi appsets are listed here
```

If B's ArgoCD CR lives in a different namespace, or B reconciles its apps from
somewhere else, replace the string `openshift-gitops-upi` in
`mces/templates/upiAppset.yaml` and `mces/templates/upiAppProjectApp.yaml`
before you merge (§4.1, §4.2). Nothing else carries it.

**Check 4 — B's ApplicationSet controller runs and supports multi-source apps.**

```bash
oc get pods -n openshift-gitops-upi | grep applicationset-controller   # -> Running
```

The gitops-upi appsets already use `sources:` with `ref: values`. If their
apps sync today, B's version is new enough for the day2 apps too.

**Check 5 — instance A may write into B's namespace.** A's wrapper app creates
an ApplicationSet there, and the static app creates an AppProject there.

```bash
SA=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
oc auth can-i create applicationsets.argoproj.io -n openshift-gitops-upi --as $SA   # -> yes
oc auth can-i patch  applicationsets.argoproj.io -n openshift-gitops-upi --as $SA   # -> yes
oc auth can-i create appprojects.argoproj.io     -n openshift-gitops-upi --as $SA   # -> yes
oc auth can-i patch  appprojects.argoproj.io     -n openshift-gitops-upi --as $SA   # -> yes
```

If your A controller runs under a different service account name, use that
one (`oc get sa -n openshift-gitops | grep application-controller`). If any
answer is `no`, apply this before §3. It deliberately has no `delete` verb:
nothing in the chain prunes.

If the migration delete guard rail is still bound to this controller, its
first rule already grants these verbs on every resource, so the answers are
`yes`. UPI never needs `delete`, so the guard rail neither blocks this change
nor needs touching for it. Lifting it is its own procedure (the guard-rail
runbook, "Lift").

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: day2-hub-writes-upi
  namespace: openshift-gitops-upi
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applicationsets", "appprojects"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: day2-hub-writes-upi
  namespace: openshift-gitops-upi
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: day2-hub-writes-upi
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
```

### 1.3 AppProjects and credentials

**Check 6 — the AppProjects on A allow the two new apps.**

```bash
oc get appproject <team>  -n openshift-gitops -o yaml   # used by the <team>-<cluster> wrappers
oc get appproject default -n openshift-gitops -o yaml   # used by <team>-upi-app-project
```

| Project | Must allow |
|---|---|
| `<team>` on A | destination `in-cluster` (server `https://kubernetes.default.svc`) with namespace `openshift-gitops-upi`; the `argoproj.io/ApplicationSet` kind if the project whitelists namespaced kinds; the platform and sigs repos as sources (already true today) |
| `default` on A | destination `in-cluster` / `openshift-gitops-upi`; the `helm-charts/argo-appproject` repo as a source (the existing `<team>-app-projects-*` apps already use it). Its `sourceNamespaces` may stay empty: `<team>-upi-app-project` lives in `openshift-gitops`, A's own namespace, like the `<team>-app-projects-*` apps |

A destination of `*` / `*` satisfies both. If `<team>` is too narrow, widen it
in the external `argo-appproject` chart (check 7), since that chart defines it.

**Check 7 — the external `argo-appproject` chart suits instance B.** This is
the Helm chart at `<GITLAB>/redbull/helm-charts/argo-appproject.git` that
creates each team's AppProject; day2 passes it only `group: <team>`. Today it
runs once per cluster registered on A. The new `<team>-upi-app-project` app
runs it once more, into B's namespace on the hub cluster, and passes
`createNamespace: false`.

The chart as it stood before UPI (no `values.yaml`; `templates/namespace.yaml`
with Namespace `gitops-<group>`; `templates/appProject.yaml` with a hardcoded
`namespace: openshift-gitops`) needs one small MR of its own, merged **before**
§4. Confirm it has landed:

1. **The Namespace can be switched off.** On prod-hub, `gitops-<team>` already
   belongs to `<team>-app-projects-in-cluster`; a second app rendering it would
   fight over it. The chart needs `values.yaml` with `createNamespace: true`
   and `{{- if .Values.createNamespace }}` around `namespace.yaml`. Keep the
   default in `values.yaml`: `default true` in the template would turn an
   explicit `false` back into `true`, and no default at all would drop the
   Namespace from every existing app.
2. **The AppProject lands in the release namespace:**
   `namespace: {{ .Release.Namespace }}` instead of `openshift-gitops`. Argo
   renders with the app's destination namespace, which is `openshift-gitops`
   for every existing `<team>-app-projects-<cluster>` app, so their output does
   not change.

   ```bash
   cd argo-appproject
   helm template t . --namespace openshift-gitops --set group=<team>
   #   -> Namespace gitops-<team> + AppProject in openshift-gitops, same as before the MR
   helm template t . --namespace openshift-gitops-upi --set group=<team> --set createNamespace=false
   #   -> ONE object: AppProject <team> in openshift-gitops-upi
   ```

   After the chart MR, every `<team>-app-projects-*` app on A stays Synced with
   no diff.
3. **The AppProject allows what B needs:**
   - destinations `in-cluster` / `openshift-gitops-upi` (the chart apps write
     their leaf Applications there) and the UPI clusters by name, in any
     workload namespace (the leaves);
   - sources: the platform repo, the sigs repos, and the chart repos your
     `<chart>.yaml` files point at;
   - the kinds your charts create. MCEs and hosted clusters already need the
     same, so a project that works there usually works here.

**Check 8 — B can read the day2 repos.** B's ApplicationSet controller now
reads the sigs repos, its chart apps render the platform repo, and its leaves
read the chart repos.

```bash
for t in repo-creds repository; do
  oc get secret -n openshift-gitops-upi -l argocd.argoproj.io/secret-type=$t \
    -o json | jq -r '.items[].data.url | @base64d'
done
# -> URLs or prefixes covering <GITLAB>/redbull/gitops-day2-prod/ (platform + sigs)
#    and every chart repo prefix your teams use
```

Compare with the same command against `-n openshift-gitops` on A. A missing
prefix is fixed by copying A's matching `repo-creds` secret into
`openshift-gitops-upi`. Note that a `repository` secret matches one exact URL
and a `repo-creds` secret a whole prefix.

### 1.4 Cluster names and coexistence

**Check 9 — the folder names you plan to create equal B's cluster names.**

```bash
oc get secret -n openshift-gitops-upi -l argocd.argoproj.io/secret-type=cluster \
  -o json | jq -r '.items[].data.name | @base64d' | sort
```

Every leaf app targets `destination.name: <folder name>`, resolved by B. Name
each folder after an existing secret, never the reverse. A name that is not in
this list gives an app that errors and deploys nothing. Also check that no UPI
cluster shares a name with an MCE or a hosted cluster of any of the five teams.
Nothing checks this offline. An MCE name is the worst case: the UPI wrapper
and that MCE's app on A would both be named `<team>-<name>`.

**Check 10 — no day2 name is already taken in B's namespace.**

```bash
oc get applications,applicationsets -n openshift-gitops-upi -o name
```

Day2 will create, per team and cluster, `<team>-<cluster>-operators`
(ApplicationSet), `<team>-<cluster>-<chart>` and
`<team>-<cluster>-<chart>-deploy`, and the AppProject `<team>`. None of the
listed names may start with `<team>-` for any of the five team names.

**Check 11 — plan the handover from gitops-upi, per cluster and chart.**
gitops-upi and day2 now both run on instance B. If both deploy the same chart
to the same cluster, two Applications with the same `releaseName` and
namespace fight over one release. For every UPI cluster, list the charts
gitops-upi deploys there. A chart may be added to a sigs repo for that cluster
only after it is gone from gitops-upi.

---

## 2. Why this is safe

**Nothing that exists today renders differently.** Every new template branch
sits behind `.Values.upi`, which no existing app sets, or behind a default
equal to today's string (`argoNamespace` defaults to `gitops-<team>`). In the
mock with Phase F removed, all 35 existing Applications and all 12 existing
ApplicationSets have a byte-identical spec after the change (§7.4). §5 checks
the same property on your own templates.

**The new generator cannot match an existing folder.** Discovery uses
`directories:` globs, where `*` matches exactly one path segment:

| Chart | Generator paths |
|---|---|
| `mces/mcesAppset.yaml` | `sites/*/*/mces/*` |
| **`mces/upiAppset.yaml` (new)** | **`sites/*/*/upi/*`** |
| `clusters/clustersAppset.yaml` | `<mcePath>/*`, `<mcePath>/in-cluster` |
| `operators/operators.yaml` | `<clusterPath>/*`, and one of `defaults/mces/*`, **`defaults/upi/*` (new)**, `defaults/hosted-clusters/*` |
| `mces/inClusterAppset.yaml` | `defaults/hub/*` |

The literal `mces` and `upi` segments keep the two cluster globs apart.

**Until a team creates a `upi/` folder, the only new objects are two per
team:** the empty `<team>-upi` ApplicationSet (zero apps) and the
`<team>-upi-app-project` app with its AppProject in B's namespace.

**Nothing is ever deleted.** Every new app is `prune: false` with no
resources-finalizer, like the rest of the chain.

---

## 3. Order of work and gates

| Step | What | Gate before the next step |
|---|---|---|
| a | §1, all eleven checks, including check 7's `argo-appproject` chart MR | all green, or their fix applied. The chart MR is merged and every `<team>-app-projects-*` app on A is still Synced with no diff |
| b | §4 platform patches, one MR in `<platform>` | **before merge**: §5 prints `RESULT: PASS` and the §10 greps match. **after merge**: §7.1 — `<team>-upi-app-project` is Synced/Healthy in `openshift-gitops` on A for every team, and `oc get appprojects -n openshift-gitops-upi` lists one AppProject per team |
| c | §6.1 `defaults/upi/README.md` in each sigs repo (optional, docs only) | none: a plain file, no generator reads it |
| d | §6.2 the first UPI cluster folder, in one team's repo | **before merge**: the §6.2 review list. **after merge**: §7.2 and §7.3 |
| e | more clusters, more teams | the same gates per MR |

**Rollback.**

- **Step b:** revert the MR. The `<team>` app that renders the `mces` chart has
  `prune: false`, so the two new objects stay behind, inert. Remove them by
  hand: `oc delete applicationset <team>-upi -n gitops-<team>` (it has no apps
  before step d) and `oc delete application <team>-upi-app-project -n
  openshift-gitops`, then optionally the AppProject `<team>` in
  `openshift-gitops-upi`. The operators and deploy changes need no cleanup:
  they render byte-identically for every existing app.
- **Step d:** delete the folder, then follow §8.

---

## 4. Platform repo — `argocd-day2-platform`

Two new files and two edited ones. Every block below is a unified diff with
paths relative to the platform repo root. §4.2 and §4.4 are the mock's change
verbatim. §4.1 and §4.3 are the mock's change without Phase F: no
`defaults/upi/exclusions.yaml` valueFile, and no `$exclusions`, `$excluded`,
`$isMce` or `$exKey` lines. One substitution throughout: the GitLab host in
`repoURL:` lines is written `<GITLAB>`. No context line contains the host, so
only added lines carry it.

To apply by patch, save each block to a file in `<platform>`, put your real
host in, then check and apply:

```bash
HOST=$(grep -m1 -o 'https://[^/]*' mces/templates/mcesAppset.yaml | cut -d/ -f3)
sed -i "s#<GITLAB>#$HOST#g" upi-*.patch        # macOS: sed -i '' ...
git apply --check upi-*.patch && git apply upi-*.patch
```

If `git apply --check` rejects an edit hunk, your file differs from the mock
around it. Apply that hunk by hand: each one is small and self-describing.

### 4.1 `mces/templates/upiAppset.yaml` — new

UPI cluster discovery, and the handover to instance B. Its destination is
`in-cluster` with namespace `openshift-gitops-upi`: that is the hop by
namespace that replaces the MCE hop by cluster.

```diff
--- /dev/null
+++ b/mces/templates/upiAppset.yaml
@@ -0,0 +1,87 @@
+apiVersion: argoproj.io/v1alpha1
+kind: ApplicationSet
+metadata:
+  name: {{ .Values.group }}-upi
+  namespace: gitops-{{ .Values.group }}
+spec:
+  generators:
+    - git:
+        repoURL: 'https://gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+        revision: main
+        # A UPI cluster is a FOLDER under sites/<site>/<env>/upi/ — a sibling of
+        # mces/ at the same depth, so path[1] = site and path[2] = env mean
+        # exactly what they mean in mcesAppset. It is NOT under an MCE: a UPI
+        # cluster is standalone, with no MCE and no Argo of its own.
+        #
+        # directories: globs are matched with Go path.Match, where '*' matches
+        # exactly ONE path segment. Depth-exact by the engine: this can never
+        # reach a chart folder one level down, and the optional
+        # sites/<site>/<env>/upi/values.yaml (the UPI-wide value slot) is a
+        # file, which a directories: generator never sees. mcesAppset's
+        # sites/*/*/mces/* has a literal `mces` segment, so the two globs can
+        # never match the same folder.
+        #
+        # Folder existence is the opt-in — no marker file. git cannot track an
+        # empty folder: a cluster onboarded before it has any content needs a
+        # .gitkeep to exist here at all. There is NO day1 parity check for UPI
+        # clusters (day1 does not know them), so a stray folder here becomes a
+        # phantom app aimed at a cluster that does not exist. Nothing catches
+        # that offline: check every new folder name against B's cluster secrets.
+        directories:
+          - path: "sites/*/*/upi/*"
+  template:
+    metadata:
+      name: '{{ .Values.group }}-{{ "{{" }}path.basename{{ "}}" }}'
+      labels:
+        day2.gitops/team: '{{ .Values.group }}'
+        day2.gitops/env: '{{ "{{" }}path[2]{{ "}}" }}'
+        day2.gitops/site: '{{ "{{" }}path[1]{{ "}}" }}'
+        day2.gitops/cluster: '{{ "{{" }}path.basename{{ "}}" }}'
+        # No mce label: there is no MCE. No ocp-version label: this is a
+        # discovery layer — it only points the operators chart at the
+        # (optional) version file.
+        day2.gitops/role: upi
+    spec:
+      project: '{{ .Values.group }}'
+      sources:
+        - repoURL: 'https://gitlab[REDACTED]/redbull/gitops-day2-prod/argocd-day2-platform.git'
+          targetRevision: main
+          path: operators
+          helm:
+            ignoreMissingValueFiles: true
+            valueFiles:
+              # The UPI cluster's OCP version, OPTIONAL. day1 provisions hosted
+              # clusters only, so a UPI cluster declares its own version in its
+              # own folder: `mastertag` and nothing else (any other key lands as
+              # a chart value). Absent -> the cluster is version-less like
+              # prod-hub: no ocp-versions/<v>/ layers, no ocp-version label.
+              - '$values/{{ "{{" }}path{{ "}}" }}/version.yaml'
+            # argoNamespace is where the operators ApplicationSet and every app
+            # below it are created: the namespace instance B (the UPI Argo)
+            # reconciles. The same string is in upiAppProjectApp.yaml.
+            values: |
+              group: '{{ .Values.group }}'
+              cluster: '{{ "{{" }}path.basename{{ "}}" }}'
+              clusterPath: '{{ "{{" }}path{{ "}}" }}'
+              upiPath: 'sites/{{ "{{" }}path[1]{{ "}}" }}/{{ "{{" }}path[2]{{ "}}" }}/upi'
+              env: '{{ "{{" }}path[2]{{ "}}" }}'
+              site: '{{ "{{" }}path[1]{{ "}}" }}'
+              upi: true
+              argoNamespace: openshift-gitops-upi
+        - repoURL: 'https://gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+          targetRevision: main
+          ref: values
+      # THE HANDOVER. This app lives on instance A (openshift-gitops), next to
+      # the per-MCE apps, but writes the operators chart into the namespace
+      # instance B (openshift-gitops-upi) reconciles — the same move
+      # mcesAppset makes onto an MCE's Argo, except B runs on this same
+      # cluster, so the hop is by namespace, not by cluster. B then generates
+      # the chart apps and leaves and syncs them to the UPI cluster with the
+      # cluster secret it already holds; A never needs one.
+      destination:
+        name: in-cluster
+        namespace: openshift-gitops-upi
+      syncPolicy:
+        automated:
+          selfHeal: true
+          prune: false
```

### 4.2 `mces/templates/upiAppProjectApp.yaml` — new

Plants AppProject `<team>` into B's namespace, because every app handed to B
uses `project: <team>`. It is rendered for every team, whether or not the team
has UPI clusters: Helm cannot see folders.

```diff
--- /dev/null
+++ b/mces/templates/upiAppProjectApp.yaml
@@ -0,0 +1,46 @@
+{{- /* Plants AppProject <group> into the namespace instance B (the UPI Argo,
+     openshift-gitops-upi) reconciles, because every app upiAppset hands over
+     to B references `project: <group>`. The prod-hub counterpart is
+     appProjectAppset (clusters: {} over instance A's cluster secrets), which
+     cannot reach B: B is not a cluster secret on A, it is another Argo on the
+     same cluster. Same external chart, same single value, so the team's policy
+     is one definition on both instances.
+
+     Rendered for EVERY team, unconditionally: Helm cannot see whether a team
+     has UPI folders. A team without any gets one inert AppProject in B.
+     The namespace string is also in upiAppset.yaml. */ -}}
+apiVersion: argoproj.io/v1alpha1
+kind: Application
+metadata:
+  name: {{ .Values.group }}-upi-app-project
+  # openshift-gitops, not gitops-<group>: this app uses project `default`, and
+  # Argo admits an app outside its own namespace only if the project's
+  # spec.sourceNamespaces matches it. prod-hub's `default` has none. Same
+  # namespace and project as appProjectAppset's apps, which do the same job.
+  namespace: openshift-gitops
+  annotations:
+    argocd.argoproj.io/sync-wave: "-1"
+  labels:
+    # team only: this is plumbing, not an app for a UPI cluster, so it stays
+    # out of `day2.gitops/role=upi` selectors (like the app-projects apps).
+    day2.gitops/team: '{{ .Values.group }}'
+spec:
+  project: default
+  source:
+    repoURL: 'https://<GITLAB>/redbull/helm-charts/argo-appproject.git'
+    path: .
+    targetRevision: main
+    helm:
+      ignoreMissingValueFiles: true
+      # AppProject only: gitops-<group> already exists on prod-hub and belongs
+      # to <group>-app-projects-in-cluster.
+      values: |
+        group: '{{ .Values.group }}'
+        createNamespace: false
+  destination:
+    name: in-cluster
+    namespace: openshift-gitops-upi
+  syncPolicy:
+    automated:
+      selfHeal: true
+      prune: false
```

### 4.3 `operators/templates/operators.yaml`

Six changes, all inert for existing renders:

- **Version:** `mastertag` stays `required` for every destination except a
  UPI cluster, which may be version-less. Every version-dependent line is
  guarded.
- **`$argoNs`:** the namespace of the ApplicationSet and of every app it
  generates. It defaults to `gitops-<team>`, so today's output is unchanged.
- **`$role`:** three kinds, built with if/else on `eq .Values.cluster
  "in-cluster"` and `.Values.upi`. `ternary` on the nil `.Values.upi` would
  abort every existing render.
- **Generator:** a `defaults/upi/*` branch, placed **before** the
  hosted-cluster branch, which would otherwise catch every non-MCE destination.
- **Labels and inline values:** `mce` only when set, and `upi`, `upiPath` and
  `argoNamespace` passed down only for UPI.
- **Config stack:** `defaults/upi/<c>/<c>.yaml` as the UPI defaults layer.

Without Phase F there is no exclusions code: the new `defaults/upi/*`
generator has no `exclude:` entries, like the two existing ones.

```diff
--- a/operators/templates/operators.yaml
+++ b/operators/templates/operators.yaml
@@ -3,18 +3,42 @@
                            (sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml)
        the MCE itself   -> passed inline by inClusterApp, from the MCE's day1
                            version.yaml (day2-owned; day1 never reads it)
+       UPI clusters     -> OPTIONAL, from this Application's own $values file
+                           sites/<site>/<env>/upi/<cluster>/version.yaml
+                           (upiAppset; day1 does not know UPI clusters)
      One derivation either way: strip the arch at the first '-' and use the
      rest verbatim (4.16.27-x86_64 -> 4.16.27). Version-pin layers are keyed
      by that exact version, so EVERY upgrade — z-streams included — needs its
      operators/<chart>/ocp-versions/<v>/ folder created BEFORE day1 flips the
-     tag, or a pinned chart silently falls back to the team default. */ -}}
-{{- $mastertag := required "mastertag missing: no day1 platform-config entry for this destination" .Values.mastertag | toString -}}
+     tag, or a pinned chart silently falls back to the team default.
+     Only a UPI cluster may lack a tag: it is then version-less like prod-hub,
+     $ocpVersion is "" and every version-dependent line below is skipped.
+     Every other destination still REQUIRES one. */ -}}
+{{- $mastertag := "" -}}
+{{- if or (not .Values.upi) .Values.mastertag -}}
+{{-   $mastertag = required "mastertag missing: no day1 platform-config entry for this destination" .Values.mastertag | toString -}}
+{{- end -}}
 {{- $ocpVersion := $mastertag | splitList "-" | first -}}
+{{- /* The namespace this ApplicationSet and every app below it live in, i.e.
+     which Argo instance reconciles them. Default: the team namespace on the
+     Argo that rendered this chart (an MCE's, for MCE hubs and hosted
+     clusters). UPI: upiAppset passes openshift-gitops-upi, the namespace the
+     UPI Argo instance reconciles on the hub cluster. */ -}}
+{{- $argoNs := .Values.argoNamespace | default (printf "gitops-%s" .Values.group) -}}
+{{- /* Three destination kinds, one template. if/else, NOT a ternary:
+     .Values.upi is nil on every MCE and hosted-cluster render, and sprig's
+     ternary requires a real bool — a nil there aborts the render. */ -}}
+{{- $role := "hosted-cluster" -}}
+{{- if eq .Values.cluster "in-cluster" -}}
+{{-   $role = "mce" -}}
+{{- else if .Values.upi -}}
+{{-   $role = "upi" -}}
+{{- end -}}
 apiVersion: argoproj.io/v1alpha1
 kind: ApplicationSet
 metadata:
   name: {{ .Values.group }}-{{ .Values.cluster }}-operators
-  namespace: gitops-{{ .Values.group }}
+  namespace: {{ $argoNs }}
 spec:
   generators:
     - git:
@@ -28,6 +52,15 @@ spec:
         revision: main
         directories:
           - path: "defaults/mces/*"
+    {{- else if .Values.upi }}
+    # Fleet defaults for UPI clusters: every chart folder here is deployed to
+    # every UPI cluster of the team. Checked BEFORE the hosted-cluster branch
+    # below, which would otherwise catch every non-MCE destination.
+    - git:
+        repoURL: 'https://gitlab[REDACTED]/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+        revision: main
+        directories:
+          - path: "defaults/upi/*"
     {{- else if not .Values.hub }}
     # Fleet defaults for hosted clusters: every chart folder here is deployed
     # to every hosted cluster of the team (mirror of the defaults/mces
@@ -45,11 +78,15 @@ spec:
         day2.gitops/team: '{{ .Values.group }}'
         day2.gitops/env: '{{ .Values.env }}'
         day2.gitops/site: '{{ .Values.site }}'
+        {{- if .Values.mce }}
         day2.gitops/mce: '{{ .Values.mce }}'
+        {{- end }}
         day2.gitops/cluster: '{{ .Values.cluster }}'
         day2.gitops/chart: '{{ "{{" }}path.basename{{ "}}" }}'
+        {{- if $ocpVersion }}
         day2.gitops/ocp-version: '{{ $ocpVersion }}'
-        day2.gitops/role: {{ eq .Values.cluster "in-cluster" | ternary "mce" "hosted-cluster" }}
+        {{- end }}
+        day2.gitops/role: {{ $role }}
     spec:
       project: '{{ .Values.group }}'
       sources:
@@ -60,23 +97,36 @@ spec:
             ignoreMissingValueFiles: true
             values: |
               group: '{{ .Values.group }}'
+              {{- if .Values.mce }}
               mce: {{ .Values.mce }}
               mcePath: {{ .Values.mcePath }}
+              {{- end }}
               cluster: {{ .Values.cluster }}
               clusterPath: {{ .Values.clusterPath }}
               env: {{ .Values.env }}
               site: {{ .Values.site }}
+              {{- if $ocpVersion }}
               ocpVersion: '{{ $ocpVersion }}'
+              {{- end }}
               operator: {{ "{{" }}path.basename{{ "}}" }}
+              {{- if .Values.upi }}
+              upi: true
+              upiPath: {{ .Values.upiPath }}
+              argoNamespace: {{ $argoNs }}
+              {{- end }}
             # Deploy-config stack, lowest -> highest: team default, per-OCP-version
             # pin (selected by the destination's own version, from day1), fleet
             # defaults, the cluster's own folder. All optional
             # (ignoreMissingValueFiles).
             valueFiles:
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              {{- if $ocpVersion }}
               - '$values/operators/{{ "{{" }}path.basename{{ "}}" }}/ocp-versions/{{ $ocpVersion }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              {{- end }}
               {{- if eq .Values.cluster "in-cluster" }}
               - '$values/defaults/mces/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
+              {{- else if .Values.upi }}
+              - '$values/defaults/upi/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- else }}
               - '$values/defaults/hosted-clusters/{{ "{{" }}path.basename{{ "}}" }}/{{ "{{" }}path.basename{{ "}}" }}.yaml'
               {{- end }}
@@ -86,7 +136,7 @@ spec:
           targetRevision: main
       destination:
         name: in-cluster
-        namespace: gitops-{{ .Values.group }}
+        namespace: {{ $argoNs }}
       syncPolicy:
         automated:
           selfHeal: true
```

### 4.4 `deploy/templates/deployApp.yaml`

The leaf. Its namespace follows `argoNamespace`, which puts UPI leaves in B's
namespace. The labels and the workload stack gain the UPI branch. The
`<mcePath>/values.yaml` slot becomes `sites/<site>/<env>/upi/values.yaml` for
UPI, written as a guarded pair: an empty path would render
`$values//values.yaml`, which is the sigs repo root. The hub branch, including
the hub-wide `defaults/hub/values.yaml` line if you have it, is outside every
hunk.

```diff
--- a/deploy/templates/deployApp.yaml
+++ b/deploy/templates/deployApp.yaml
@@ -6,7 +6,10 @@
   {{- else }}
   name: {{ .Values.group }}-{{ .Values.cluster }}-{{ .Values.operator }}-deploy
   {{- end }}
-  namespace: gitops-{{ .Values.group }}
+  # Which Argo instance holds this leaf. Default: the team namespace on the
+  # Argo that rendered it. UPI: openshift-gitops-upi, passed down from
+  # upiAppset through the operators chart.
+  namespace: {{ .Values.argoNamespace | default (printf "gitops-%s" .Values.group) }}
   labels:
     day2.gitops/team: '{{ .Values.group }}'
     day2.gitops/chart: '{{ .Values.operator }}'
@@ -15,11 +18,21 @@
     {{- else }}
     day2.gitops/env: '{{ .Values.env }}'
     day2.gitops/site: '{{ .Values.site }}'
+    {{- if .Values.mce }}
     day2.gitops/mce: '{{ .Values.mce }}'
+    {{- end }}
     day2.gitops/cluster: '{{ .Values.cluster }}'
+    {{- if .Values.ocpVersion }}
     day2.gitops/ocp-version: '{{ .Values.ocpVersion }}'
-    day2.gitops/role: {{ eq .Values.cluster "in-cluster" | ternary "mce" "hosted-cluster" }}
     {{- end }}
+    {{- if eq .Values.cluster "in-cluster" }}
+    day2.gitops/role: mce
+    {{- else if .Values.upi }}
+    day2.gitops/role: upi
+    {{- else }}
+    day2.gitops/role: hosted-cluster
+    {{- end }}
+    {{- end }}
 spec:
   project: '{{ .Values.group }}'
   sources:
@@ -47,19 +60,32 @@
           - '$values/defaults/hub/{{ .Values.operator }}/values.yaml'
           {{- else }}
           - '$values/operators/{{ .Values.operator }}/values.yaml'
+          {{- if .Values.ocpVersion }}
           - '$values/operators/{{ .Values.operator }}/ocp-versions/{{ .Values.ocpVersion }}/values.yaml'
+          {{- end }}
           - '$values/sites/{{ .Values.site }}/values.yaml'
           - '$values/sites/{{ .Values.site }}/{{ .Values.env }}/values.yaml'
           {{- if eq .Values.cluster "in-cluster" }}
           - '$values/defaults/mces/{{ .Values.operator }}/values.yaml'
           - '$values/defaults/mces/{{ .Values.operator }}/values-{{ .Values.env }}.yaml'
           - '$values/defaults/mces/{{ .Values.operator }}/values-{{ .Values.mce }}.yaml'
+          {{- else if .Values.upi }}
+          - '$values/defaults/upi/{{ .Values.operator }}/values.yaml'
+          - '$values/defaults/upi/{{ .Values.operator }}/values-{{ .Values.env }}.yaml'
+          - '$values/defaults/upi/{{ .Values.operator }}/values-{{ .Values.cluster }}.yaml'
           {{- else }}
           - '$values/defaults/hosted-clusters/{{ .Values.operator }}/values.yaml'
           - '$values/defaults/hosted-clusters/{{ .Values.operator }}/values-{{ .Values.env }}.yaml'
           - '$values/defaults/hosted-clusters/{{ .Values.operator }}/values-{{ .Values.cluster }}.yaml'
           {{- end }}
+          # MCE-wide slot; for a UPI cluster, the UPI-wide slot at its site+env
+          # (sites/<site>/<env>/upi/values.yaml). Never an unguarded empty path:
+          # '$values//values.yaml' would resolve to the sigs repo root.
+          {{- if .Values.upi }}
+          - '$values/{{ .Values.upiPath }}/values.yaml'
+          {{- else }}
           - '$values/{{ .Values.mcePath }}/values.yaml'
+          {{- end }}
           - '$values/{{ .Values.clusterPath }}/values.yaml'
           - '$values/{{ .Values.clusterPath }}/{{ .Values.operator }}/values.yaml'
           {{- end }}
```

### 4.5 Untouched

`groups/`, `mces/templates/mcesAppset.yaml`, `mces/templates/inClusterAppset.yaml`,
`mces/templates/appProjectAppset.yaml` and everything under `clusters/`. The
frozen `namespace: gitops-{{ .Values.repository }}` lines are not copied into
either new file, and are not touched. Applying this guide does not apply any
part of Phase F.

---

## 5. Offline render check — `helm` only

The mock verifies with a render harness in `tools/`, which the air-gap does not
have. This script is the offline gate for step b instead. It renders the three
charts the MR touches with `helm template`, once from `origin/main` and once
from your working tree, and asserts:

- the `operators` and `deploy` charts render **identically** for every
  existing destination kind (MCE hub, hosted cluster, prod-hub), with and
  without the optional deploy-config keys;
- the `mces` chart output only **gains** the two new objects and loses nothing;
- the UPI branch renders at all, with and without a version, into
  `openshift-gitops-upi`.

The values are placeholders: which keys are set picks the template branch, the
names do not matter. YAML comment lines are ignored, as Argo ignores them. Both
sides get the same minimal `Chart.yaml`, so the result does not depend on it.

Save the script outside the repo, for example as `/tmp/upi-render-check.sh`,
and run it from `<platform>` with the §4 changes in the working tree:

```bash
cd <platform>
git fetch
bash /tmp/upi-render-check.sh               # compares against origin/main
```

```bash
#!/usr/bin/env bash
# UPI platform MR, offline gate. Run from <platform> with the §4 changes in the
# working tree. Needs git and helm only.
# Compares against origin/main, or the ref given as $1.
set -u
BASE_REF=${1:-origin/main}
TMP=$(mktemp -d); OLD=$TMP/old; NEW=$TMP/new; mkdir -p "$OLD" "$NEW"
git archive "$BASE_REF" | tar -x -C "$OLD" || { echo "cannot read $BASE_REF"; exit 2; }
cp -R mces operators deploy "$NEW"/
# Same minimal Chart.yaml on both sides: the render must not depend on it.
for d in "$OLD" "$NEW"; do for c in mces operators deploy; do
  printf 'apiVersion: v2\nname: %s\nversion: 0.1.0\n' $c > "$d/$c/Chart.yaml"
done; done
rc=0

# Placeholder values. Only which keys are set matters: that picks the branch.
M='group: t
env: prod
site: s1
mce: m1
mcePath: sites/s1/prod/mces/m1'
U='group: t
env: prod
site: s1
cluster: u1
clusterPath: sites/s1/prod/upi/u1
upiPath: sites/s1/prod/upi
upi: true
argoNamespace: openshift-gitops-upi'
printf '%s\n' "$M" 'cluster: in-cluster' 'clusterPath: sites/s1/prod/mces/m1/in-cluster' \
  'mastertag: 4.16.27-x86_64'                                  > $TMP/ops-mce.yaml
printf '%s\n' "$M" 'cluster: hc1' 'clusterPath: sites/s1/prod/mces/m1/hc1' \
  'mastertag: 4.16.27-x86_64'                                  > $TMP/ops-hc.yaml
printf '%s\n' "$M" 'cluster: in-cluster' 'clusterPath: sites/s1/prod/mces/m1/in-cluster' \
  'ocpVersion: 4.16.27' 'operator: c1'                         > $TMP/dep-mce.yaml
printf '%s\n' "$M" 'cluster: hc1' 'clusterPath: sites/s1/prod/mces/m1/hc1' \
  'ocpVersion: 4.16.27' 'operator: c1'                         > $TMP/dep-hc.yaml
printf '%s\n' 'group: t' 'cluster: in-cluster' 'hub: true' 'operator: c1' > $TMP/dep-hub.yaml
cat > $TMP/cfg.yaml <<'EOF'
appname: custom-name
oldConvention: true
projectNamespace: ns1
repourl: https://example.invalid/chart.git
targetRevision: v1
path: charts/x
syncPolicy: {automated: {prune: false, selfHeal: true}}
ignoreDifferences: [{group: apps, kind: Deployment, jsonPointers: [/spec/replicas]}]
EOF
printf '%s\n' "$U" 'mastertag: 4.16.27-x86_64'                 > $TMP/ops-upi.yaml
printf '%s\n' "$U"                                             > $TMP/ops-upi-nover.yaml
printf '%s\n' "$U" 'ocpVersion: 4.16.27' 'operator: c1'        > $TMP/dep-upi.yaml
printf '%s\n' "$U" 'operator: c1'                              > $TMP/dep-upi-nover.yaml
echo 'group: t'                                                > $TMP/mces.yaml

render() { # dir chart args... -> output on stdout; a failed render prints RENDER-FAILED
  # YAML comment lines are dropped (Argo never sees them); "# Source:" is kept.
  { helm template x "$1/$2" "${@:3}" 2>&1 || echo "RENDER-FAILED"; } |
    awk '!/^[[:space:]]*#/ || /^# Source:/'
}

same() { # label chart valuefiles...  -> main and branch must render identically
  local label=$1 chart=$2; shift 2
  local args=(); for f in "$@"; do args+=(-f "$TMP/$f"); done
  render "$OLD" "$chart" "${args[@]}" > $TMP/o; render "$NEW" "$chart" "${args[@]}" > $TMP/n
  if grep -q RENDER-FAILED $TMP/o $TMP/n; then
    echo "  FAIL  $chart, $label: render error"; grep -h "^Error" $TMP/o $TMP/n | head -3 | sed 's/^/        /'; rc=1
  elif diff $TMP/o $TMP/n > $TMP/d; then
    echo "  ok    $chart, $label: identical to $BASE_REF"
  else
    echo "  FAIL  $chart, $label: differs from $BASE_REF"; sed 's/^/        /' $TMP/d; rc=1
  fi
}

echo "Existing destinations: must render byte-identically"
same "MCE hub"                  operators ops-mce.yaml
same "hosted cluster"           operators ops-hc.yaml
same "MCE hub"                  deploy    dep-mce.yaml
same "hosted cluster"           deploy    dep-hc.yaml
same "hosted cluster, all keys" deploy    dep-hc.yaml cfg.yaml
same "prod-hub"                 deploy    dep-hub.yaml
same "prod-hub, all keys"       deploy    dep-hub.yaml cfg.yaml

echo "mces chart: only the two new objects may appear"
render "$OLD" mces -f $TMP/mces.yaml > $TMP/o; render "$NEW" mces -f $TMP/mces.yaml > $TMP/n
diff $TMP/o $TMP/n > $TMP/d
if grep -q RENDER-FAILED $TMP/o $TMP/n; then
  echo "  FAIL  mces: render error"; grep -h "^Error" $TMP/o $TMP/n | head -3 | sed 's/^/        /'; rc=1
elif grep -q '^<' $TMP/d; then
  echo "  FAIL  existing mces output changed:"; grep '^<' $TMP/d | sed 's/^/        /'; rc=1
fi
added=$(grep '^> # Source:' $TMP/d | sed 's#.*/templates/##' | sort | tr '\n' ' ')
if [ "$added" = "upiAppProjectApp.yaml upiAppset.yaml " ]; then
  echo "  ok    added: $added"
else
  echo "  FAIL  added: '${added}' (expected upiAppProjectApp.yaml upiAppset.yaml)"; rc=1
fi

echo "UPI: must render (branch only)"
for c in "operators ops-upi.yaml" "operators ops-upi-nover.yaml" "deploy dep-upi.yaml" "deploy dep-upi-nover.yaml"; do
  set -- $c
  out=$(render "$NEW" $1 -f $TMP/$2)
  if ! echo "$out" | grep -q RENDER-FAILED && echo "$out" | grep -q 'namespace: openshift-gitops-upi'; then
    echo "  ok    $1, ${2%.yaml}"
  else
    echo "  FAIL  $1, ${2%.yaml}: render error, or nothing in openshift-gitops-upi"
    echo "$out" | grep '^Error' | head -3 | sed 's/^/        /'; rc=1
  fi
done

rm -rf "$TMP"
echo; [ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
```

Expected output:

```
Existing destinations: must render byte-identically
  ok    operators, MCE hub: identical to origin/main
  ok    operators, hosted cluster: identical to origin/main
  ok    deploy, MCE hub: identical to origin/main
  ok    deploy, hosted cluster: identical to origin/main
  ok    deploy, hosted cluster, all keys: identical to origin/main
  ok    deploy, prod-hub: identical to origin/main
  ok    deploy, prod-hub, all keys: identical to origin/main
mces chart: only the two new objects may appear
  ok    added: upiAppProjectApp.yaml upiAppset.yaml
UPI: must render (branch only)
  ok    operators, ops-upi
  ok    operators, ops-upi-nover
  ok    deploy, dep-upi
  ok    deploy, dep-upi-nover

RESULT: PASS
```

Any `FAIL` stops the MR:

- **`differs from origin/main`** under "Existing destinations": a UPI guard
  leaked into an existing render. The diff lines show where. Compare the file
  with §4.
- **`render error`**: a nil reached a template function, typically a
  `ternary` on `.Values.upi`, or `.Values.upi` used without a guard.
- **`existing mces output changed`**, or other files under `added:`: something
  besides the two new files changed in `mces/templates/`.

What it cannot see: which folders the generators discover, and anything in the
sigs repos. Discovery is covered by the glob argument in §2. Sigs changes are
covered by the review list in §6.2.

---

## 6. Sigs repos

### 6.1 `defaults/upi/README.md` (optional)

The working contract for the folder: rules and value precedence. It is a
plain file, so no generator sees it. Do not copy the mock's copy: it also
documents the structural opt-out (`exclusions.yaml`, rule 4, the XOR
carve-out), which does not exist without Phase F. Use this version instead,
with `<team>` replaced by the team name:

````markdown
# defaults/upi

Chart folders in this directory are deployed to **every UPI cluster** of this
team (<team>), on every site and env. A UPI cluster is a standalone OpenShift
cluster: no MCE above it and no Argo of its own. This folder is the UPI mirror
of [`defaults/hosted-clusters/`](../hosted-clusters/) (every hosted cluster),
[`defaults/mces/`](../mces/) (every MCE hub) and [`defaults/hub/`](../hub/)
(the prod-hub mgmt cluster).

Wiring: the platform's `upiAppset` (on prod-hub's day2 Argo) creates one
`<team>-<cluster>` app per folder under `sites/<site>/<env>/upi/`. That app
hands the `operators` chart over to the **UPI Argo instance**
(`openshift-gitops-upi`, on the same hub cluster), whose generator scans
`defaults/upi/*` next to the cluster's own chart folders and feeds the **same
ApplicationSet and template**. A chart therefore renders a byte-identical
Application whether it sits here or in a specific cluster folder — moving it
between the two is an in-place update, never a delete/recreate.

## Layout

```
defaults/
  upi/
    <chart>/
      <chart>.yaml            # deploy config (repourl, projectNamespace, syncPolicy, ...)
      values.yaml             # helm values applied on every UPI cluster
      values-<env>.yaml       # optional: overrides for one env (prod | prep | test)
      values-<cluster>.yaml   # optional: overrides for one specific UPI cluster
```

## Registering a UPI cluster

A UPI cluster exists for day2 when its folder exists:
`sites/<site>/<env>/upi/<cluster>/`. Two things to know:

- **The folder name is the cluster's name on the UPI Argo instance**
  (`argocd cluster list` against `openshift-gitops-upi`). The leaf apps target
  `destination.name: <cluster>` there. Name the folder after the existing
  cluster secret, never the reverse.
- **`version.yaml` in that folder is optional.** It holds `mastertag:
  4.16.27-x86_64` and nothing else. With it, the cluster's charts pick up
  `operators/<chart>/ocp-versions/<v>/` pins and carry a
  `day2.gitops/ocp-version` label. Without it, the cluster is version-less
  like prod-hub: pinned charts get the team default. day1 does not know UPI
  clusters, so this is the one place a sigs repo declares a version, and a UPI
  upgrade is one edit per team repo that declares it.

There is **no day1 parity check** for UPI folders, so a stray folder under
`upi/` becomes a phantom app. Nothing catches that offline: every MR that
touches `upi/` is reviewed by hand.

## Rules

1. **XOR rule:** a chart lives EITHER here OR in a specific UPI cluster's
   folder (`sites/<site>/<env>/upi/<cluster>/<chart>/`) — never both. A
   violation produces two generator entries with the same Application name;
   controller behavior for duplicates is undefined.
2. **Per-scope overrides go in `values-<env>.yaml` / `values-<cluster>.yaml`
   here** — do NOT create the chart under a specific cluster just to hold an
   override file (that violates rule 1).
3. **Every directory directly under this folder becomes an Application on
   every UPI cluster.** Never create non-chart directories here. Plain files
   are ignored by the directory generator and are safe — this README is a
   plain file here for exactly that reason.
4. **There is no per-cluster opt-out.** A chart here is deployed to every UPI
   cluster of the team. A cluster that needs the chart to *behave* differently
   gets a `values-<cluster>.yaml` here. A chart that some UPI cluster must not
   have **at all** does not belong here: put it in the folders of the clusters
   that need it instead.
5. **`repourl` is all-lowercase** — that is the key `deployApp.yaml` reads.
6. **Leave `targetRevision` out of the deploy config here if the chart should
   follow per-OCP-version pins.** This file sits ABOVE the
   `operators/<chart>/ocp-versions/<v>/` layer in the config stack, so a
   `targetRevision` written here overrides every version pin silently.
7. **Never let gitops-upi and day2 deploy the same chart to the same cluster.**
   Both now run on the UPI Argo instance with the same `releaseName` and
   namespace, so two Applications would fight over one release. Remove the
   chart from gitops-upi first, then add it here or to the cluster folder.

## Values precedence (lowest to highest)

1. `operators/<chart>/values.yaml` — chart, team-wide
2. `operators/<chart>/ocp-versions/<v>/values.yaml` — chart, per OCP version (only when the cluster has a `version.yaml`)
3. `sites/<site>/values.yaml` — site-wide (shared with every kind of cluster at the site)
4. `sites/<site>/<env>/values.yaml` — site + env (shared likewise)
5. `defaults/upi/<chart>/values.yaml` — chart, every UPI cluster
6. `defaults/upi/<chart>/values-<env>.yaml` — chart + env
7. `defaults/upi/<chart>/values-<cluster>.yaml` — chart + cluster
8. `sites/<site>/<env>/upi/values.yaml` — every UPI cluster at this site + env
9. `sites/<site>/<env>/upi/<cluster>/values.yaml` — cluster-wide
10. `.../<cluster>/<chart>/values.yaml` — per-cluster charts only (XOR rule)

Layers 3 and 4 are shared with MCE hubs and hosted clusters at the same
site/env on purpose: they hold site facts (registry, DNS, proxy) that every
cluster there needs. Anything only UPI clusters should see goes in layers 5–9.

Deploy config precedence: `operators/<chart>/<chart>.yaml` →
`operators/<chart>/ocp-versions/<v>/<chart>.yaml` (versioned clusters only) →
`defaults/upi/<chart>/<chart>.yaml` →
`.../<cluster>/<chart>/<chart>.yaml` (per-cluster charts only).
````

The folder `defaults/upi/` itself works like `defaults/hosted-clusters/`:
every chart folder in it deploys to every UPI cluster of the team, with
`values-<env>.yaml` and `values-<cluster>.yaml` overrides. There is no
per-cluster opt-out: a chart that some UPI cluster must not have belongs in
the folders of the clusters that need it, not here.

### 6.2 Onboarding one UPI cluster

1. **Pick the folder**: `sites/<site>/<env>/upi/<cluster>/`, where `<cluster>`
   is B's cluster secret name (check 9). `<env>` is one of `prod`, `prep`,
   `test`. The name need not contain the env: the folder position is what
   sets `env` and `site`.
2. **Optionally add `version.yaml`** (§6.3).
3. **Add chart folders**, `<chart>/{<chart>.yaml, values.yaml}`, exactly as for
   a hosted cluster. Only charts that gitops-upi does not deploy to this
   cluster (check 11).
4. A folder with no content yet needs a `.gitkeep`: git cannot track an empty
   folder.
5. **Review the MR by hand.** Nothing checks a sigs change offline in the
   air-gap, and every folder under `upi/` becomes an app:
   - the path is exactly `sites/<site>/<env>/upi/<cluster>/`, and `<env>` is
     `prod`, `prep` or `test`;
   - `<cluster>` is in B's cluster secret list (check 9), is not `in-cluster`,
     and is not the name of an MCE or hosted cluster of any team;
   - `version.yaml`, if present, has exactly one key, `mastertag`, in the form
     `4.16.27` or `4.16.27-x86_64` (§6.3);
   - no chart is both in `defaults/upi/` and in the cluster folder: that emits
     two apps with one name;
   - no chart in the folder is still deployed to that cluster by gitops-upi
     (check 11);
   - the MR adds no other folder under `sites/*/*/upi/`.

### 6.3 `version.yaml` — optional

```yaml
# sites/<site>/<env>/upi/<cluster>/version.yaml
mastertag: 4.16.27-x86_64
```

- **With it:** the cluster's charts use the `operators/<chart>/ocp-versions/4.16.27/`
  layers and carry `day2.gitops/ocp-version: "4.16.27"`. The arch suffix is
  optional.
- **Without it:** the cluster is version-less like prod-hub. A chart pinned
  per version gets its team default from `operators/<chart>/<chart>.yaml`.
- **`mastertag` and nothing else.** The file is loaded as a Helm value file,
  so any other key silently becomes a chart value. Nothing rejects it in the
  air-gap: the §6.2 review is the check. A malformed tag is silent too: the
  version-pin paths are built from it and simply match no folder.
- **Hand-maintained, per team repo.** day1 does not know UPI clusters, so
  every sigs repo that has the cluster declares its own copy, and an upgrade is
  one edit in each. Create the new `ocp-versions/<v>/` layers first.

### 6.4 Value precedence for a UPI cluster (lowest to highest)

| # | Layer | Scope |
|---|---|---|
| 1 | `operators/<c>/values.yaml` | chart, team-wide |
| 2 | `operators/<c>/ocp-versions/<v>/values.yaml` | chart, per OCP version (only with `version.yaml`) |
| 3 | `sites/<site>/values.yaml` | site-wide, **shared with MCEs and hosted clusters** |
| 4 | `sites/<site>/<env>/values.yaml` | site + env, **shared likewise** |
| 5 | `defaults/upi/<c>/values.yaml` | chart, every UPI cluster |
| 6 | `defaults/upi/<c>/values-<env>.yaml` | chart + env |
| 7 | `defaults/upi/<c>/values-<cluster>.yaml` | chart + one cluster |
| 8 | `sites/<site>/<env>/upi/values.yaml` | every UPI cluster at this site + env |
| 9 | `sites/<site>/<env>/upi/<cluster>/values.yaml` | cluster-wide |
| 10 | `sites/<site>/<env>/upi/<cluster>/<c>/values.yaml` | chart on this cluster — always wins |

Layers 3 and 4 are shared on purpose. They hold site facts, such as registry,
DNS and proxy, that every cluster at the site needs. Anything only UPI
clusters should see goes in layers 5 to 9.

Deploy config: `operators/<c>/<c>.yaml` → `operators/<c>/ocp-versions/<v>/<c>.yaml`
→ `defaults/upi/<c>/<c>.yaml` → `sites/<site>/<env>/upi/<cluster>/<c>/<c>.yaml`.

---

## 7. Verify

### 7.1 After the platform MR (step b)

**Before merging:** §5 prints `RESULT: PASS`, and the §10 greps match.

**Optional live preview**, before merging, with the `argocd` CLI logged in to
instance A. The app to diff is the one the `groups` ApplicationSet created for
the team, which renders the `mces` chart (`argocd app list | grep <team>`; its
path is `mces`):

```bash
argocd app diff <team> --revision <your-branch>
```

It must show exactly two new objects, the ApplicationSet `<team>-upi` and the
Application `<team>-upi-app-project`, and nothing else. The operators and
deploy changes do not show here: apps on the MCEs' Argo instances render
those charts, and §5 covers them.

**After merging**, per team:

```bash
oc get application <team>-upi-app-project -n openshift-gitops          # Synced / Healthy
oc get appproject <team> -n openshift-gitops-upi                       # exists
oc get applicationset <team>-upi -n gitops-<team>                      # exists
oc get applications -n openshift-gitops-upi -l day2.gitops/team=<team> # nothing yet: no upi/ folder
```

No existing day2 app, on A or on an MCE, should go OutOfSync because of this
merge. Their templates render identically (§5), so an OutOfSync app there has
another cause.

### 7.2 After the first UPI cluster folder (step d)

**Before merging:** the §6.2 review list. **After merging**, the chain runs:

- on A, `<team>-upi` creates the wrapper `<team>-<cluster>` in `gitops-<team>`;
- the wrapper writes the ApplicationSet `<team>-<cluster>-operators` into
  `openshift-gitops-upi`;
- on B, that ApplicationSet creates two apps per chart, `<team>-<cluster>-<chart>`
  and its leaf `<team>-<cluster>-<chart>-deploy`, for every chart in the folder
  and in `defaults/upi/`.

Expect exactly **1 + 2 × (charts in the folder + charts in `defaults/upi/`)**
new apps, and no change to any existing app. The mock's first folder,
`sites/site1/prod/upi/ocp4-dok-site1/` with a `version.yaml` and one chart,
`cluster-roles`, gave 3 (§7.4).

The leaf has namespace `openshift-gitops-upi`, destination `name: <cluster>`,
`releaseName: <chart>`, labels with `role: upi` and no `mce`, and this value
stack (`oc get application <team>-<cluster>-<chart>-deploy -n
openshift-gitops-upi -o yaml`, `spec.sources[0].helm.valueFiles`). In the mock:

```
 1  $values/operators/cluster-roles/values.yaml
 2  $values/operators/cluster-roles/ocp-versions/4.16.27/values.yaml
 3  $values/sites/site1/values.yaml
 4  $values/sites/site1/prod/values.yaml
 5  $values/defaults/upi/cluster-roles/values.yaml
 6  $values/defaults/upi/cluster-roles/values-prod.yaml
 7  $values/defaults/upi/cluster-roles/values-ocp4-dok-site1.yaml
 8  $values/sites/site1/prod/upi/values.yaml
 9  $values/sites/site1/prod/upi/ocp4-dok-site1/values.yaml
10  $values/sites/site1/prod/upi/ocp4-dok-site1/cluster-roles/values.yaml
```

Without `version.yaml`, line 2 is absent and so is the
`day2.gitops/ocp-version` label.

### 7.3 Live, after the first folder

```bash
oc get application <team>-<cluster> -n gitops-<team>                       # A: Synced
oc get applicationset <team>-<cluster>-operators -n openshift-gitops-upi   # B: exists
oc get applications -n openshift-gitops-upi -l day2.gitops/cluster=<cluster>
                                        # B: <team>-<cluster>-<chart> and -deploy, Synced/Healthy
```

The chart's resources exist on the UPI cluster. That is the check nothing
offline can make.

### 7.4 Verification in the mock, with Phase F removed

The mock's platform was copied and Phase F reversed in the copy (F.1–F.3 from
`APPLY-EXCLUSIONS.md`, and no `exclusions.yaml` in the sigs copy): that is
the air-gap's starting point. §4 was then applied from the blocks in this file
and checked with the mock's render harness, which renders the whole chain
offline. Probes were reverted after each run.

| Step / probe | Result |
|---|---|
| step b: §4 applied, no `upi/` folder | 35 → 36 apps: only `prod-hub:redbull-upi-app-project` added; every other app identical |
| step d: + `sites/site1/prod/upi/ocp4-dok-site1/` (`version.yaml` + `cluster-roles`) | 36 → 39: the wrapper on prod-hub, `cluster-roles` and its `-deploy` leaf on B; every other app identical |
| `version.yaml` deleted | no render error; the leaf stack drops to 9 layers and the `ocp-version` label goes |
| `mastertag` flipped to `4.20.9-x86_64` | only the two chart apps' labels and version-pin paths change |
| `defaults/upi/example-chart/` added | 2 apps added on B |
| a marker in `sites/site1/prod/upi/values.yaml` | the leaf's value stack gains that file; no other app changes |
| §5 on the same copy | `RESULT: PASS`. Two planted leaks, a wrong role label on hosted clusters and a `ternary` on `.Values.upi` in the deploy chart, each make it `FAIL` |

---

## 8. Removing a UPI cluster

Deleting a folder never uninstalls anything, as for MCEs and hosted clusters
(`ARCHITECTURE.md` R8). For UPI it plays out like this:

1. `<team>-upi` deletes the wrapper `<team>-<cluster>` on A. The wrapper has
   no resources-finalizer, so the ApplicationSet `<team>-<cluster>-operators`
   it wrote into B's namespace **stays and keeps running**, with the values it
   was rendered with.
2. That ApplicationSet no longer finds the cluster folder, so B removes the
   cluster's own chart apps. Their `-deploy` leaves stay, and the workloads
   keep running.
3. It still finds `defaults/upi/*`, so fleet-default charts **keep being
   deployed** to that cluster.

To remove the cluster from day2 completely:

```bash
oc delete applicationset <team>-<cluster>-operators -n openshift-gitops-upi
# Kubernetes then garbage-collects its chart apps (<team>-<cluster>-<chart>).
oc get applications -n openshift-gitops-upi -l day2.gitops/cluster=<cluster>
# -> only the -deploy leaves remain. Then, per leaf, ONE of:

# keep the workload running on the cluster, unmanaged:
oc delete application <team>-<cluster>-<chart>-deploy -n openshift-gitops-upi

# or remove the workload too (logged in to instance B):
argocd app delete <team>-<cluster>-<chart>-deploy --cascade
```

Re-adding the same folder instead recreates everything and re-adopts the
running workloads by name.

---

## 9. Docs

The mock updated these alongside the templates. Carry them over if you keep
copies in the air-gap. The mock's copies also describe Phase F
(`exclusions.yaml`, the XOR carve-out, runbook R10, the CI checks): leave
those parts out.

| File | Change |
|---|---|
| `sigs/<team>/README.md` | `upi/` in the tree, naming rules, "what makes a folder a cluster", the version exception, value stacks, `defaults/upi/` |
| `sigs/<team>/defaults/upi/README.md` | new: the version in §6.1, not the mock's |
| `sigs/<team>/defaults/{mces,hub,hosted-clusters}/README.md` | link to `defaults/upi/` |
| `argocd-day2-platform/README.md` | four destination kinds, instance B, the two new templates, fork tables, values, labels, invariants |
| `ARCHITECTURE.md` | the same, plus runbook R11 "Add a UPI cluster" and the UPI case in R8 |
| `CHANGES.md` | a pointer to this guide |

---

## 10. Final gate

```bash
cd <platform>
grep -rn 'namespace: openshift-gitops-upi\|argoNamespace: openshift-gitops-upi' --include='*.yaml' .
# -> exactly 3 lines, all in the two new files:
#    mces/templates/upiAppProjectApp.yaml   namespace: openshift-gitops-upi
#    mces/templates/upiAppset.yaml          argoNamespace: openshift-gitops-upi
#    mces/templates/upiAppset.yaml          namespace: openshift-gitops-upi
grep -c '^  namespace: openshift-gitops$' mces/templates/upiAppProjectApp.yaml
                                                                  # -> 1 (A's own namespace: project default has no sourceNamespaces)
grep -c 'createNamespace: false' mces/templates/upiAppProjectApp.yaml
                                                                  # -> 1 (B gets the AppProject only, check 7)
grep -c '\$day1' mces/templates/upiAppset.yaml                    # -> 0 (UPI never reads day1)
grep -c '| ternary' operators/templates/operators.yaml deploy/templates/deployApp.yaml
                                                                  # -> 0 and 0 (never on .Values.upi)
grep -c 'exclu' operators/templates/operators.yaml mces/templates/upiAppset.yaml
                                                                  # -> 0 and 0 (no Phase F code)
grep -rn '<GITLAB>' mces/ operators/ deploy/                      # -> nothing (host replaced, §4)
git diff --stat origin/main -- mces/templates/appProjectAppset.yaml mces/templates/mcesAppset.yaml clusters/ groups/
                                                                  # -> nothing
```

Then §5 (`RESULT: PASS`), the §7.1 live checks after the merge, and the §7.3 live check once the first
folder lands.
