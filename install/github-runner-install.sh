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
  curl \
  jq \
  git \
  build-essential \
  libssl-dev \
  libffi-dev \
  libicu-dev \
  libkrb5-dev \
  zlib1g-dev
msg_ok "Installed Dependencies"

msg_info "Installing Docker"
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p "$(dirname $DOCKER_CONFIG_PATH)"
echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
$STD sh <(curl -fsSL https://get.docker.com)
msg_ok "Installed Docker"

msg_info "Installing Node.js and Claude Code"
NODE_VERSION="22" NODE_MODULE="@anthropic-ai/claude-code" setup_nodejs
msg_ok "Installed Node.js and Claude Code"

msg_info "Installing Python"
PYTHON_VERSION="3.12" setup_uv
msg_ok "Installed Python"

msg_info "Installing Go"
setup_go
msg_ok "Installed Go"

msg_info "Installing Rust"
setup_rust
msg_ok "Installed Rust"

msg_info "Configuring GitHub Runner"

while true; do
  read -r -p "${TAB3}Enter GitHub Organization name: " GH_ORG
  [[ -n "$GH_ORG" ]] && break
  echo -e "${TAB3}${RD}Organization name cannot be empty${CL}"
done

while true; do
  read -r -s -p "${TAB3}Enter GitHub PAT (admin:org scope): " GH_PAT
  echo
  [[ -n "$GH_PAT" ]] && break
  echo -e "${TAB3}${RD}PAT cannot be empty${CL}"
done

read -r -p "${TAB3}Runner name [$(hostname)]: " RUNNER_NAME
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"

read -r -p "${TAB3}Runner labels [self-hosted,linux,x64]: " RUNNER_LABELS
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"

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

msg_info "Creating runner user"
useradd -m -s /bin/bash runner
usermod -aG docker runner
msg_ok "Created runner user"

msg_info "Downloading GitHub Actions Runner"
RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

mkdir -p /opt/actions-runner
cd /opt/actions-runner
$STD curl -fsSL -o runner.tar.gz "$RUNNER_URL"
$STD tar xzf runner.tar.gz
rm runner.tar.gz
chown -R runner:runner /opt/actions-runner
msg_ok "Downloaded GitHub Actions Runner v${RUNNER_VERSION}"

msg_info "Configuring runner"
su - runner -c "cd /opt/actions-runner && ./config.sh --unattended \
  --url https://github.com/${GH_ORG} \
  --token ${REG_TOKEN} \
  --name ${RUNNER_NAME} \
  --labels ${RUNNER_LABELS} \
  --runnergroup Default \
  --work _work"
msg_ok "Configured runner"

cat <<EOF >/opt/actions-runner/.env
GH_ORG=${GH_ORG}
RUNNER_NAME=${RUNNER_NAME}
RUNNER_LABELS=${RUNNER_LABELS}
EOF
chmod 400 /opt/actions-runner/.env

echo "${RUNNER_VERSION}" >/root/.github-runner

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/github-runner.service
[Unit]
Description=GitHub Actions Runner
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=runner
Group=runner
WorkingDirectory=/opt/actions-runner
ExecStart=/opt/actions-runner/run.sh
Restart=always
RestartSec=10
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q --now github-runner
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
