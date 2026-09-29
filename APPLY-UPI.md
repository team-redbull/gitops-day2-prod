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

Implemented and render-verified in the mock repo. §7 has the exact harness
output to expect, and every patch below is the mock's change verbatim.

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

**Check 1 — confirm the checkout is the migrated one.** UPI builds on the end
state of `CHANGES.md` (Phases A→E), `APPLY-EXCLUSIONS.md` (F and G) and
`APPLY-OCP-VERSIONS.md`. All three are already applied in the air-gap
(confirmed 2026-09-28), so this is a quick check that the platform checkout
you are about to patch is that state. The §4 patches use it as context and
will not apply to anything else.

```bash
cd <platform>
grep -c 'sites/\*/\*/mces/\*' mces/templates/mcesAppset.yaml            # -> 1   (sites/ tree live)
grep -c 'ocp-versions/' deploy/templates/deployApp.yaml                 # -> 1   (rename applied)
grep -cF 'ocp-versions/{{ $ocpVersion }}/' operators/templates/operators.yaml   # -> 1   (rename applied: the valueFiles line)
grep -cF 'ocp-versions/<v>/ folder created' operators/templates/operators.yaml  # -> 1   (the preamble comment)
grep -c 'Values.exclusions' operators/templates/operators.yaml          # -> 1   (Phase F applied)
grep -c 'argoNamespace' operators/templates/operators.yaml deploy/templates/deployApp.yaml
                                                                        # -> 0 and 0 (this guide not applied yet)
ls mces/templates/upiAppset.yaml                                        # -> No such file
```

| Output | What it means | What to do |
|---|---|---|
| all as shown | the expected, migrated state | continue |
| the first, second, third or fifth is `0` | this is not the migrated platform repo: an old clone, or a branch cut before the migration | switch to the migrated `main` and re-run |
| only the preamble-comment line is `0` | the rename landed on the live line, but the comment still has the old wording (`APPLY-OCP-VERSIONS.md` §3.2 is comment-only, so nothing caught it). Rendering is fine. The first hunk of §4.3 uses that comment line as context, so `git apply --check` will reject it | run `grep -n 'folder created' operators/templates/operators.yaml` and make that line read exactly `     operators/<chart>/ocp-versions/<v>/ folder created BEFORE day1 flips the`, then re-run |
| `argoNamespace` non-zero, or the file exists | this guide was already (partly) applied | compare with §4 file by file |

**Check 2 — the harness baseline is green.** The harness moved into the
platform repo with Phase G (`APPLY-EXCLUSIONS.md` G.2). Run it once per sigs
repo and keep the output: it is the "before" snapshot for §7.

```bash
RENDER=<platform>/tools/render-verify/render_chain.py
python3 "$RENDER" snapshot --out /tmp/rv-before-<team> \
    --group <team> --sigs <sigs> --platform <platform> --day1 <day1>
# -> "snapshot: N apps, M appset CRs", exit 0, no CONSISTENCY CHECK FAILURES
```

Any failure here is pre-existing and unrelated to UPI. Fix it first.

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

