#!/usr/bin/env bash

# FILE: codeck-remote-service.sh
# Purpose: Manages local Codeck Remote launchd services for Cloudflare Tunnel workflows.
# Layer: developer utility
# Exports: launchd install/start/stop/status/log helpers
# Depends on: bash, launchctl, cloudflared, run-local-remodex.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
STATE_DIR="${HOME}/Library/Application Support/CodeckRemote"
LOG_DIR="${HOME}/Library/Logs/CodeckRemote"

LOCAL_LABEL="com.jingyang.codeck.remote.local"
CLOUDFLARED_LABEL="com.jingyang.codeck.remote.cloudflared"

LOCAL_PLIST="${LAUNCH_AGENTS_DIR}/${LOCAL_LABEL}.plist"
CLOUDFLARED_PLIST="${LAUNCH_AGENTS_DIR}/${CLOUDFLARED_LABEL}.plist"

LOCAL_STDOUT_LOG="${LOG_DIR}/local.out.log"
LOCAL_STDERR_LOG="${LOG_DIR}/local.err.log"
CLOUDFLARED_STDOUT_LOG="${LOG_DIR}/cloudflared.out.log"
CLOUDFLARED_STDERR_LOG="${LOG_DIR}/cloudflared.err.log"

usage() {
  cat <<'EOF'
Usage: scripts/codeck-remote-service.sh <command> [options]

Commands:
  write-cloudflared-config --tunnel TUNNEL --hostname HOSTNAME [--credentials-file PATH] [--config PATH] [--port PORT]
      Write a locally-managed cloudflared config that proxies HOSTNAME to http://127.0.0.1:PORT.

  install-local --relay-url URL [--port PORT]
      Install and start the local relay+bridge LaunchAgent. URL should be wss://HOSTNAME/relay.

  install-cloudflared --config PATH --tunnel TUNNEL [--protocol PROTOCOL]
      Install and start the cloudflared LaunchAgent using the config file and tunnel name/UUID.
      PROTOCOL defaults to http2 (recommended for stability on flaky networks).

  install --hostname HOSTNAME --tunnel TUNNEL [--credentials-file PATH] [--config PATH] [--port PORT] [--protocol PROTOCOL]
      Write cloudflared config, install local relay+bridge, and install cloudflared.

  uninstall
      Stop and remove both LaunchAgents. Does not delete Cloudflare tunnels.

  start | stop | restart | status
      Manage both LaunchAgents.

  logs [local|cloudflared|all]
      Tail service logs. Use local logs to find the pairing QR payload after install.

Examples:
  cloudflared tunnel login
  cloudflared tunnel create codeck-remote
  cloudflared tunnel route dns codeck-remote codeck.example.com
  scripts/codeck-remote-service.sh install --hostname codeck.example.com --tunnel codeck-remote --protocol http2
  scripts/codeck-remote-service.sh logs local
EOF
}

die() {
  echo "[codeck-remote-service] $*" >&2
  exit 1
}

log() {
  echo "[codeck-remote-service] $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "${value}"
}

ensure_dirs() {
  mkdir -p "${LAUNCH_AGENTS_DIR}" "${STATE_DIR}" "${LOG_DIR}"
}

gui_domain() {
  printf 'gui/%s' "$(id -u)"
}

normalize_relay_url() {
  local hostname="$1"
  if [[ "${hostname}" == ws://* || "${hostname}" == wss://* || "${hostname}" == http://* || "${hostname}" == https://* ]]; then
    node -e '
const raw = process.argv[1];
const url = new URL(raw);
if (url.protocol === "http:") url.protocol = "ws:";
if (url.protocol === "https:") url.protocol = "wss:";
if (url.pathname === "" || url.pathname === "/") url.pathname = "/relay";
url.search = "";
url.hash = "";
console.log(url.toString());
' "${hostname}"
    return
  fi

  printf 'wss://%s/relay\n' "${hostname}"
}

default_cloudflared_config_path() {
  printf '%s/.cloudflared/codeck-remote.yml\n' "${HOME}"
}

default_credentials_file() {
  local tunnel="$1"
  if [[ -f "${HOME}/.cloudflared/${tunnel}.json" ]]; then
    printf '%s/.cloudflared/%s.json\n' "${HOME}" "${tunnel}"
    return
  fi

  local match
  match="$(find "${HOME}/.cloudflared" -maxdepth 1 -type f -name '*.json' 2>/dev/null | head -n 1 || true)"
  [[ -n "${match}" ]] || die "Could not find a cloudflared credentials JSON in ~/.cloudflared. Pass --credentials-file."
  printf '%s\n' "${match}"
}

write_cloudflared_config() {
  local tunnel=""
  local hostname=""
  local credentials_file=""
  local config_path=""
  local port="9000"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tunnel) tunnel="${2:-}"; shift 2 ;;
      --hostname) hostname="${2:-}"; shift 2 ;;
      --credentials-file) credentials_file="${2:-}"; shift 2 ;;
      --config) config_path="${2:-}"; shift 2 ;;
      --port) port="${2:-}"; shift 2 ;;
      *) die "Unknown write-cloudflared-config option: $1" ;;
    esac
  done

  [[ -n "${tunnel}" ]] || die "--tunnel is required."
  [[ -n "${hostname}" ]] || die "--hostname is required."
  [[ "${hostname}" != *"://"* ]] || die "--hostname must be a hostname only, not a URL."
  [[ "${port}" =~ ^[0-9]+$ ]] || die "--port must be a number."

  config_path="${config_path:-$(default_cloudflared_config_path)}"
  credentials_file="${credentials_file:-$(default_credentials_file "${tunnel}")}"
  [[ -f "${credentials_file}" ]] || die "Credentials file does not exist: ${credentials_file}"

  mkdir -p "$(dirname "${config_path}")"
  cat > "${config_path}" <<EOF
