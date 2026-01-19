#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: n8
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/actions/runner

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  ca-certificates \
  curl \
  jq \
  git \
  gnupg \
  lsb-release \
  python3 \
  python3-pip \
  python3-venv \
  build-essential \
  libssl-dev \
  libffi-dev \
  libicu-dev \
  libkrb5-dev \
  zlib1g-dev
msg_ok "Installed Dependencies"

msg_info "Creating runner user"
if ! id -u runner >/dev/null 2>&1; then
  useradd -m -s /bin/bash runner
fi
msg_ok "Runner user ready"

msg_info "Installing Docker"
DOCKER_LOG_DRIVER="journald" setup_docker
usermod -aG docker runner
msg_ok "Installed Docker"

msg_info "Installing Node.js and Claude Code"
NODE_VERSION="22" NODE_MODULE="@anthropic-ai/claude-code" setup_nodejs
msg_ok "Installed Node.js and Claude Code"

msg_info "Installing Python tooling"
PYTHON_VERSION="3.12" setup_uv
if ! su - runner -c "/usr/local/bin/uv python install 3.12"; then
  msg_warn "uv Python install failed; falling back to system python"
fi
if [[ -x /home/runner/.local/bin/python3.12 ]]; then
  mkdir -p /home/runner/.local/bin
  ln -sf /home/runner/.local/bin/python3.12 /home/runner/.local/bin/python3
  chown -h runner:runner /home/runner/.local/bin/python3
fi
msg_ok "Installed Python tooling"

msg_info "Installing Go"
setup_go
msg_ok "Installed Go"

msg_info "Installing Rust (runner user)"
if [[ -x /home/runner/.cargo/bin/rustup ]]; then
  su - runner -c "/home/runner/.cargo/bin/rustup update stable" >/dev/null 2>&1 || true
else
  su - runner -c "curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable"
fi
msg_ok "Installed Rust"

msg_info "Configuring GitHub Runner"

case "$(uname -m)" in
  x86_64) RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  armv7l | armv6l) RUNNER_ARCH="arm" ;;
  *)
    msg_error "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

if [[ -z "${GH_ORG:-}" || -z "${GH_PAT:-}" ]]; then
  if [[ ! -t 0 ]]; then
    msg_error "No TTY available for prompts. Set GH_ORG and GH_PAT env vars and rerun."
    exit 1
  fi
fi

if [[ -z "${GH_ORG:-}" ]]; then
  while true; do
    read -r -p "${TAB3}Enter GitHub Organization name: " GH_ORG
    [[ -n "$GH_ORG" ]] && break
    echo -e "${TAB3}${RD}Organization name cannot be empty${CL}"
  done
fi

if [[ -z "${GH_PAT:-}" ]]; then
  while true; do
    read -r -s -p "${TAB3}Enter GitHub PAT (admin:org scope): " GH_PAT
    echo
    [[ -n "$GH_PAT" ]] && break
    echo -e "${TAB3}${RD}PAT cannot be empty${CL}"
  done
fi

if [[ -z "${RUNNER_NAME:-}" ]]; then
  read -r -p "${TAB3}Runner name [$(hostname)]: " RUNNER_NAME
  RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
fi

if [[ -z "${RUNNER_LABELS:-}" ]]; then
  read -r -p "${TAB3}Runner labels [self-hosted,linux,${RUNNER_ARCH}]: " RUNNER_LABELS
  RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,${RUNNER_ARCH}}"
fi

msg_info "Fetching registration token from GitHub"
REG_TOKEN=$(curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_PAT}" \
  "https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token" 2>/dev/null | jq -r '.token')

if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  msg_error "Failed to get registration token. Check PAT permissions (admin:org scope required)."
  exit 1
fi
msg_ok "Obtained registration token"

msg_info "Downloading GitHub Actions Runner"
RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
if [[ -z "$RUNNER_VERSION" || "$RUNNER_VERSION" == "null" ]]; then
  msg_error "Failed to fetch runner version from GitHub"
  exit 1
fi

RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

mkdir -p /opt/actions-runner
cd /opt/actions-runner
$STD curl -fsSL -o runner.tar.gz "$RUNNER_URL"
$STD tar xzf runner.tar.gz
rm runner.tar.gz
$STD ./bin/installdependencies.sh
chown -R runner:runner /opt/actions-runner
msg_ok "Downloaded GitHub Actions Runner v${RUNNER_VERSION}"

msg_info "Configuring runner"
su - runner -c "cd /opt/actions-runner && ./config.sh --unattended \
  --url https://github.com/${GH_ORG} \
  --token ${REG_TOKEN} \
  --name \"${RUNNER_NAME}\" \
  --labels \"${RUNNER_LABELS}\" \
  --replace \
  --runnergroup Default \
  --work _work"
msg_ok "Configured runner"

cat <<EOF >/opt/actions-runner/.env
GH_ORG=${GH_ORG}
RUNNER_NAME=${RUNNER_NAME}
RUNNER_LABELS=${RUNNER_LABELS}
EOF
chmod 400 /opt/actions-runner/.env

unset GH_PAT
unset REG_TOKEN

echo "${RUNNER_VERSION}" >/root/.github-runner

msg_info "Installing Service"
cd /opt/actions-runner
./svc.sh install runner

SERVICE_NAME=$(cat /opt/actions-runner/.service 2>/dev/null || true)
if [[ -n "$SERVICE_NAME" ]]; then
  SERVICE_DROPIN="/etc/systemd/system/${SERVICE_NAME}.d"
  mkdir -p "$SERVICE_DROPIN"
  cat <<EOF >"${SERVICE_DROPIN}/override.conf"
[Unit]
After=docker.service
Wants=docker.service

[Service]
Environment=PATH=/home/runner/.cargo/bin:/home/runner/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Restart=always
RestartSec=10
EOF
  systemctl daemon-reload
fi

if [[ -n "$SERVICE_NAME" ]]; then
  systemctl start "$SERVICE_NAME"
else
  ./svc.sh start
fi
msg_ok "Installed Service"

motd_ssh
customize
cleanup_lxc