If the migration delete guard rail (`tools/migration-guardrail/`) is still
bound to this controller, its first rule already grants these verbs on every
resource, so the answers are `yes`. UPI never needs `delete`, so the guard
rail neither blocks this change nor needs touching for it. Lifting it is its
own procedure (`tools/migration-guardrail/README.md`, "Lift").

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
cluster shares a name with an MCE or a hosted cluster. The harness enforces
that within one sigs repo, but only you can see across all five.

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
mock, all 33 existing Applications and all 12 existing ApplicationSets have a
byte-identical spec after the change (§7.1).

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
| b | §4 platform patches + §5 harness patches, one MR in `<platform>` | **offline**: §7.1 compare for every team shows only `apps added: ['prod-hub:<team>-upi-app-project']` and `IDENTITY OK`. **live**: `<team>-upi-app-project` is Synced/Healthy in `openshift-gitops` on A for every team, and `oc get appprojects -n openshift-gitops-upi` lists one AppProject per team |
| c | §6.1 `defaults/upi/README.md` in each sigs repo (optional, docs only) | offline compare unchanged |
| d | §6.2 the first UPI cluster folder, in one team's repo | **offline**: §7.2 compare shows only `apps added` (1 on `prod-hub`, 2 per chart on `prod-hub-upi`) and `IDENTITY OK`. **live**: §7.3 |
| e | more clusters, more teams | the same two gates per MR |

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
paths relative to the platform repo root, and the mock's change verbatim
except for one substitution: the GitLab host in `repoURL:` lines is written
`<GITLAB>`. No context line contains the host, so only added lines carry it.

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
@@ -0,0 +1,91 @@
+apiVersion: argoproj.io/v1alpha1
+kind: ApplicationSet
+metadata:
+  name: {{ .Values.group }}-upi
+  namespace: gitops-{{ .Values.group }}
+spec:
+  generators:
+    - git:
+        repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
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
+        # phantom app aimed at a cluster that does not exist; the only offline
+        # signal is an unexpected `apps added` line in render-verify's compare.
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
+        - repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/argocd-day2-platform.git'
+          targetRevision: main
+          path: operators
+          helm:
+            ignoreMissingValueFiles: true
+            valueFiles:
+              # Generation input, not workload config: the team's fleet-default
+              # opt-out matrix. FIRST on purpose — the version file must
+              # outrank it (same order as clustersAppset).
+              - '$values/defaults/upi/exclusions.yaml'
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
+        - repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
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
- **`$role`:** three kinds, built with if/else. `ternary` on the nil
  `.Values.upi` would abort every existing render.
- **Generator:** a `defaults/upi/*` branch, placed **before** the
  hosted-cluster branch, which would otherwise catch every non-MCE destination.
- **Labels and inline values:** `mce` only when set, and `upi`, `upiPath` and
  `argoNamespace` passed down only for UPI.
- **Config stack:** `defaults/upi/<c>/<c>.yaml` as the UPI defaults layer.

