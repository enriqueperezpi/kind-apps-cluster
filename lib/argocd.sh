#!/usr/bin/env bash
# argocd.sh — ArgoCD deployment and management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

# ArgoCD version resolution
get_argocd_version() {
  local version="${ARGOCD_VERSION:-stable}"
  
  if [[ "$version" == "stable" ]] || [[ -z "$version" ]]; then
    # Fetch latest stable release tag from GitHub
    version=$(curl -s "https://api.github.com/repos/argoproj/argo-cd/releases/latest" 2>/dev/null | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || echo "stable")
    if [[ -z "$version" ]] || [[ "$version" == "stable" ]]; then
      version="v2.14.0"  # Fallback to known stable version
    fi
  elif [[ "$version" == "latest" ]]; then
    version=$(curl -s "https://api.github.com/repos/argoproj/argo-cd/releases" 2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "latest")
    if [[ -z "$version" ]] || [[ "$version" == "latest" ]]; then
      version="v2.15.0"  # Fallback to latest known version
    fi
  fi
  
  echo "$version"
}

_argocd_installed() {
  kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null && \
    kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" &>/dev/null
}

install_argocd() {
  # Resolve version first
  local resolved_version
  resolved_version=$(get_argocd_version)
  log_info "Using ArgoCD version: ${resolved_version}"
  
  # Always install ApplicationSet CRD first (required for applicationset-controller)
  if kubectl get crd applicationsets.argoproj.io &>/dev/null; then
    log_info "ApplicationSet CRD already installed."
  else
    log_info "Installing ApplicationSet CRD…"
    kubectl apply -f "https://raw.githubusercontent.com/argoproj/argo-cd/${resolved_version}/manifests/crds/applicationset-crd.yaml"
  fi

  if _argocd_installed; then
    log_warn "ArgoCD is already installed in '${ARGOCD_NAMESPACE}'. Upgrading to ensure consistency…"
    # Re-apply the manifest to ensure all components are up to date
    local manifest="https://raw.githubusercontent.com/argoproj/argo-cd/${resolved_version}/manifests/install.yaml"
    log_info "Re-applying ArgoCD manifest…"
    kubectl apply -n "$ARGOCD_NAMESPACE" -f "$manifest" 2>&1 | grep -v "unchanged" || true
  else
    log_info "Creating namespace '${ARGOCD_NAMESPACE}'…"
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply ArgoCD manifest
    local manifest="https://raw.githubusercontent.com/argoproj/argo-cd/${resolved_version}/manifests/install.yaml"
    log_info "Applying ArgoCD manifest…"
    
    # Apply with retry (ArgoCD can take time to be fully ready)
    local max_retries=3
    local retry=0
    while [[ $retry -lt $max_retries ]]; do
      if kubectl apply -n "$ARGOCD_NAMESPACE" -f "$manifest" 2>&1 | tee /dev/stderr | grep -q "error"; then
        ((retry++)) || true
        log_warn "Retry ${retry}/${max_retries}…"
        sleep 5
      else
        break
      fi
    done
  fi

  log_info "Waiting for ArgoCD server to be ready…"
  wait_for_deployment "$ARGOCD_NAMESPACE" "argocd-server" 600

  log_info "Waiting for remaining ArgoCD pods…"
  wait_for_pods_ready "$ARGOCD_NAMESPACE" "" 300

  log_success "ArgoCD ${resolved_version} deployed."
}

patch_argocd_server() {
  if ! _argocd_installed; then
    log_error "ArgoCD is not installed."
    return 1
  fi

  log_info "Configuring ArgoCD server for HTTP mode…"

  # Configure server for insecure mode (HTTP)
  kubectl apply -n "$ARGOCD_NAMESPACE" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
data:
  server.insecure: "true"
EOF

  # Restart server to pick up the config change
  log_info "Restarting ArgoCD server…"
  kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server
  wait_for_deployment "$ARGOCD_NAMESPACE" "argocd-server" 300

  log_success "ArgoCD server configured for HTTP mode."
}

# ── ArgoCD Apps Management ────────────────────────────────────────────────────

# Check if app is enabled (YAML is not commented out)
is_app_enabled() {
  local app_dir="$1"
  local app_file
  
  # Find the application file
  if [[ -f "${app_dir}/application.yaml" ]]; then
    app_file="${app_dir}/application.yaml"
  elif [[ -f "${app_dir}/application.yml" ]]; then
    app_file="${app_dir}/application.yml"
  else
    return 1
  fi
  
  # Check if file has non-commented content (lines not starting with #)
  # A valid YAML app has at least one line that doesn't start with # or whitespace
  if grep -v '^[[:space:]]*#' "$app_file" | grep -v '^[[:space:]]*$' | grep -q '^[[:space:]]*apiVersion:'; then
    return 0
  fi
  return 1
}

