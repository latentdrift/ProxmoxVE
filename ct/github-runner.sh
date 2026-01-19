#!/usr/bin/env bash
CS_REPO="${CS_REPO:-community-scripts/ProxmoxVE}"
CS_REPO_BRANCH="${CS_REPO_BRANCH:-main}"
CS_REPO_URL="${CS_REPO_URL:-https://raw.githubusercontent.com/${CS_REPO}/${CS_REPO_BRANCH}}"
export CS_REPO CS_REPO_BRANCH CS_REPO_URL
source <(curl -fsSL "${CS_REPO_URL}/misc/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: n8
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/actions/runner

APP="GitHub-Runner"
var_tags="${var_tags:-automation;ci-cd}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-0}"
var_nesting="${var_nesting:-1}"

header_info "$APP"
variables
color
catch_errors

export GH_ORG GH_PAT RUNNER_NAME RUNNER_LABELS
export INSTALL_ENV_VARS="CS_REPO_URL GH_ORG GH_PAT RUNNER_NAME RUNNER_LABELS"

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/actions-runner ]]; then
    msg_error "No GitHub Runner installation found!"
    exit
  fi

  CURRENT_VERSION=$(cat /root/.github-runner 2>/dev/null || echo "0")
  LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
  if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
    msg_error "Failed to fetch latest runner version"
    exit
  fi

  case "$(uname -m)" in
    x86_64) RUNNER_ARCH="x64" ;;
    aarch64) RUNNER_ARCH="arm64" ;;
    armv7l | armv6l) RUNNER_ARCH="arm" ;;
    *)
      msg_error "Unsupported architecture: $(uname -m)"
      exit
      ;;
  esac

  if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    msg_ok "GitHub Runner is already at v${LATEST_VERSION}"
    exit
  fi

  msg_info "Updating GitHub Runner from v${CURRENT_VERSION} to v${LATEST_VERSION}"

  SERVICE_NAME=$(cat /opt/actions-runner/.service 2>/dev/null || true)
  if [[ -n "$SERVICE_NAME" ]]; then
    systemctl stop "$SERVICE_NAME" || true
  else
    systemctl stop github-runner || true
  fi

  cp /opt/actions-runner/.runner /tmp/.runner.bak 2>/dev/null || true
  cp /opt/actions-runner/.credentials /tmp/.credentials.bak 2>/dev/null || true
  cp /opt/actions-runner/.credentials_rsaparams /tmp/.credentials_rsaparams.bak 2>/dev/null || true

  cd /opt/actions-runner
  curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${LATEST_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${LATEST_VERSION}.tar.gz"
  tar xzf runner.tar.gz
  rm runner.tar.gz
  $STD ./bin/installdependencies.sh

  cp /tmp/.runner.bak /opt/actions-runner/.runner 2>/dev/null || true
  cp /tmp/.credentials.bak /opt/actions-runner/.credentials 2>/dev/null || true
  cp /tmp/.credentials_rsaparams.bak /opt/actions-runner/.credentials_rsaparams 2>/dev/null || true

  chown -R runner:runner /opt/actions-runner

  echo "${LATEST_VERSION}" >/root/.github-runner

  if [[ -n "$SERVICE_NAME" ]]; then
    systemctl start "$SERVICE_NAME" || true
  else
    systemctl start github-runner || true
  fi

  msg_ok "Updated GitHub Runner to v${LATEST_VERSION}"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Runner should now appear in your GitHub organization settings.${CL}"
echo -e "${TAB}${GATEWAY}${BGN}https://github.com/orgs/YOUR_ORG/settings/actions/runners${CL}"