```diff
--- a/operators/templates/operators.yaml
+++ b/operators/templates/operators.yaml
@@ -3,20 +3,35 @@
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
 {{- /* Fleet-default exclusions — the one structural opt-out from
-     defaults/mces/ and defaults/hosted-clusters/.
+     defaults/mces/, defaults/hosted-clusters/ and defaults/upi/.
      The data CANNOT live per-chart: chart folders are discovered from git at
      generator time, and this template only ever sees Helm VALUES. So it
      arrives from ONE fixed-path file per scope, defaults/<scope>/
      exclusions.yaml, resolved by the parent Application (clustersAppset /
-     inClusterApp) through its $values ref source. Absent file -> empty dict
+     inClusterApp / upiAppset) through its $values ref source. Absent file -> empty dict
      -> zero exclude entries -> byte-identical output to before this feature,
      which is the permanent state of any team that never writes one.
      A key naming a chart that does not exist, or a name that is not a real
@@ -27,8 +42,18 @@
 {{-   fail (printf "defaults/<scope>/exclusions.yaml: `exclusions` must be a map of <chart> -> [names], got %s" (kindOf $exclusions)) -}}
 {{- end -}}
 {{- $isMce := eq .Values.cluster "in-cluster" -}}
+{{- /* Three destination kinds, one template. if/else, NOT a ternary:
+     .Values.upi is nil on every MCE and hosted-cluster render, and sprig's
+     ternary requires a real bool — a nil there aborts the render. */ -}}
+{{- $role := "hosted-cluster" -}}
+{{- if $isMce -}}
+{{-   $role = "mce" -}}
+{{- else if .Values.upi -}}
+{{-   $role = "upi" -}}
+{{- end -}}
 {{- /* MCE hubs key on the MCE name (.Values.cluster is the literal
-     "in-cluster" for every one of them); hosted clusters on the folder name. */ -}}
+     "in-cluster" for every one of them); hosted clusters and UPI clusters on
+     the folder name. */ -}}
 {{- $exKey := $isMce | ternary .Values.mce .Values.cluster -}}
 {{- $excluded := list -}}
 {{- range $chart, $names := $exclusions -}}
@@ -45,7 +70,7 @@
 kind: ApplicationSet
 metadata:
   name: {{ .Values.group }}-{{ .Values.cluster }}-operators
-  namespace: gitops-{{ .Values.group }}
+  namespace: {{ $argoNs }}
 spec:
   generators:
     - git:
@@ -68,6 +93,21 @@
           - path: "defaults/mces/{{ $chart }}"
             exclude: true
           {{- end }}
+    {{- else if .Values.upi }}
+    # Fleet defaults for UPI clusters: every chart folder here is deployed to
+    # every UPI cluster of the team. Checked BEFORE the hosted-cluster branch
+    # below, which would otherwise catch every non-MCE destination.
+    - git:
+        repoURL: 'https://<GITLAB>/redbull/gitops-day2-prod/sigs/{{ .Values.group }}.git'
+        revision: main
+        # Same two constraints as the MCE generator above: same block, and
+        # byte-for-byte equal to what the include glob emits.
+        directories:
+          - path: "defaults/upi/*"
+          {{- range $chart := $excluded }}
+          - path: "defaults/upi/{{ $chart }}"
+            exclude: true
+          {{- end }}
     {{- else if not .Values.hub }}
     # Fleet defaults for hosted clusters: every chart folder here is deployed
     # to every hosted cluster of the team (mirror of the defaults/mces
@@ -91,11 +131,15 @@
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
@@ -106,23 +150,36 @@
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
@@ -132,7 +189,7 @@
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
either new file, and are not touched.

---

## 5. Render harness — `tools/`

Same MR as §4, so the platform CI checks the change with the new rules. The
paths are the mock's. Use wherever your copy lives after `APPLY-EXCLUSIONS.md`
G.2.

What changes in `render_chain.py`:

- **Instance B is modelled.** An app whose destination is `in-cluster` in
  namespace `openshift-gitops-upi` hands its objects to instance B, reported as
  `prod-hub-upi:<app>`. Without this, UPI apps would be keyed as prod-hub apps.
- **`defaults/upi/exclusions.yaml`** is a control file, and `defaults/upi` is
  an exclusion scope with UPI cluster names as its valid targets.
- **A UPI `version.yaml`** is its own `version` bucket: changing it is INFO,
  like a day1 version change. A file with anything but a valid `mastertag` is
  a check failure. A missing file is fine.
- **UPI folders are linted:** env folder allow-list, no `in-cluster`, and no
  reuse of an MCE or hosted-cluster name. There is **no day1 parity check**
  for UPI, so a stray folder under `upi/` shows only as an unexpected
  `apps added` line. Read that line on every MR.

```diff
--- a/tools/render-verify/render_chain.py
+++ b/tools/render-verify/render_chain.py
@@ -7,12 +7,15 @@
              -> clusters chart -> clustersAppset + static inClusterApp
              -> operators chart -> operators appset
              -> deploy chart   -> leaf workload Application
+  UPI clusters (no MCE): mces chart -> upiAppset -> operators chart -> deploy
+             chart, the operators chart handed over by NAMESPACE to the UPI
+             Argo instance on the same hub cluster (ARGO_BY_NAMESPACE)
 
 For every generated Application it records identity fields, labels and the
 ordered sequence of *existing* value files (path + content hash) the app
 resolves. Value files come from TWO repos: the sigs repo ($values) and the
-day1 platform-config repo ($day1), which owns every cluster's OCP version as
-`mastertag`. Resolved files land in one of THREE buckets:
+day1 platform-config repo ($day1), which owns every MCE's and hosted cluster's
+OCP version as `mastertag`. Resolved files land in one of FOUR buckets:
 
   sigs     workload config -> a change here changes what a workload renders
                               -> HARD
@@ -24,11 +27,15 @@
                               would raise a HARD diff on every app in the team
                               for a change whose real effect is a two-line
                               APPS DISAPPEARED -> INFO
+  version  a UPI cluster's own sigs/.../upi/<cluster>/version.yaml (day1 does
+                              not know UPI clusters, so the folder declares its
+                              optional version). Same role as a day1 file:
+                              where versions are SUPPOSED to change -> INFO
 
 Snapshots taken before/after a change are compared with `compare`: identity
 fields and the sigs-resolved content sequence must be equal; everything else