# List all apps in argocd-apps directory
list_argocd_apps() {
  local apps_dir="${ARGOCD_APPS_DIR:-./argocd-apps}"
  
  if [[ ! -d "$apps_dir" ]]; then
    log_warn "Apps directory '${apps_dir}' not found."
    return 0
  fi

  # Find all directories with application.yaml
  local apps=()
  while IFS= read -r -d '' app_file; do
    local app_dir
    app_dir=$(dirname "$app_file")
    local app_name
    app_name=$(basename "$app_dir")
    apps+=("$app_name")
  done < <(find "$apps_dir" \( -name 'application.yaml' -o -name 'application.yml' \) -print0 | sort -z)

  if [[ ${#apps[@]} -eq 0 ]]; then
    log_info "No applications found in '${apps_dir}'."
    log_info "Create apps as: ${apps_dir}/<app-name>/application.yaml"
    return 0
  fi

  echo ""
  echo "Available Applications in ${apps_dir}:"
  echo "============================================"
  
  for app in "${apps[@]}"; do
    local app_dir="${apps_dir}/${app}"
    local status="disabled"
    local has_httproute=""
    
    if is_app_enabled "$app_dir"; then
      status="enabled"
    fi
    
    # Check for httproute
    if [[ -f "${app_dir}/httproute.yaml" ]] || [[ -f "${app_dir}/httproute.yml" ]]; then
      has_httproute=" [route]"
    fi
    
    echo "  ${app}${has_httproute} - ${status}"
  done
  
  echo ""
  echo "Use CLI to manage apps:"
  echo "  ./setup.sh --list-apps           List apps"
  echo "  ./setup.sh --enable <app>       Enable (uncomment YAML)"
  echo "  ./setup.sh --disable <app>      Disable (comment YAML)"
  echo ""
}

# Apply only enabled apps
apply_argocd_apps() {
  local apps_dir="${ARGOCD_APPS_DIR:-./argocd-apps}"
  
  if [[ ! -d "$apps_dir" ]]; then
    log_warn "Apps directory '${apps_dir}' not found — skipping."
    return 0
  fi

  # Check if ArgoCD is installed
  if ! _argocd_installed; then
    log_error "ArgoCD is not installed. Install it first (option 4)."
    return 1
  fi

  # Find all application.yaml files
  local app_count=0
  local skipped_count=0
  local total_count=0
  
  while IFS= read -r -d '' app_file; do
    local app_dir
    app_dir=$(dirname "$app_file")
    local app_name
    app_name=$(basename "$app_dir")
    ((total_count++)) || true
    
    # Check if app is enabled
    if ! is_app_enabled "$app_dir"; then
      log_info "  - ${app_name} [disabled, skipping]"
      ((skipped_count++)) || true
      continue
    fi
    
    log_info "  -> ${app_name}"
    local apply_output
    apply_output=$(kubectl apply -f "$app_file" 2>&1)
    local apply_status=$?
    if [[ $apply_status -eq 0 ]]; then
      echo "     ${apply_output}" | head -1
      ((app_count++)) || true
    else
      log_error "    Failed to apply ${app_name}"
      echo "    Error: ${apply_output}" | head -5
    fi
  done < <(find "$apps_dir" \( -name 'application.yaml' -o -name 'application.yml' \) -print0)
  
  echo ""
  if [[ $app_count -gt 0 ]]; then
    log_success "Applied ${app_count} application(s)"
  fi
  if [[ $skipped_count -gt 0 ]]; then
    log_info "Skipped ${skipped_count} disabled application(s)"
  fi
  
  if [[ $app_count -gt 0 ]]; then
    log_info "Apps will sync automatically. Check status with:"
    log_info "  argocd app list"
    log_info "  kubectl get applications -n ${ARGOCD_NAMESPACE}"
  fi
}

# Enable an app (uncomment YAML)
enable_argocd_app() {
  local app_name="${1:-}"
  local apps_dir="${ARGOCD_APPS_DIR:-./argocd-apps}"
  
  if [[ -z "$app_name" ]]; then
    list_argocd_apps
    return 0
  fi
  
  local app_dir="${apps_dir}/${app_name}"
  local app_file=""
  
  if [[ ! -d "$app_dir" ]]; then
    log_error "Application '${app_name}' not found in '${apps_dir}'."
    return 1
  fi
  
  if [[ -f "${app_dir}/application.yaml" ]]; then
    app_file="${app_dir}/application.yaml"
  elif [[ -f "${app_dir}/application.yml" ]]; then
    app_file="${app_dir}/application.yml"
  else
    log_error "No application.yaml or application.yml found in '${app_dir}'."
    return 1
  fi
  
  # Check if already enabled
  if is_app_enabled "$app_dir"; then
    log_info "Application '${app_name}' is already enabled."
    return 0
  fi
  
  # Uncomment YAML content using sed (macOS compatible)
  local tmp_file
  tmp_file=$(mktemp)
  sed 's/^# //' "$app_file" > "$tmp_file"
  mv "$tmp_file" "$app_file"
  
  log_success "Enabled application '${app_name}'"
  log_info "Apply with option 5 or run: kubectl apply -f ${app_file}"
}

# Disable an app (comment YAML)
disable_argocd_app() {
  local app_name="${1:-}"
  local apps_dir="${ARGOCD_APPS_DIR:-./argocd-apps}"
  
  if [[ -z "$app_name" ]]; then
    list_argocd_apps
    return 0
  fi
  
  local app_dir="${apps_dir}/${app_name}"
  local app_file=""
  
  if [[ ! -d "$app_dir" ]]; then
    log_error "Application '${app_name}' not found in '${apps_dir}'."
    return 1
  fi
  
  if [[ -f "${app_dir}/application.yaml" ]]; then
    app_file="${app_dir}/application.yaml"
  elif [[ -f "${app_dir}/application.yml" ]]; then
    app_file="${app_dir}/application.yml"
  else
    log_error "No application.yaml or application.yml found in '${app_dir}'."
    return 1
  fi
  
  # Check if already disabled
  if ! is_app_enabled "$app_dir"; then
    log_info "Application '${app_name}' is already disabled."
    return 0
  fi
  
  # Comment YAML content (add # to non-comment, non-empty lines)
  local tmp_file
  tmp_file=$(mktemp)
  
  while IFS= read -r line; do
    # If line is empty or only whitespace, keep as-is
    if [[ -z "${line// }" ]]; then
      echo "$line"
    # If line already starts with # (possibly with whitespace), keep as-is
    elif [[ "$line" =~ ^[[:space:]]*# ]]; then
      echo "$line"
    else
      echo "# $line"
    fi
  done < "$app_file" > "$tmp_file"
  
  mv "$tmp_file" "$app_file"
  
  log_success "Disabled application '${app_name}'"
  log_info "It will be skipped on next apply"
  
  # Optionally remove from cluster
  log_info "To also remove from cluster, run:"
  log_info "  kubectl delete -f ${app_file}"
}

argocd_admin_password() {
  if ! _argocd_installed; then
    log_error "ArgoCD is not installed."
    return 1
  fi

  local pw
  pw=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [[ -z "$pw" ]]; then
    log_warn "Could not retrieve ArgoCD admin password."
    log_info "Password may not be available yet. Wait for ArgoCD to be fully ready."
    return 1
  fi

  echo ""
  echo -e "  ${BOLD}ArgoCD Admin Credentials${NC}"
  echo "  ─────────────────────────────────"
  echo "  User:     admin"
  echo "  Password: ${pw}"
  echo ""
}

argocd_status() {
  if ! _argocd_installed; then
    log_warn "ArgoCD is not installed."
    return 0
  fi

  echo ""
  echo "  ArgoCD Status:"
  echo "  ─────────────────────────────────"
  
  # Pod status
  local pod_count
  local pod_ready
  pod_count=$(kubectl get pods -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pod_ready=$(kubectl get pods -n "$ARGOCD_NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  
  echo "  Pods: ${pod_ready}/${pod_count} running"
  
  # ArgoCD version
  local version
  version=$(kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed -n 's/.*:v\([0-9][0-9.]*\).*/v\1/p' | head -1)
  echo "  Version: ${version:-unknown}"
  
  # Server URL
  echo ""
  echo "  Access:"
  echo "  - Local: kubectl port-forward -n ${ARGOCD_NAMESPACE} svc/argocd-server 8080:80"
  echo "  - Or visit: http://localhost:8080"
  echo "  - Get password: ./setup.sh (option 7)"
  
  # List local applications (from argocd-apps folder)
  local apps_dir="${ARGOCD_APPS_DIR:-./argocd-apps}"
  local local_apps=()
  while IFS= read -r -d '' app_file; do
    local app_dir
    app_dir=$(dirname "$app_file")
    local app_name
    app_name=$(basename "$app_dir")
    local status="disabled"
    if is_app_enabled "$app_dir"; then
      status="enabled"
    fi
    local_apps+=("${app_name}:${status}")
  done < <(find "$apps_dir" \( -name 'application.yaml' -o -name 'application.yml' \) -print0 2>/dev/null)
  
  if [[ ${#local_apps[@]} -gt 0 ]]; then
    echo ""
    echo "  Local Apps (argocd-apps/):"
    for app_info in "${local_apps[@]}"; do
      local name="${app_info%%:*}"
      local status="${app_info##*:}"
      local icon="○"
      if [[ "$status" == "enabled" ]]; then
        icon="●"
      fi
      echo "    ${icon} ${name} (${status})"
    done
    echo ""
    echo "  Managed Apps (in cluster):"
  fi
  
  # List deployed applications
  local app_count
  app_count=$(kubectl get applications -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$app_count" -gt 0 ]]; then
    kubectl get applications -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
      echo "    $line"
    done
  else
    echo "    (none deployed)"
  fi
}
