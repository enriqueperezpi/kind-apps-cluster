#!/usr/bin/env bash
# tools.sh — detect and optionally install required CLI tools
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

# List of required tools
REQUIRED_TOOLS=(kind kubectl helm)

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

detect_pkg_manager() {
  local os
  os=$(detect_os)
  case "$os" in
    macos)
      if command -v brew &>/dev/null; then
        echo "brew"
      else
        echo "none"
      fi
      ;;
    linux)
      if command -v apt-get &>/dev/null; then
        echo "apt"
      elif command -v dnf &>/dev/null; then
        echo "dnf"
      elif command -v yum &>/dev/null; then
        echo "yum"
      else
        echo "none"
      fi
      ;;
    *)
      echo "none"
      ;;
  esac
}

is_tool_installed() {
  command -v "$1" &>/dev/null
}

install_kind() {
  local os
  os=$(detect_os)
  log_info "Installing kind…"

  if [[ "$os" == "macos" ]] && command -v brew &>/dev/null; then
    brew install kind
  else
    local arch
    arch=$(uname -m)
    case "$arch" in
      x86_64)  arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
    esac
    curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/v0.24.0/kind-${os}-${arch}"
    chmod +x /usr/local/bin/kind
  fi
  log_success "kind installed."
}

install_kubectl() {
  local os
  os=$(detect_os)
  log_info "Installing kubectl…"

  if [[ "$os" == "macos" ]] && command -v brew &>/dev/null; then
    brew install kubectl
  else
    local arch
    arch=$(uname -m)
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/${os}/${arch}/kubectl"
    chmod +x /usr/local/bin/kubectl
  fi
  log_success "kubectl installed."
}

install_helm() {
  log_info "Installing helm…"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log_success "helm installed."
}

install_tool() {
  local tool="$1"
  case "$tool" in
    kind)     install_kind ;;
    kubectl)  install_kubectl ;;
    helm)     install_helm ;;
    *)
      log_error "Don't know how to install '${tool}'."
      return 1
      ;;
  esac
}

check_and_install_tools() {
  local missing=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! is_tool_installed "$tool"; then
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_success "All required tools are installed."
    return 0
  fi

  log_warn "Missing tools: ${missing[*]}"

  if [[ "${AUTO_INSTALL_TOOLS:-true}" != "true" ]]; then
    log_error "AUTO_INSTALL_TOOLS is disabled. Install manually and retry."
    return 1
  fi

  for tool in "${missing[@]}"; do
    install_tool "$tool"
  done
}

print_tool_versions() {
  echo ""
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if is_tool_installed "$tool"; then
      printf "  %-12s %s\n" "$tool:" "$($tool version 2>&1 | head -1)"
    else
      printf "  %-12s %s\n" "$tool:" "${RED}not installed${NC}"
    fi
  done
  echo ""
}