-(labels, valueFiles path strings, extra ref sources, day1 versions, control
-files) is reported as an expected/informational diff.
+(labels, valueFiles path strings, extra ref sources, day1 and UPI versions,
+control files) is reported as an expected/informational diff.
 
 This simulates the documented ApplicationSet generator parameters only
 ({{path}}, {{path.basename}}, {{path[n]}}, flattened file keys). It is a
@@ -67,8 +74,17 @@
 # git at generator time and never reach it. Bucketed away from the sigs
 # sequence in compare — see the module docstring.
 CONTROL_FILES = {"defaults/hosted-clusters/exclusions.yaml",
-                 "defaults/mces/exclusions.yaml"}
+                 "defaults/mces/exclusions.yaml",
+                 "defaults/upi/exclusions.yaml"}
 ENVS_ALLOWED = {"prod", "prep", "test"}
+# A UPI cluster's optional version file, in its own sigs folder. A regex, not
+# a glob: fnmatch's '*' would cross '/'.
+UPI_VERSION_RE = re.compile(r"^sites/[^/]+/[^/]+/upi/[^/]+/version\.yaml$")
+# Argo instances reached by NAMESPACE on the same cluster rather than by a
+# cluster destination: an app whose destination is in-cluster + one of these
+# namespaces hands its rendered objects to that instance (upiAppset ->
+# the UPI Argo). Everything else keeps today's rule (in-cluster = same Argo).
+ARGO_BY_NAMESPACE = {"openshift-gitops-upi": "prod-hub-upi"}
 
 # All four are set in main(). In this mock the three repos are subdirectories
 # of one checkout; in the air-gapped env they are three separate GitLab
@@ -307,6 +323,8 @@
         rel = posixpath.normpath(rel)
         if repo == "sigs" and rel in CONTROL_FILES:
             repo = "control"
+        elif repo == "sigs" and UPI_VERSION_RE.match(rel):
+            repo = "version"
         full = os.path.join(root, rel)
         if os.path.isfile(full):
             with open(full, "rb") as fh:
@@ -380,7 +398,11 @@
     docs = helm_template(chart_dir, values)
 
     dest = (spec.get("destination") or {}).get("name")
-    child_argo = argo if dest in (None, "in-cluster") else dest
+    dest_ns = (spec.get("destination") or {}).get("namespace")
+    if dest in (None, "in-cluster"):
+        child_argo = ARGO_BY_NAMESPACE.get(dest_ns, argo)
+    else:
+        child_argo = dest
 
     for doc in docs:
         process_doc(snapshot, child_argo, doc, parent_layer=layer)
@@ -459,6 +481,43 @@
     return m.group(1)
 
 
