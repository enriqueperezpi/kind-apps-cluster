#!/usr/bin/env bash
# kind.sh — kind cluster lifecycle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

_cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

# Check if the Docker container for the control-plane is actually running
_cluster_healthy() {
  if ! _cluster_exists; then
    return 1
  fi
  local node="${CLUSTER_NAME}-control-plane"
  docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null | grep -q "true"
}

generate_kind_config() {
  # Check if using Cilium CNI
  local cni_plugin=""
  if [[ "${CNI_PLUGIN:-kind}" == "cilium" ]]; then
    cni_plugin="none"
  fi

  cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  disableDefaultCNI: $([[ "$cni_plugin" == "none" ]] && echo "true" || echo "false")
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
        cni-bin-dir: $([[ "$cni_plugin" == "none" ]] && echo "/opt/cni/bin" || echo "")
  extraMounts:
  - hostPath: /sys/kernel/bpf
    containerPath: /sys/kernel/bpf
    readOnly: true
  - hostPath: /run/cilium
    containerPath: /run/cilium
  extraPortMappings:
  - containerPort: 80
    hostPort: ${HTTP_PORT}
    protocol: TCP
    listenAddress: "0.0.0.0"
  - containerPort: 443
    hostPort: ${HTTPS_PORT}
    protocol: TCP
    listenAddress: "0.0.0.0"
EOF

  for i in $(seq 1 "${WORKER_NODES}"); do
    cat <<EOF
- role: worker
  extraMounts:
  - hostPath: /sys/kernel/bpf
    containerPath: /sys/kernel/bpf
    readOnly: true
  - hostPath: /run/cilium
    containerPath: /run/cilium
EOF
  done
}

create_cluster() {
  if _cluster_healthy; then
    log_warn "Cluster '${CLUSTER_NAME}' already exists and is healthy — skipping creation."
    return 0
  fi

  # Cluster exists but container is dead — clean up first
  if _cluster_exists; then
    log_warn "Cluster '${CLUSTER_NAME}' exists but is not healthy — deleting and recreating…"
    kind delete cluster --name "$CLUSTER_NAME"
  fi

  log_info "Creating kind cluster '${CLUSTER_NAME}' (k8s ${K8S_VERSION})…"

  local config_file
  config_file=$(mktemp)
  generate_kind_config > "$config_file"

  kind create cluster \
    --name "$CLUSTER_NAME" \
    --image "kindest/node:${K8S_VERSION}" \
    --config "$config_file" \
    --wait 120s

  rm -f "$config_file"
  log_success "Cluster '${CLUSTER_NAME}' created."
}

delete_cluster() {
  if ! _cluster_exists; then
    log_warn "Cluster '${CLUSTER_NAME}' does not exist — nothing to delete."
    return 0
  fi

  if confirm "Delete cluster '${CLUSTER_NAME}'?"; then
    kind delete cluster --name "$CLUSTER_NAME"
    log_success "Cluster '${CLUSTER_NAME}' deleted."
  fi
}

ensure_kubeconfig() {
  if ! _cluster_exists; then
    log_error "Cluster '${CLUSTER_NAME}' does not exist. Create it first."
    return 1
  fi

  if ! _cluster_healthy; then
    log_error "Cluster '${CLUSTER_NAME}' exists but its container is not running."
    log_error "Delete it first (option 9) and recreate."
    return 1
  fi

  local context="kind-${CLUSTER_NAME}"
  local kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"

  log_info "Setting kubeconfig context to '${context}'…"
  kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$kubeconfig"

  # Explicitly switch to the kind context
  kubectl config use-context "$context" --kubeconfig "$kubeconfig"

  # Verify the API server is reachable
  if ! kubectl cluster-info &>/dev/null; then
    log_warn "API server not ready yet — waiting 10s and retrying…"
    sleep 10
    if ! kubectl cluster-info &>/dev/null; then
      log_error "API server still unreachable. The cluster may be broken."
      log_error "Try: kind delete cluster --name ${CLUSTER_NAME} && re-run setup."
      return 1
    fi
  fi

  log_success "kubeconfig set to '${context}'."
}

cluster_status() {
  if _cluster_healthy; then
    log_success "Cluster '${CLUSTER_NAME}' is running."
    echo ""
    kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || true
    echo ""
    kubectl get nodes -o wide 2>/dev/null || true
  elif _cluster_exists; then
    log_warn "Cluster '${CLUSTER_NAME}' exists but is NOT healthy (container stopped)."
  else
    log_warn "Cluster '${CLUSTER_NAME}' does not exist."
  fi
}