tunnel: ${tunnel}
credentials-file: ${credentials_file}

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:${port}
  - service: http_status:404
EOF

  log "Wrote ${config_path}"
}

write_local_plist() {
  local relay_url="$1"
  local port="$2"
  local command

  command="cd $(printf '%q' "${ROOT_DIR}") && ./run-local-remodex.sh --relay-url $(printf '%q' "${relay_url}") --bind-host 127.0.0.1 --port $(printf '%q' "${port}")"
  cat > "${LOCAL_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LOCAL_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$(xml_escape "${command}")</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "${ROOT_DIR}")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "${PATH}")</string>
    <key>HOME</key>
    <string>$(xml_escape "${HOME}")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "${LOCAL_STDOUT_LOG}")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "${LOCAL_STDERR_LOG}")</string>
</dict>
</plist>
EOF
}

write_cloudflared_plist() {
  local config_path="$1"
  local tunnel="$2"
  local protocol="$3"
  local cloudflared_path

  cloudflared_path="$(command -v cloudflared)"
  cat > "${CLOUDFLARED_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CLOUDFLARED_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "${cloudflared_path}")</string>
    <string>tunnel</string>
    <string>--protocol</string>
    <string>$(xml_escape "${protocol}")</string>
    <string>--config</string>
    <string>$(xml_escape "${config_path}")</string>
    <string>run</string>
    <string>$(xml_escape "${tunnel}")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$(xml_escape "${HOME}")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "${CLOUDFLARED_STDOUT_LOG}")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "${CLOUDFLARED_STDERR_LOG}")</string>
</dict>
</plist>
EOF
}

bootstrap_plist() {
  local plist="$1"
  launchctl bootout "$(gui_domain)" "${plist}" >/dev/null 2>&1 || true
  launchctl bootstrap "$(gui_domain)" "${plist}"
  launchctl kickstart -k "$(gui_domain)/$(basename "${plist}" .plist)"
}

bootout_plist() {
  local plist="$1"
  launchctl bootout "$(gui_domain)" "${plist}" >/dev/null 2>&1 || true
}

install_local() {
  local relay_url=""
  local port="9000"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --relay-url) relay_url="${2:-}"; shift 2 ;;
      --port) port="${2:-}"; shift 2 ;;
      *) die "Unknown install-local option: $1" ;;
    esac
  done

  [[ -n "${relay_url}" ]] || die "--relay-url is required."
  [[ "${port}" =~ ^[0-9]+$ ]] || die "--port must be a number."
  relay_url="$(normalize_relay_url "${relay_url}")"

  ensure_dirs
  write_local_plist "${relay_url}" "${port}"
  plutil -lint "${LOCAL_PLIST}" >/dev/null
  bootstrap_plist "${LOCAL_PLIST}"
  log "Installed ${LOCAL_LABEL}"
  log "Relay URL: ${relay_url}"
  log "Local logs: ${LOCAL_STDOUT_LOG}"
}

install_cloudflared() {
  local config_path=""
  local tunnel=""
  local protocol="http2"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) config_path="${2:-}"; shift 2 ;;
      --tunnel) tunnel="${2:-}"; shift 2 ;;
      --protocol) protocol="${2:-}"; shift 2 ;;
      *) die "Unknown install-cloudflared option: $1" ;;
    esac
  done

  [[ -n "${config_path}" ]] || die "--config is required."
  [[ -n "${tunnel}" ]] || die "--tunnel is required."
  [[ -f "${config_path}" ]] || die "Config file does not exist: ${config_path}"

  require_command cloudflared
  ensure_dirs
  write_cloudflared_plist "${config_path}" "${tunnel}" "${protocol}"
  plutil -lint "${CLOUDFLARED_PLIST}" >/dev/null
  bootstrap_plist "${CLOUDFLARED_PLIST}"
  log "Installed ${CLOUDFLARED_LABEL}"
  log "Cloudflared protocol: ${protocol}"
  log "Cloudflared logs: ${CLOUDFLARED_STDOUT_LOG}"
}