+def sigs_mastertag(rel, needed_by):
+    """Validate a UPI cluster's OPTIONAL version.yaml in the sigs repo.
+
+    day1 provisions MCEs and hosted clusters only, so a UPI cluster declares
+    its own version in its own folder — or none, and is then version-less like
+    prod-hub. Absent is legal (returns None, no failure). Present means the
+    same format rule as a day1 tag, and `mastertag` must be the ONLY key: the
+    file is loaded as a Helm value file, so any other key is a real chart value.
+    """
+    full = os.path.join(SIGS, rel)
+    if not os.path.isfile(full):
+        return None
+    with open(full) as fh:
+        raw = fh.read()
+    try:
+        doc = yaml.safe_load(raw)
+    except yaml.YAMLError as e:
+        fail(f"{rel}: not parseable as YAML: {e}")
+        return None
+    if doc is None:
+        return None                    # empty file: same as absent
+    if not isinstance(doc, dict) or set(doc) != {"mastertag"}:
+        keys = sorted(doc) if isinstance(doc, dict) else type(doc).__name__
+        fail(f"{rel}: a UPI version file carries `mastertag` and nothing else "
+             f"(found {keys}) — it is loaded as a Helm value file for "
+             f"{needed_by}, so every other key becomes a chart value. Delete the "
+             f"file instead to make the cluster version-less.")
+        return None
+    tag = str(doc["mastertag"])
+    if not MASTERTAG_RE.match(tag):
+        fail(f"{rel}: mastertag {tag!r} is not <major>.<minor>.<patch>[-<arch>] "
+             f"— the platform strips the arch at the first '-' and uses the "
+             f"rest verbatim as ocpVersion")
+        return None
+    return tag
+
+
 def lint_sigs_tree():
     """§9.2 consistency checks on the sigs repo.
 
@@ -468,6 +527,12 @@
     carrying the `mastertag` its OCP version is rendered from — that parity
     check is also what catches a stray folder that is not a cluster, before it
     becomes a phantom Application.
+
+    A UPI cluster is a folder under sites/<site>/<env>/upi/. day1 does not know
+    UPI clusters, so there is NO parity check for them: a stray folder there is
+    caught only as an unexpected `apps added` line in compare. What IS checked:
+    the env folder, the optional version.yaml, and that the name is not already
+    taken by an MCE or a hosted cluster (cluster names are flat and global).
     """
     if git_ls("mces/*/mce.yaml") or git_ls("mces/*/*/hc.yaml"):
         fail("legacy mces/ layout found: a day1 version file cannot be located "
@@ -487,6 +552,27 @@
                 continue               # the MCE hub itself, excluded by the appset
             day1_mastertag(day1_version_file(site, mce, hc), hc_dir)
 
+    # UPI clusters: sites/<site>/<env>/upi/<cluster>, a sibling of mces/ at
+    # the same depth.
+    mce_names = {posixpath.basename(d) for d in match_dirs("sites/*/*/mces/*")}
+    hc_names = ({posixpath.basename(d) for d in match_dirs("sites/*/*/mces/*/*")}
+                - {"in-cluster"})
+    for upi_dir in sorted(match_dirs("sites/*/*/upi/*")):
+        segs = upi_dir.split("/")          # sites/<site>/<env>/upi/<cluster>
+        env, cluster = segs[2], segs[4]
+        if env not in ENVS_ALLOWED:
+            fail(f"{upi_dir}: env folder '{env}' not in {sorted(ENVS_ALLOWED)}")
+        if cluster == "in-cluster":
+            fail(f"{upi_dir}: a UPI cluster cannot be named in-cluster — that "
+                 f"is every Argo's name for its own cluster, and the operators "
+                 f"chart would render it as an MCE hub")
+        elif cluster in mce_names or cluster in hc_names:
+            fail(f"{upi_dir}: UPI folder {cluster!r} reuses an MCE or "
+                 f"hosted-cluster name — cluster names are flat and global, "
+                 f"so one name would mean two clusters (for an MCE name, "
+                 f"`{GROUP}-{cluster}` would also be emitted twice on prod-hub)")
+        sigs_mastertag(f"{upi_dir}/version.yaml", upi_dir)
+
     # Migration window: marker files are inert once the platform reads day1,
     # but while they still exist they must not contradict it. Legacy markers
     # carry the STREAM (4.16), day1 carries the full tag (4.16.27-x86_64).
@@ -544,6 +630,8 @@
         "defaults/hosted-clusters": ("hosted cluster", sorted(
             {posixpath.basename(d) for d in match_dirs("sites/*/*/mces/*/*")}
             - {"in-cluster"})),
+        "defaults/upi": ("UPI cluster", sorted(
+            posixpath.basename(d) for d in match_dirs("sites/*/*/upi/*"))),
     }
 
     for scope, (kind, names_known) in sorted(known.items()):
@@ -725,6 +813,9 @@
         if _split(o, "day1") != _split(n, "day1"):
             info.append(f"{uid}: day1 version files {_split(o, 'day1')} -> "
                         f"{_split(n, 'day1')}")
+        if _split(o, "version") != _split(n, "version"):
+            info.append(f"{uid}: UPI version file {_split(o, 'version')} -> "
+                        f"{_split(n, 'version')}")
         # The exclusion matrix decides whether apps EXIST, not what they
         # render. Its real effect shows up as APPS DISAPPEARED (HARD) on the
         # handful of apps actually excluded — reporting the file's own hash as
