#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--apply] [--mode local|vps|both] [--yes]

Default is dry-run (no changes). Use --apply to install.
--mode local|vps|both  Installs only what that environment needs.
--yes                 Skip confirmation prompts for major changes.
EOF
}

log() { echo "[setup] $*"; }
warn() { echo "[setup][warn] $*" >&2; }
die() { echo "[setup][error] $*" >&2; exit 1; }

APPLY="false"
MODE="both"
YES="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true" ;;
    --mode)
      MODE="${2:-}"
      shift
      ;;
    --yes) YES="true" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

case "$MODE" in
  local|vps|both) ;;
  *) die "Invalid --mode: $MODE (use local|vps|both)" ;;
esac

run() {
  if [[ "$APPLY" == "true" ]]; then
    log "RUN: $*"
    eval "$@"
  else
    log "DRY-RUN: $*"
  fi
}

confirm() {
  if [[ "$YES" == "true" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ver_to_int() {
  local v="${1#v}"
  IFS='.' read -r a b c <<<"$v"
  printf "%03d%03d%03d" "${a:-0}" "${b:-0}" "${c:-0}"
}

version_ge() {
  [[ "$(ver_to_int "$1")" -ge "$(ver_to_int "$2")" ]]
}

OS_NAME="$(uname -s)"
if [[ "${OS:-}" == "Windows_NT" ]] || [[ "$OS_NAME" =~ MINGW|MSYS|CYGWIN ]]; then
  cat <<'EOF'
Windows detected.
This setup script does not install system dependencies on native Windows.
Recommended: install WSL2 (Ubuntu 22.04), clone the repo inside WSL, then run:

  ./setup.sh --apply --mode both

EOF
  exit 1
fi

if [[ "$OS_NAME" == "Darwin" ]]; then
  die "macOS detected. This script currently supports Linux only."
fi

if [[ "$OS_NAME" != "Linux" ]]; then
  die "Unsupported OS: $OS_NAME"
fi

if [[ ! -f /etc/os-release ]]; then
  die "Cannot detect Linux distribution (/etc/os-release missing)."
fi

source /etc/os-release
DIST_ID="${ID:-unknown}"
DIST_LIKE="${ID_LIKE:-}"

IS_DEBIAN="false"
IS_FEDORA="false"
if [[ "$DIST_ID" =~ (ubuntu|debian) ]] || [[ "$DIST_LIKE" =~ debian ]]; then
  IS_DEBIAN="true"
elif [[ "$DIST_ID" =~ (fedora|rhel|centos) ]] || [[ "$DIST_LIKE" =~ rhel|fedora ]]; then
  IS_FEDORA="true"
fi

if [[ "$IS_DEBIAN" != "true" && "$IS_FEDORA" != "true" ]]; then
  die "Unsupported Linux distro: $DIST_ID"
fi

REQ_GO_VERSION="1.25.0"
if [[ -f "$ROOT_DIR/orchestrator/go.mod" ]]; then
  REQ_GO_VERSION="$(awk '/^go /{print $2; exit}' "$ROOT_DIR/orchestrator/go.mod" || echo "1.25.0")"
fi
REQ_NODE_MAJOR="20"

install_base_debian() {
  run "sudo apt-get update -y"
  run "sudo apt-get install -y curl ca-certificates git jq python3 python3-venv build-essential unzip"
}

install_base_fedora() {
  run "sudo dnf -y install curl ca-certificates git jq python3 python3-virtualenv gcc gcc-c++ make unzip"
}

install_docker_debian() {
  if confirm "Install Docker (docker.io) and enable service?"; then
    run "sudo apt-get install -y docker.io"
    run "sudo systemctl enable --now docker"
    run "sudo usermod -aG docker \"$USER\""
    log "Docker installed. You may need to log out/in for group changes."
  else
    warn "Skipping Docker install."
  fi
}

install_docker_fedora() {
  warn "Auto-install for Docker on Fedora is not guaranteed."
  warn "Recommended: follow Docker Engine official install docs for Fedora."
}

install_kubectl() {
  if confirm "Install kubectl (latest stable) to /usr/local/bin?"; then
    run "curl -fsSL -o /tmp/kubectl https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    run "sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl"
  else
    warn "Skipping kubectl install."
  fi
}

install_helm() {
  if confirm "Install Helm v3 (official script)?"; then
    run "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  else
    warn "Skipping Helm install."
  fi
}

install_k3d() {
  if confirm "Install k3d (official script)?"; then
    run "curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
  else
    warn "Skipping k3d install."
  fi
}

install_k3s() {
  if confirm "Install k3s (single-node) and start service?"; then
    run "curl -fsSL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644"
  else
    warn "Skipping k3s install."
  fi
}

install_go() {
  if confirm "Install Go ${REQ_GO_VERSION} to /usr/local/go?"; then
    run "curl -fsSL -o /tmp/go.tgz https://go.dev/dl/go${REQ_GO_VERSION}.linux-amd64.tar.gz"
    if [[ -d /usr/local/go ]]; then
      local ts
      ts="$(date +%Y%m%d%H%M%S)"
      if confirm "Existing /usr/local/go will be moved to /usr/local/go.bak.${ts}. Proceed?"; then
        run "sudo mv /usr/local/go /usr/local/go.bak.${ts}"
      else
        warn "Skipping Go install."
        return
      fi
    fi
    run "sudo tar -C /usr/local -xzf /tmp/go.tgz"
    if ! grep -q '/usr/local/go/bin' "$HOME/.bashrc" 2>/dev/null; then
      run "echo 'export PATH=\$PATH:/usr/local/go/bin' >> \"$HOME/.bashrc\""
      log "Added /usr/local/go/bin to ~/.bashrc. Reload your shell."
    fi
  else
    warn "Skipping Go install."
  fi
}

install_node_debian() {
  if confirm "Install Node.js ${REQ_NODE_MAJOR}.x (NodeSource) + npm?"; then
    run "curl -fsSL https://deb.nodesource.com/setup_${REQ_NODE_MAJOR}.x | sudo -E bash -"
    run "sudo apt-get install -y nodejs"
  else
    warn "Skipping Node.js install."
  fi
}

install_node_fedora() {
  if confirm "Install Node.js ${REQ_NODE_MAJOR}.x (dnf module) + npm?"; then
    run "sudo dnf -y module reset nodejs"
    run "sudo dnf -y module enable nodejs:${REQ_NODE_MAJOR}"
    run "sudo dnf -y install nodejs"
  else
    warn "Skipping Node.js install."
  fi
}

check_and_install_base() {
  if [[ "$IS_DEBIAN" == "true" ]]; then
    install_base_debian
  else
    install_base_fedora
  fi
}

check_tools() {
  local dry_run="true"
  if [[ "$APPLY" == "true" ]]; then dry_run="false"; fi
  log "Mode: $MODE (dry-run: $dry_run)"
  log "Required Go: $REQ_GO_VERSION, Node: $REQ_NODE_MAJOR.x"

  if [[ "$MODE" == "local" || "$MODE" == "both" ]]; then
    log "Local prerequisites: docker, kubectl, helm, k3d, go, node, npm"
  fi
  if [[ "$MODE" == "vps" || "$MODE" == "both" ]]; then
    log "VPS prerequisites: k3s, kubectl, go, node, npm (docker recommended)"
  fi
}

main() {
  check_and_install_base

  if ! has_cmd go; then
    install_go
  else
    GO_VER="$(go version | awk '{print $3}' | sed 's/^go//')"
    if ! version_ge "$GO_VER" "$REQ_GO_VERSION"; then
      warn "Go $GO_VER found, but project requires >= $REQ_GO_VERSION."
      install_go
    else
      log "Go $GO_VER OK."
    fi
  fi

  if ! has_cmd node; then
    if [[ "$IS_DEBIAN" == "true" ]]; then
      install_node_debian
    else
      install_node_fedora
    fi
  else
    NODE_VER="$(node -v | sed 's/^v//')"
    NODE_MAJOR="${NODE_VER%%.*}"
    if [[ "$NODE_MAJOR" -lt "$REQ_NODE_MAJOR" ]]; then
      warn "Node $NODE_VER found, but project requires >= ${REQ_NODE_MAJOR}.x."
      if [[ "$IS_DEBIAN" == "true" ]]; then
        install_node_debian
      else
        install_node_fedora
      fi
    else
      log "Node $NODE_VER OK."
    fi
  fi

  if [[ "$MODE" == "local" || "$MODE" == "both" ]]; then
    if ! has_cmd docker; then
      if [[ "$IS_DEBIAN" == "true" ]]; then
        install_docker_debian
      else
        install_docker_fedora
      fi
    else
      log "Docker OK."
    fi

    if ! has_cmd kubectl; then install_kubectl; else log "kubectl OK."; fi
    if ! has_cmd helm; then install_helm; else log "Helm OK."; fi
    if ! has_cmd k3d; then install_k3d; else log "k3d OK."; fi
  fi

  if [[ "$MODE" == "vps" || "$MODE" == "both" ]]; then
    if ! has_cmd k3s; then install_k3s; else log "k3s OK."; fi
    if ! has_cmd kubectl; then install_kubectl; else log "kubectl OK."; fi
    if ! has_cmd docker; then
      warn "Docker not found. VPS can run without local image build, but local builds will fail."
    fi
  fi

  cat <<EOF

Setup complete (mode: $MODE).
If you installed Docker, you may need to log out/in for group changes.
EOF
}

check_tools
main