install_all() {
  local tunnel=""
  local hostname=""
  local credentials_file=""
  local config_path=""
  local port="9000"
  local protocol="http2"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tunnel) tunnel="${2:-}"; shift 2 ;;
      --hostname) hostname="${2:-}"; shift 2 ;;
      --credentials-file) credentials_file="${2:-}"; shift 2 ;;
      --config) config_path="${2:-}"; shift 2 ;;
      --port) port="${2:-}"; shift 2 ;;
      --protocol) protocol="${2:-}"; shift 2 ;;
      *) die "Unknown install option: $1" ;;
    esac
  done

  [[ -n "${hostname}" ]] || die "--hostname is required."
  [[ -n "${tunnel}" ]] || die "--tunnel is required."
  config_path="${config_path:-$(default_cloudflared_config_path)}"

  local write_args=(--tunnel "${tunnel}" --hostname "${hostname}" --config "${config_path}" --port "${port}")
  if [[ -n "${credentials_file}" ]]; then
    write_args+=(--credentials-file "${credentials_file}")
  fi

  write_cloudflared_config "${write_args[@]}"
  install_local --relay-url "$(normalize_relay_url "${hostname}")" --port "${port}"
  install_cloudflared --config "${config_path}" --tunnel "${tunnel}" --protocol "${protocol}"
}

stop_all() {
  bootout_plist "${LOCAL_PLIST}"
  bootout_plist "${CLOUDFLARED_PLIST}"
}

start_all() {
  [[ -f "${LOCAL_PLIST}" ]] && bootstrap_plist "${LOCAL_PLIST}" || log "Missing ${LOCAL_PLIST}"
  [[ -f "${CLOUDFLARED_PLIST}" ]] && bootstrap_plist "${CLOUDFLARED_PLIST}" || log "Missing ${CLOUDFLARED_PLIST}"
}

uninstall_all() {
  stop_all
  rm -f "${LOCAL_PLIST}" "${CLOUDFLARED_PLIST}"
  log "Removed LaunchAgents."
}

status_all() {
  log "Local service:"
  launchctl print "$(gui_domain)/${LOCAL_LABEL}" 2>/dev/null || true
  log "Cloudflared service:"
  launchctl print "$(gui_domain)/${CLOUDFLARED_LABEL}" 2>/dev/null || true
}

logs() {
  local target="${1:-all}"
  case "${target}" in
    local)
      touch "${LOCAL_STDOUT_LOG}" "${LOCAL_STDERR_LOG}"
      tail -n 200 -f "${LOCAL_STDOUT_LOG}" "${LOCAL_STDERR_LOG}"
      ;;
    cloudflared)
      touch "${CLOUDFLARED_STDOUT_LOG}" "${CLOUDFLARED_STDERR_LOG}"
      tail -n 200 -f "${CLOUDFLARED_STDOUT_LOG}" "${CLOUDFLARED_STDERR_LOG}"
      ;;
    all)
      touch "${LOCAL_STDOUT_LOG}" "${LOCAL_STDERR_LOG}" "${CLOUDFLARED_STDOUT_LOG}" "${CLOUDFLARED_STDERR_LOG}"
      tail -n 200 -f "${LOCAL_STDOUT_LOG}" "${LOCAL_STDERR_LOG}" "${CLOUDFLARED_STDOUT_LOG}" "${CLOUDFLARED_STDERR_LOG}"
      ;;
    *)
      die "Unknown logs target: ${target}"
      ;;
  esac
}

main() {
  local command="${1:-}"
  [[ -n "${command}" ]] || { usage; exit 1; }
  shift || true

  case "${command}" in
    write-cloudflared-config) write_cloudflared_config "$@" ;;
    install-local) install_local "$@" ;;
    install-cloudflared) install_cloudflared "$@" ;;
    install) install_all "$@" ;;
    uninstall) uninstall_all ;;
    start) start_all ;;
    stop) stop_all ;;
    restart) stop_all; start_all ;;
    status) status_all ;;
    logs) logs "$@" ;;
    --help|-h|help) usage ;;
    *) usage >&2; die "Unknown command: ${command}" ;;
  esac
}

main "$@"