```

```diff
--- a/tools/ci/README.md
+++ b/tools/ci/README.md
@@ -34,7 +34,8 @@
 | check | what it catches |
 |---|---|
 | exclusion Rules 0–3 | a chart name or cluster name in `exclusions.yaml` that does not exist; a stray top-level key; a hub file |
-| day1 parity | an MCE or hosted-cluster folder with no day1 `mastertag` — i.e. **a stray folder that would become a phantom Application** |
+| day1 parity | an MCE or hosted-cluster folder with no day1 `mastertag` — i.e. **a stray folder that would become a phantom Application**. UPI folders have no day1 file and no parity check: a stray one shows only as an unexpected `apps added` line in `review` |
+| UPI folders | a UPI cluster folder named `in-cluster` or reusing an MCE / hosted-cluster name; a `version.yaml` in one that carries anything but a valid `mastertag` (the file itself is optional) |
 | DUPLICATE app | THE ONE INVARIANT — two generators emitting one app name (the XOR rule) |
 | DEPTH-AMBIGUOUS `files:` glob | the Phase B prod incident — a `files:` glob matching deeper than intended |
 | unsubstituted `{{ }}` | a placeholder that survived into a generated app |
@@ -44,7 +45,9 @@
 `compare` adds the second half: HARD on apps disappeared, identity changes
 (name / namespace / project / destination / repoURL / releaseName /
 syncPolicy), ref sources removed, or the resolved **sigs** value-file content
-stack changing. That is what turns an exclusion MR into a reviewable two-line
+stack changing. A UPI cluster's own `version.yaml` is bucketed like a day1
+file: changing it is INFO, as a version change is supposed to be. Apps handed
+to the UPI Argo instance are reported as `prod-hub-upi:<app>`. That is what turns an exclusion MR into a reviewable two-line
 `APPS DISAPPEARED` instead of a guess.
 
 ## Reading the result
```

---

## 6. Sigs repos

### 6.1 `defaults/upi/README.md` (optional)

Copy the mock's `sigs/redbull/defaults/upi/README.md` into each sigs repo that
will have UPI clusters, replacing `redbull` with the team name. It is the
working contract for the folder: rules, the structural opt-out, and the value
precedence. It is a plain file, so no generator sees it.

The folder `defaults/upi/` itself works like `defaults/hosted-clusters/`:
every chart folder in it deploys to every UPI cluster of the team, with
`values-<env>.yaml` and `values-<cluster>.yaml` overrides and an optional
`exclusions.yaml`.

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
5. Run the harness (§7.2) and read the `apps added` line.

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
  so any other key becomes a chart value. The harness rejects it.
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

```bash
# "before" snapshots are the ones from check 2, taken with BOTH repos at main.
python3 "$RENDER" snapshot --out /tmp/rv-after-<team> \
    --group <team> --sigs <sigs> --platform <platform> --day1 <day1>
python3 "$RENDER" compare /tmp/rv-before-<team> /tmp/rv-after-<team>
```

Run the pair once per sigs repo. The mock printed:

```
snapshot: 33 apps, 12 appset CRs -> /tmp/rv-before-redbull
snapshot: 34 apps, 13 appset CRs -> /tmp/rv-after-redbull
== compare /tmp/rv-before-redbull -> /tmp/rv-after-redbull ==
apps: 33 -> 34
  [info] apps added: ['prod-hub:redbull-upi-app-project']
IDENTITY OK: names, destinations, releaseNames, syncPolicies and resolved value-file contents are unchanged.
```

Read it as three assertions:

- **App count +1**, and the only added app is `prod-hub:<team>-upi-app-project`.
- **No other INFO line.** Any `labels` or `valueFiles` line here means a guard
  leaked into an existing render. Stop and diff the file against §4.
- **`IDENTITY OK`.** A `render aborted` line means a nil reached a template
  function. Stop.

The `snapshot:` line also shows one more ApplicationSet per team:
`<team>-upi`, with no apps.

### 7.2 After the first UPI cluster folder (step d)

The mock added `sites/site1/prod/upi/ocp4-dok-site1/` with a `version.yaml`
and one chart, `cluster-roles`. Compared with the step-b snapshot:

```
snapshot: 34 apps, 13 appset CRs -> /tmp/rv-after-redbull
snapshot: 37 apps, 14 appset CRs -> /tmp/rv-upi-redbull
== compare /tmp/rv-after-redbull -> /tmp/rv-upi-redbull ==
apps: 34 -> 37
  [info] apps added: ['prod-hub-upi:redbull-ocp4-dok-site1-cluster-roles', 'prod-hub-upi:redbull-ocp4-dok-site1-cluster-roles-deploy', 'prod-hub:redbull-ocp4-dok-site1']
