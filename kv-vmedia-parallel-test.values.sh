# Values for kv-vmedia-parallel-test.sh (sourced as bash — no spaces around '=').
# Replace every CHANGE-ME; the script refuses to start while one is left.

# Cluster names; kubeconfigs are read from $KC_ROOT/<cluster-name>/auth/kubeconfig
KC_ROOT=/root/openshift4-installation
MCE_CLUSTER=CHANGE-ME                     # MCE hub: BMHs, NMStateConfigs, InfraEnv, Agents
KV_CLUSTER=CHANGE-ME                      # KubeVirt cluster: VMs, copy-iso pods, kubevirt-redfish

# The chart that creates every BMH + NMStateConfig + BMC Secret in one release.
# It is installed as-is: no --set, no values file.
BMH_CHART=/root/herzi/kubevirt-bmh
RELEASE=install-20-vms
HELM_NS=CHANGE-ME                         # namespace of the release on the hub (usually the InfraEnv namespace)
HELM_ARGS=()                              # extra args for helm template/install; empty = install as-is

# KubeVirt side
VM_NS=CHANGE-ME                           # namespace of the 20 pre-created VMs
RF_NS=CHANGE-ME                           # namespace of kubevirt-redfish
RF_DEPLOY=kubevirt-redfish                # deployment name of kubevirt-redfish

# Hub side, read only: BMO/Ironic settings and logs, assisted-service log
BMO_NS=openshift-machine-api
ASSISTED_NS=multicluster-engine

RESULTS_DIR=./results                     # one sub-directory per run
POLL=10                                   # s between progress lines
MAX_WAIT=5400                             # s after helm install before the run stops anyway
POST_WAIT=180                             # s to keep recording after every host has an Agent (catches ejects)