IDENTITY OK: names, destinations, releaseNames, syncPolicies and resolved value-file contents are unchanged.
```

Expect exactly **1 + 2 × (charts in the folder + charts in `defaults/upi/`)**
added apps: the wrapper on `prod-hub`, and each chart's app and `-deploy` leaf
on `prod-hub-upi`. The ApplicationSet count grows by one,
`prod-hub-upi:<team>-<cluster>-operators`.

In the mock snapshot the leaf
`prod-hub-upi:redbull-ocp4-dok-site1-cluster-roles-deploy` has namespace
`openshift-gitops-upi`, destination `ocp4-dok-site1`, `releaseName:
cluster-roles`, labels with `role: upi` and `ocp-version: 4.16.27` and no
`mce`, and this 10-layer stack:

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

### 7.3 Live, after the first folder

```bash
oc get application <team>-<cluster> -n gitops-<team>                       # A: Synced
oc get applicationset <team>-<cluster>-operators -n openshift-gitops-upi   # B: exists
oc get applications -n openshift-gitops-upi -l day2.gitops/cluster=<cluster>
                                        # B: <team>-<cluster>-<chart> and -deploy, Synced/Healthy
```

The chart's resources exist on the UPI cluster. That is the check nothing
offline can make.

### 7.4 Probes run in the mock (all reverted)

| Probe | Result |
|---|---|
| a marker in `sites/site1/prod/upi/values.yaml` | one HARD: the leaf's sigs value sequence gains that file, and no other app changes |
| `mastertag` flipped to `4.20.9-x86_64` | INFO only: `UPI version file` on the wrapper, labels and `valueFiles` on the two chart apps; `IDENTITY OK` |
| `version.yaml` deleted | INFO only; the leaf stack drops to 9 layers and the `ocp-version` label is gone; `IDENTITY OK` |
| a second key in `version.yaml` | check failure: "a UPI version file carries `mastertag` and nothing else" |
| `defaults/upi/example-chart/` added | `apps added` ×2 on `prod-hub-upi` |
| then `defaults/upi/exclusions.yaml` naming the cluster | `APPS DISAPPEARED` ×2, `exclusion control file` INFO on the wrapper |
| the folder renamed to a hosted-cluster name | check failure: "reuses an MCE or hosted-cluster name" |
| a hosted cluster's day1 file removed (scratch copy of day1) | unchanged behaviour: parity failure and `mastertag missing` render abort |

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
copies in the air-gap:

| File | Change |
|---|---|
| `sigs/<team>/README.md` | `upi/` in the tree, naming rules, "what makes a folder a cluster", the version exception, value stacks, `defaults/upi/` |
| `sigs/<team>/defaults/upi/README.md` | new (§6.1) |
| `sigs/<team>/defaults/{mces,hub,hosted-clusters}/README.md` | link to `defaults/upi/` |
| `argocd-day2-platform/README.md` | four destination kinds, instance B, the two new templates, fork tables, values, labels, invariants |
| `ARCHITECTURE.md` | the same, plus runbook R11 "Add a UPI cluster" and the UPI case in R8 |
| `CHANGES.md` | a pointer to this guide |
| `tools/ci/README.md` | §5 |

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
                                                                  # -> 1 and 0 ($exKey only; never on .Values.upi)
grep -rn 'gitlab\|<GITLAB>' mces/ operators/ deploy/          # -> nothing (host replaced, §4)
git diff --stat origin/main -- mces/templates/appProjectAppset.yaml mces/templates/mcesAppset.yaml clusters/ groups/
                                                                  # -> nothing
```

Then the §7.1 compare for every team, and the §7.3 live check once the first
folder lands.
