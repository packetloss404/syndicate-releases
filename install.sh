#!/usr/bin/env bash
# Syndicate Linux installer. This file is intentionally self-contained so the
# curl pipe is the only downloaded code that executes before artifact checks.
set -euo pipefail

PROGRAM="syndicate-install"
INSTALLER_CONTRACT=2
REPOSITORY="${SYNDICATE_INSTALL_REPOSITORY:-packetloss404/syndicate-releases}"
VERSION="${SYNDICATE_INSTALL_VERSION:-latest}"
PREFIX="${SYNDICATE_INSTALL_PREFIX:-${HOME:?HOME must be set}/.local/share/syndicate}"
STATE_DIR="${SYNDICATE_INSTALL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/syndicate}"
DRY_RUN=0
UNINSTALL=0
ENABLE_LINGER=0
LAN_PROXY=0
LAN_PROXY_REQUESTED=0
LAN_PROXY_ADDRESS=""
LAN_PROXY_PORT=8443
LAN_PROXY_PORT_REQUESTED=0
NO_SERVICE=0
DEFER_ACTIVATION=0
KEEP_DOWNLOADS=0
RELEASE_BASE_URL="${SYNDICATE_INSTALL_RELEASE_BASE_URL:-}"
CHECKSUMS_URL="${SYNDICATE_INSTALL_CHECKSUMS_URL:-}"
SYSTEMCTL_USER="${SYNDICATE_INSTALL_SYSTEMCTL_USER:-systemctl --user}"
ALLOW_FILE_URL="${SYNDICATE_INSTALL_ALLOW_FILE_URL:-0}"
HEALTHCHECK_URL="${SYNDICATE_INSTALL_HEALTHCHECK_URL:-http://127.0.0.1:4317/api/v1/health}"
HEALTHCHECK_ATTEMPTS="${SYNDICATE_INSTALL_HEALTHCHECK_ATTEMPTS:-30}"
SERVICE_NAME="syndicate.service"
TERMINAL_SERVICE_NAME="syndicate-terminal-host.service"
PROXY_SERVICE_NAME="syndicate-proxy.service"
LEGACY_TERMINAL_SERVICE_NAME="syndicate-packet-host.service"
WORKSTATION_SERVICE_NAME="syndicate-workstation.service"
TMP_DIR=""
ACTIVATION_ACTIVE=0

# Rollback bookkeeping is referenced from the EXIT trap, so it lives at file
# scope and is initialised before any step can arm activation.
PREVIOUS_CURRENT=""
VERSION_DIR=""
VERSION_ROLLBACK=""
BACKUP_DIR=""
STATE_ROLLBACK_READY=0
OLD_VERSION_SAVED=0
OLD_LAUNCHER_SAVED=0
OLD_SERVICE_SAVED=0
OLD_TERMINAL_SERVICE_SAVED=0
OLD_PROXY_SERVICE_SAVED=0
OLD_LEGACY_TERMINAL_SERVICE_SAVED=0
OLD_CONFIG_SAVED=0
CONFIG_SNAPSHOT_TAKEN=0
WORKSTATION_WAS_RUNNING=0
WORKSTATION_WAS_ENABLED=0
WORKSTATION_KEY=""
OLD_WORKSTATION_LAUNCHER_SAVED=0
WORKSTATION_LAUNCHER_PATH=""
VERSION_INSTALLED=0
STAGING=""
HOST_SERVICE_WAS_ACTIVE=0
TERMINAL_SERVICE_WAS_ACTIVE=0
PROXY_SERVICE_WAS_ACTIVE=0
LEGACY_TERMINAL_SERVICE_WAS_ACTIVE=0
STATE_DIR_EXISTED=0
DATA_EXISTED=0
LOCAL_KEY_EXISTED=0
RUN_DIR_EXISTED=0
HOST_LOCK_EXISTED=0
BACKUPS_DIR_EXISTED=0
PROXY_TLS_DIR_EXISTED=0
SERVICE_DIR=""
SERVICE_PATH=""
TERMINAL_SERVICE_PATH=""
PROXY_SERVICE_PATH=""
LEGACY_TERMINAL_SERVICE_PATH=""
LAUNCHER_LINK_DIR=""
LAUNCHER_LINK=""
LAUNCHER_LINK_MANAGED=0
LAUNCHER_LINK_EXISTED=0
LAUNCHER_LINK_PREVIOUS=""
LAUNCHER_LINK_DIR_EXISTED=0

# This Ed25519 key is the independent trust anchor for official Syndicate
# release manifests. It is intentionally not configurable for HTTPS releases.
# Test fixtures may override it only while the explicit file:// test gate is on.
RELEASE_PUBLIC_KEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAQjdqhCjWhkgHHDEL3VOF+tH1tsRxr9Gy0sC7dR9xY3M=
-----END PUBLIC KEY-----'

usage() {
  cat <<'EOF'
Install a verified Syndicate release for the current unprivileged Linux user.

Usage:
  install.sh [options]

Options:
  --version VERSION      Install a release tag (default: latest).
  --print-contract       Print the installer compatibility contract and exit.
  --prefix PATH          Install root (default: ~/.local/share/syndicate).
  --dry-run              Print planned actions without downloading or writing.
  --no-service           Install files but do not write/enable a user service.
  --defer-activation     Write user services but leave them disabled/stopped.
  --enable-linger        Ask loginctl to keep the user service alive after logout.
  --lan-proxy-address IP Install the managed HTTPS LAN proxy on IP:8443.
  --lan-proxy-port PORT  Managed proxy port (default: 8443).
  --no-lan-proxy         Keep dashboard access on loopback only.
  --uninstall            Disable the service and remove the selected prefix.
  --keep-downloads       Retain the temporary download directory for inspection.
  -h, --help             Show this help.

Release contract:
  The selected GitHub release must publish both files below for this platform:
    syndicate-VERSION-linux-ARCH.tar.gz
    SHA256SUMS
    SHA256SUMS.sig

  The archive must contain bin/syndicate, bin/syndicate-terminal-host, and the
  built dashboard at apps/dashboard/dist. Each version is installed under
  PREFIX/versions/VERSION, then PREFIX/current changes atomically. The installer
  downloads data only, verifies SHA256SUMS with Syndicate's pinned Ed25519
  release key, verifies the archive with SHA-256, rejects unsafe archive paths,
  and then extracts it. It never executes another downloaded installer.

  After activation the syndicate command is linked at ~/.local/bin/syndicate.
  The installer warns instead of editing a shell profile when that directory is
  not already on PATH, and --uninstall removes only a link it owns.

Environment overrides intended for mirrors and automated tests:
  SYNDICATE_INSTALL_RELEASE_BASE_URL  Base containing the archive and sums.
  SYNDICATE_INSTALL_CHECKSUMS_URL     Exact SHA256SUMS URL.
  SYNDICATE_INSTALL_REPOSITORY        GitHub owner/repository.
  SYNDICATE_INSTALL_STATE_DIR         Persistent data/worktree directory.
  SYNDICATE_INSTALL_SYSTEMCTL_USER    User service manager command (tests only;
                                      do not use with untrusted input).
  SYNDICATE_INSTALL_ALLOW_FILE_URL     Test-only: set to 1 for file:// fixtures.
  SYNDICATE_INSTALL_TEST_PUBLIC_KEY_PEM
                                      Test-only signing key override; accepted
                                      only with the file:// test gate.

The installer does not install Node.js, pnpm, Rust, Codex, Claude Code, or
PacketCode and does not modify a firewall. Official Syndicate release archives
must be self-contained. The service binds the host to 127.0.0.1:4317 and runs
with the current OS user's filesystem authority so agents can work in that
user's repositories.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

shell_join() {
  local output="" item quoted
  for item in "$@"; do
    printf -v quoted '%q' "$item"
    output+="${output:+ }${quoted}"
  done
  printf '%s' "$output"
}

run() {
  if (( DRY_RUN )); then
    printf '+ '
    shell_join "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# Check a tree that is already on disk against a manifest recorded earlier, at
# a different point in the install. Checking a manifest against the same bytes
# it was just computed from proves nothing, so this is deliberately never called
# on the tree the manifest was generated from.
#
# `sha256sum -c` alone only proves the recorded files are unchanged; it says
# nothing about files that are present but unrecorded. The file-set comparison
# closes that gap, so an extra file dropped into an installed version directory
# is a mismatch rather than a silent pass.
verify_tree_against_manifest() {
  local tree="$1"
  [[ -f "$tree/INSTALL_MANIFEST.sha256" ]] || return 1
  (
    cd -- "$tree" || exit 1
    sha256sum -c INSTALL_MANIFEST.sha256 >/dev/null 2>&1 || exit 1
    local recorded observed
    recorded="$(cut -c 67- INSTALL_MANIFEST.sha256 | LC_ALL=C sort)"
    observed="$(find . -type f ! -name INSTALL_MANIFEST.sha256 -print | LC_ALL=C sort)"
    [[ "$recorded" == "$observed" ]] || exit 1
  )
}

cleanup() {
  if [[ -n "$STAGING" && "$STAGING" == "$PREFIX/versions/.staging-"* && -d "$STAGING" && ! -L "$STAGING" ]]; then
    rm -rf -- "$STAGING"
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$KEEP_DOWNLOADS" -eq 0 ]]; then
    rm -rf -- "$TMP_DIR"
  elif [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Downloads retained at $TMP_DIR"
  fi
}

systemctl_user() {
  local -a command
  read -r -a command <<< "$SYSTEMCTL_USER"
  [[ ${#command[@]} -gt 0 ]] || die "empty SYNDICATE_INSTALL_SYSTEMCTL_USER"
  run "${command[@]}" "$@"
}

rollback_activation() {
  set +e
  log "Activation failed; restoring the previous Syndicate runtime and state"
  if (( NO_SERVICE == 0 )); then
    systemctl_user stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl_user stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    if [[ -z "$PREVIOUS_CURRENT" ]]; then
      # A failed first install introduced both services. Remove that entire
      # service footprint rather than leaving a new syndicate-terminal-host daemon alive.
      systemctl_user disable --now "$SERVICE_NAME" "$TERMINAL_SERVICE_NAME" "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    elif (( TERMINAL_SERVICE_WAS_ACTIVE == 0 )); then
      # If this activation started a syndicate-terminal-host that was previously stopped,
      # do not leave the new binary resident after switching back to old files.
      systemctl_user stop "$TERMINAL_SERVICE_NAME" >/dev/null 2>&1
    fi
  fi

  rm -f -- "$PREFIX/current" "$PREFIX/.current-$$"
  if [[ -n "$PREVIOUS_CURRENT" ]]; then
    ln -s -- "$PREVIOUS_CURRENT" "$PREFIX/.current-rollback-$$"
    mv -Tf -- "$PREFIX/.current-rollback-$$" "$PREFIX/current"
  fi

  # The PATH launcher link is restored to exactly its pre-activation state: a
  # link this installer created is removed, an adopted one is pointed back.
  if (( LAUNCHER_LINK_MANAGED )); then
    rm -f -- "$LAUNCHER_LINK" "$LAUNCHER_LINK.staging-$$"
    if (( LAUNCHER_LINK_EXISTED )); then
      ln -s -- "$LAUNCHER_LINK_PREVIOUS" "$LAUNCHER_LINK.staging-$$"
      mv -Tf -- "$LAUNCHER_LINK.staging-$$" "$LAUNCHER_LINK"
    elif (( LAUNCHER_LINK_DIR_EXISTED == 0 )); then
      rmdir -- "$LAUNCHER_LINK_DIR" >/dev/null 2>&1
    fi
  fi

  if (( VERSION_INSTALLED )) && [[ -n "$VERSION_DIR" && -e "$VERSION_DIR" ]]; then rm -rf -- "$VERSION_DIR"; fi
  if (( OLD_VERSION_SAVED )); then mv -- "$VERSION_ROLLBACK" "$VERSION_DIR"; fi

  if (( STATE_ROLLBACK_READY )); then
    if (( STATE_DIR_EXISTED == 0 )); then
      rm -rf -- "$STATE_DIR"
    else
      rm -rf -- "$STATE_DIR/data"
      if (( DATA_EXISTED )); then cp -a -- "$BACKUP_DIR/data" "$STATE_DIR/data"; fi
      if (( LOCAL_KEY_EXISTED == 0 )); then rm -f -- "$STATE_DIR/local.key"; fi
      if (( HOST_LOCK_EXISTED == 0 )); then rm -f -- "$STATE_DIR/host.lock"; fi
      if (( RUN_DIR_EXISTED == 0 && TERMINAL_SERVICE_WAS_ACTIVE == 0 )); then rm -rf -- "$STATE_DIR/run"; fi
      if (( PROXY_TLS_DIR_EXISTED == 0 )); then rm -rf -- "$STATE_DIR/proxy-tls"; fi
      if [[ -n "$BACKUP_DIR" ]]; then rm -rf -- "$BACKUP_DIR"; fi
      if (( BACKUPS_DIR_EXISTED == 0 )); then rmdir -- "$STATE_DIR/backups" >/dev/null 2>&1 || true; fi
    fi
  fi

  if (( OLD_LAUNCHER_SAVED )); then
    cp -a -- "$TMP_DIR/old-service-launcher" "$PREFIX/service-launcher"
  else
    rm -f -- "$PREFIX/service-launcher"
  fi
  if (( CONFIG_SNAPSHOT_TAKEN )); then
    if (( OLD_CONFIG_SAVED )); then
      cp -a -- "$TMP_DIR/old-config.json" "$SYNDICATE_CONFIG_PATH"
    else
      rm -f -- "$SYNDICATE_CONFIG_PATH"
    fi
  fi
  if (( OLD_WORKSTATION_LAUNCHER_SAVED )); then
    cp -a -- "$TMP_DIR/old-workstation-start.sh" "$WORKSTATION_LAUNCHER_PATH"
  fi
  if (( NO_SERVICE == 0 )); then
    if (( OLD_SERVICE_SAVED )); then cp -a -- "$TMP_DIR/old-$SERVICE_NAME" "$SERVICE_PATH"; else rm -f -- "$SERVICE_PATH"; fi
    if (( OLD_TERMINAL_SERVICE_SAVED )); then cp -a -- "$TMP_DIR/old-$TERMINAL_SERVICE_NAME" "$TERMINAL_SERVICE_PATH"; else rm -f -- "$TERMINAL_SERVICE_PATH"; fi
    if (( OLD_PROXY_SERVICE_SAVED )); then cp -a -- "$TMP_DIR/old-$PROXY_SERVICE_NAME" "$PROXY_SERVICE_PATH"; else rm -f -- "$PROXY_SERVICE_PATH"; fi
    if (( OLD_LEGACY_TERMINAL_SERVICE_SAVED )); then cp -a -- "$TMP_DIR/old-$LEGACY_TERMINAL_SERVICE_NAME" "$LEGACY_TERMINAL_SERVICE_PATH"; else rm -f -- "$LEGACY_TERMINAL_SERVICE_PATH"; fi
    systemctl_user daemon-reload >/dev/null 2>&1
    # A syndicate-terminal-host that predated activation is deliberately not restarted: its
    # PTYs survive the Host rollback. Service activity is restored to its prior
    # state instead of unexpectedly starting a previously stopped installation.
    if [[ -n "$PREVIOUS_CURRENT" ]]; then
      if (( TERMINAL_SERVICE_WAS_ACTIVE )); then systemctl_user start "$TERMINAL_SERVICE_NAME" >/dev/null 2>&1; fi
      if (( LEGACY_TERMINAL_SERVICE_WAS_ACTIVE )); then systemctl_user start "$LEGACY_TERMINAL_SERVICE_NAME" >/dev/null 2>&1; fi
      if (( HOST_SERVICE_WAS_ACTIVE )); then systemctl_user restart "$SERVICE_NAME" >/dev/null 2>&1; fi
      if (( PROXY_SERVICE_WAS_ACTIVE )); then systemctl_user restart "$PROXY_SERVICE_NAME" >/dev/null 2>&1; fi
      if (( WORKSTATION_WAS_RUNNING && HOST_SERVICE_WAS_ACTIVE )); then
        log "Previous workstation $WORKSTATION_KEY and its native PTYs were retained; existing attachment clients may reconnect to the restored Host"
      fi
    fi
  fi
  ACTIVATION_ACTIVE=0
  set -e
}

health_ready() {
  local attempt response protocols="=http,https"
  [[ "$ALLOW_FILE_URL" == "1" ]] && protocols="=http,https,file"
  for (( attempt=1; attempt<=HEALTHCHECK_ATTEMPTS; attempt++ )); do
    response="$(curl --fail --silent --show-error --location --proto "$protocols" \
      --connect-timeout 2 --max-time 3 "$HEALTHCHECK_URL" 2>/dev/null || true)"
    if grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<<"$response" \
      && grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' <<<"$response"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# A oneshot boot unit can remain active after `workstation stop` destroys its
# tmux presentation. Only the presentation itself proves the operator left it
# running; the unit's enabled/active flags alone must never resurrect a stop.
read_workstation_state() {
  local output="$1" key="${2:-}"
  local -a arguments=(workstation status)
  [[ -z "$key" ]] || arguments+=("$key")
  "$PREFIX/current/bin/syndicate" "${arguments[@]}" --json > "$output" 2> "$TMP_DIR/workstation-status.err" || true
  "$PREFIX/current/runtime/node/bin/node" -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!["running", "stopped"].includes(value.presentation)) process.exit(2);
    if (process.argv[2]) {
      const before = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
      if (value.key !== process.argv[2] || value.repositoryPath !== before.repositoryPath) process.exit(2);
    }
    process.stdout.write(value.presentation);
  ' "$output" "$key" "$TMP_DIR/workstation-before.json"
}

write_default_workstation_launcher() {
  local temporary="$WORKSTATION_LAUNCHER_PATH.staging-$$"
  cat > "$temporary" <<EOF
#!/bin/bash
# Managed by Syndicate: restore the persisted default workstation.
set -euo pipefail
for attempt in \$(seq 1 90); do
  response="\$(curl --fail --silent --proto '=http' --connect-timeout 2 --max-time 3 "http://127.0.0.1:4317/api/v1/health" 2>/dev/null || true)"
  if grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' <<<"\$response"; then
    exec "$PREFIX/current/bin/syndicate" workstation recover --detach
  fi
  sleep 1
done
echo "syndicate-workstation: the Host did not become ready on loopback" >&2
exit 1
EOF
  chmod 0700 "$temporary"
  mv -f -- "$temporary" "$WORKSTATION_LAUNCHER_PATH"
}

finish() {
  local status=$?
  trap - EXIT
  # Roll back whenever activation is still armed, whatever the reported status.
  # A run that reaches this point with the window open never completed it, and
  # a truncated `curl | bash` can reach EOF and report success mid-window.
  if (( ACTIVATION_ACTIVE )); then
    rollback_activation
    (( status != 0 )) || status=1
  fi
  cleanup
  exit "$status"
}
trap finish EXIT

# Everything below runs from a single function invoked on the last line of this
# file. A `curl | bash` install that is truncated in transit therefore executes
# nothing at all instead of half of an activation. The body is deliberately left
# unindented: it contains heredocs whose contents are installed verbatim.
syndicate_install_main() {

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --print-contract) printf '%s\n' "$INSTALLER_CONTRACT"; exit 0 ;;
    --prefix)
      [[ $# -ge 2 ]] || die "--prefix requires a value"
      PREFIX="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-service) NO_SERVICE=1; shift ;;
    --defer-activation) DEFER_ACTIVATION=1; shift ;;
    --enable-linger) ENABLE_LINGER=1; shift ;;
    --lan-proxy-address) [[ $# -ge 2 ]] || die "--lan-proxy-address requires a value"; LAN_PROXY_REQUESTED=1; LAN_PROXY=1; LAN_PROXY_ADDRESS="$2"; shift 2 ;;
    --lan-proxy-port) [[ $# -ge 2 ]] || die "--lan-proxy-port requires a value"; LAN_PROXY_PORT="$2"; LAN_PROXY_PORT_REQUESTED=1; shift 2 ;;
    --no-lan-proxy) LAN_PROXY_REQUESTED=1; LAN_PROXY=0; LAN_PROXY_ADDRESS=""; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --keep-downloads) KEEP_DOWNLOADS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (run with --help)" ;;
  esac
done

(( NO_SERVICE == 0 || DEFER_ACTIVATION == 0 )) \
  || die "--no-service and --defer-activation are mutually exclusive"

# Upgrades preserve an already-managed LAN endpoint unless the operator explicitly chooses
# --no-lan-proxy or supplies a replacement address. The service file is installer-owned and its
# two values are validated below before they are reused.
EXISTING_PROXY_SERVICE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$PROXY_SERVICE_NAME"
if (( LAN_PROXY_REQUESTED == 0 )) && [[ -f "$EXISTING_PROXY_SERVICE" && ! -L "$EXISTING_PROXY_SERVICE" ]]; then
  LAN_PROXY_ADDRESS="$(sed -n 's/^Environment=SYNDICATE_PROXY_PUBLIC_ORIGIN=https:\/\/\([^:]*\):.*$/\1/p' "$EXISTING_PROXY_SERVICE" | head -n 1)"
  # An explicit --lan-proxy-port on an upgrade is a request, not something to overwrite silently.
  if (( LAN_PROXY_PORT_REQUESTED == 0 )); then
    LAN_PROXY_PORT="$(sed -n 's/^Environment=SYNDICATE_PROXY_LISTEN_PORT=\([0-9]*\)$/\1/p' "$EXISTING_PROXY_SERVICE" | head -n 1)"
  fi
  [[ -n "$LAN_PROXY_ADDRESS" && -n "$LAN_PROXY_PORT" ]] || die "existing managed proxy service is malformed; pass --no-lan-proxy or a replacement --lan-proxy-address"
  LAN_PROXY=1
fi

[[ "$(uname -s)" == "Linux" ]] || die "only Linux is supported"
[[ "$(id -u)" -ne 0 ]] || die "do not run this installer as root or with sudo"

case "$(uname -m)" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid version: $VERSION"
[[ "$PREFIX" == /* ]] || die "--prefix must be an absolute path"
[[ "$PREFIX" != "/" && "$PREFIX" != "$HOME" ]] || die "refusing unsafe prefix: $PREFIX"
[[ "$PREFIX" != *[$'\n\r\t %\\"']* ]] || die "--prefix contains characters unsafe for a systemd service"
[[ "$STATE_DIR" == /* && "$STATE_DIR" != "/" && "$STATE_DIR" != "$HOME" ]] || die "state directory must be a safe absolute path"
[[ "$STATE_DIR" != *[$'\n\r\t %\\"']* ]] || die "state directory contains characters unsafe for a systemd service"
[[ "$HEALTHCHECK_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$HEALTHCHECK_ATTEMPTS" -le 120 ]] \
  || die "SYNDICATE_INSTALL_HEALTHCHECK_ATTEMPTS must be between 1 and 120"
if [[ "$HEALTHCHECK_URL" != http://127.0.0.1:* && "$HEALTHCHECK_URL" != http://localhost:* \
  && ! ( "$ALLOW_FILE_URL" == "1" && "$HEALTHCHECK_URL" == file://* ) ]]; then
  die "health check URL must use loopback HTTP (file:// is permitted only for tests)"
fi
[[ "$LAN_PROXY_PORT" =~ ^[0-9]{1,5}$ && "$LAN_PROXY_PORT" -ge 1024 && "$LAN_PROXY_PORT" -le 65535 ]] \
  || die "--lan-proxy-port must be between 1024 and 65535"
if (( LAN_PROXY )); then
  [[ "$LAN_PROXY_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--lan-proxy-address must be an IPv4 address"
  IFS=. read -r ip_a ip_b ip_c ip_d <<< "$LAN_PROXY_ADDRESS"
  (( ip_a <= 255 && ip_b <= 255 && ip_c <= 255 && ip_d <= 255 )) || die "--lan-proxy-address must be an IPv4 address"
fi

SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SYNDICATE_CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/syndicate/config.json"
SERVICE_PATH="$SERVICE_DIR/$SERVICE_NAME"
TERMINAL_SERVICE_PATH="$SERVICE_DIR/$TERMINAL_SERVICE_NAME"
PROXY_SERVICE_PATH="$SERVICE_DIR/$PROXY_SERVICE_NAME"
LEGACY_TERMINAL_SERVICE_PATH="$SERVICE_DIR/$LEGACY_TERMINAL_SERVICE_NAME"
LAUNCHER_LINK_DIR="$HOME/.local/bin"
LAUNCHER_LINK="$LAUNCHER_LINK_DIR/syndicate"

if (( UNINSTALL )); then
  log "Uninstalling Syndicate from $PREFIX"
  if (( NO_SERVICE == 0 )); then
    # The bootstrap workstation unit hard-requires syndicate.service; left enabled it fails every boot.
    systemctl_user disable --now "$SERVICE_NAME" "$TERMINAL_SERVICE_NAME" "$PROXY_SERVICE_NAME" "$LEGACY_TERMINAL_SERVICE_NAME" "$WORKSTATION_SERVICE_NAME" || true
    run rm -f -- "$SERVICE_PATH" "$TERMINAL_SERVICE_PATH" "$PROXY_SERVICE_PATH" "$LEGACY_TERMINAL_SERVICE_PATH" "$SERVICE_DIR/$WORKSTATION_SERVICE_NAME"
    systemctl_user daemon-reload || true
  fi
  # Only a link this installer owns is removed: one that resolves into the
  # prefix being uninstalled. A user's own `syndicate` command is left alone.
  if [[ -L "$LAUNCHER_LINK" && "$(readlink "$LAUNCHER_LINK")" == "$PREFIX/"* ]]; then
    run rm -f -- "$LAUNCHER_LINK"
  fi
  run rm -rf -- "$PREFIX"
  log "Syndicate uninstall complete. Repositories and state outside this prefix were not removed."
  exit 0
fi

if (( DRY_RUN )); then
  log "Dry run: install Syndicate $VERSION for linux-$ARCH"
  log "Release source: ${RELEASE_BASE_URL:-https://github.com/$REPOSITORY/releases/<resolved-version>}"
  log "Install prefix: $PREFIX"
  log "Persistent state: $STATE_DIR"
  log "PATH launcher: $LAUNCHER_LINK -> $PREFIX/current/bin/syndicate"
  run mkdir -p -- "$PREFIX"
  if (( NO_SERVICE == 0 )); then
    run mkdir -p -- "$SERVICE_DIR"
    run install -m 0600 /dev/null "$SERVICE_PATH"
    run install -m 0600 /dev/null "$TERMINAL_SERVICE_PATH"
    (( LAN_PROXY == 0 )) || run install -m 0600 /dev/null "$PROXY_SERVICE_PATH"
    systemctl_user daemon-reload
    if (( DEFER_ACTIVATION == 0 )); then
      if (( LAN_PROXY )); then systemctl_user enable --now "$TERMINAL_SERVICE_NAME" "$SERVICE_NAME" "$PROXY_SERVICE_NAME"; else systemctl_user enable --now "$TERMINAL_SERVICE_NAME" "$SERVICE_NAME"; fi
    fi
  fi
  if (( ENABLE_LINGER )); then
    run loginctl enable-linger "$(id -un)"
  fi
  exit 0
fi

for command in curl openssl sha256sum tar mktemp install awk grep sed head base64 tr wc cp find sort xargs readlink date sleep; do
  command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
if (( NO_SERVICE == 0 )); then
  read -r -a service_manager_command <<< "$SYSTEMCTL_USER"
  [[ ${#service_manager_command[@]} -gt 0 ]] || die "empty SYNDICATE_INSTALL_SYSTEMCTL_USER"
  command -v "${service_manager_command[0]}" >/dev/null 2>&1 \
    || die "a systemd user manager is required; retry with --no-service for a files-only install"
fi

# A files-only first install is supported. Updating an installation whose Host
# service is currently running is not: without stopping it there is no coherent
# SQLite/WAL snapshot or safe activation boundary.
if (( NO_SERVICE )) && [[ -e "$SERVICE_PATH" ]]; then
  read -r -a service_manager_command <<< "$SYSTEMCTL_USER"
  [[ ${#service_manager_command[@]} -gt 0 ]] || die "empty SYNDICATE_INSTALL_SYSTEMCTL_USER"
  command -v "${service_manager_command[0]}" >/dev/null 2>&1 \
    || die "cannot verify installed Host service state during --no-service update"
  if systemctl_user is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1; then
    die "--no-service cannot update while the installed Syndicate Host service is active; stop it or install with service management enabled"
  fi
fi

if [[ "$VERSION" == "latest" ]]; then
  if [[ -z "$RELEASE_BASE_URL" ]]; then
    VERSION="$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 60 \
      "https://api.github.com/repos/$REPOSITORY/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1)"
    [[ -n "$VERSION" ]] || die "could not resolve the latest release tag; pass --version"
    [[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "release API returned an invalid tag"
  else
    die "--version is required when SYNDICATE_INSTALL_RELEASE_BASE_URL is set"
  fi
fi

BASE_URL="${RELEASE_BASE_URL:-https://github.com/$REPOSITORY/releases/download/$VERSION}"
ARCHIVE="syndicate-$VERSION-linux-$ARCH.tar.gz"
SUMS_NAME="SHA256SUMS"
SUMS_SOURCE="${CHECKSUMS_URL:-$BASE_URL/$SUMS_NAME}"
ARCHIVE_SOURCE="$BASE_URL/$ARCHIVE"

if [[ -n "${SYNDICATE_INSTALL_TEST_PUBLIC_KEY_PEM:-}" ]]; then
  if [[ "$ALLOW_FILE_URL" != "1" || "$BASE_URL" != file://* \
    || "$SUMS_SOURCE" != file://* || "$ARCHIVE_SOURCE" != file://* ]]; then
    die "SYNDICATE_INSTALL_TEST_PUBLIC_KEY_PEM requires file:// base, checksum, and archive sources behind the explicit test gate"
  fi
  RELEASE_PUBLIC_KEY_PEM="$SYNDICATE_INSTALL_TEST_PUBLIC_KEY_PEM"
fi
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/syndicate-install.XXXXXXXX")"

download() {
  local url="$1" destination="$2"
  local protocols="=https"
  [[ "$ALLOW_FILE_URL" == "1" ]] && protocols="=https,file"
  if [[ "$url" != https://* && ! ( "$ALLOW_FILE_URL" == "1" && "$url" == file://* ) ]]; then
    die "release URLs must use HTTPS (file:// is permitted only for tests)"
  fi
  curl --fail --silent --show-error --location --proto "$protocols" --tlsv1.2 \
    --connect-timeout 15 --max-time 300 --retry 3 --retry-connrefused \
    --output "$destination" "$url"
}

log "Downloading Syndicate $VERSION for linux-$ARCH"
download "$SUMS_SOURCE" "$TMP_DIR/$SUMS_NAME" || die "could not download required checksums"
download "${SUMS_SOURCE}.sig" "$TMP_DIR/${SUMS_NAME}.sig" || die "could not download required checksum signature"
printf '%s\n' "$RELEASE_PUBLIC_KEY_PEM" > "$TMP_DIR/release-public-key.pem"
openssl pkeyutl -verify -pubin -inkey "$TMP_DIR/release-public-key.pem" -rawin \
  -in "$TMP_DIR/$SUMS_NAME" -sigfile "$TMP_DIR/${SUMS_NAME}.sig" \
  >/dev/null 2>&1 || die "SHA256SUMS Ed25519 signature verification failed"
log "Verified release manifest signature (Ed25519 key 285944e7579833efa71bb42be7fe1f584e2c3b79772ea91d5c902f4ccbfb517d)"
download "$ARCHIVE_SOURCE" "$TMP_DIR/$ARCHIVE" || die "could not download release archive"

EXPECTED_HASH="$(awk -v name="$ARCHIVE" '
  $1 ~ /^[0-9A-Fa-f]{64}$/ {
    file=$2; sub(/^\*/, "", file); if (file == name || file == "./" name) { print tolower($1); count++ }
  }
  END { if (count != 1) exit 1 }
' "$TMP_DIR/$SUMS_NAME")" || die "SHA256SUMS must contain exactly one valid entry for $ARCHIVE"
ACTUAL_HASH="$(sha256sum "$TMP_DIR/$ARCHIVE" | awk '{print tolower($1)}')"
[[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || die "checksum verification failed for $ARCHIVE"
log "Verified SHA-256: $ACTUAL_HASH"

declare -A ARCHIVE_ENTRIES=()
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  [[ "$entry" != /* && "$entry" != ".." && "$entry" != ../* && "$entry" != */../* && "$entry" != */.. ]] \
    || die "archive contains an unsafe path: $entry"
  [[ -z "${ARCHIVE_ENTRIES[$entry]+present}" ]] || die "archive contains a duplicate path: $entry"
  ARCHIVE_ENTRIES["$entry"]=1
done < <(tar -tzf "$TMP_DIR/$ARCHIVE")

while IFS= read -r listing; do
  case "${listing:0:1}" in
    -|d) ;;
    *) die "archive contains a link or special file, which is not permitted" ;;
  esac
done < <(tar -tvzf "$TMP_DIR/$ARCHIVE")

for member in \
  bin/syndicate \
  bin/syndicate-terminal-host \
  runtime/cli.mjs \
  runtime/host.mjs \
  runtime/node/bin/node \
  runtime-manifest.json \
  SBOM.spdx.json \
  release-metadata.json \
  THIRD_PARTY_NOTICES.md \
  licenses/node/LICENSE \
  licenses/syndicate-terminal-host/NOTICE \
  licenses/dependencies/dependency-license-index.json \
  runtime/node_modules/better-sqlite3/LICENSE \
  migrations/001_initial.sql \
  apps/dashboard/dist/index.html; do
  [[ -n "${ARCHIVE_ENTRIES[$member]+present}" ]] || die "release archive is missing $member"
done

VERSION_DIR="$PREFIX/versions/$VERSION"
STAGING="$PREFIX/versions/.staging-$VERSION-$$"
VERSION_ROLLBACK="$PREFIX/versions/.rollback-$VERSION-$$"
[[ "$STAGING" != "/" ]] || die "refusing unsafe staging path"
mkdir -p -- "$PREFIX/versions"
rm -rf -- "$STAGING"
mkdir -p -- "$STAGING"
tar -xzf "$TMP_DIR/$ARCHIVE" --no-same-owner --no-same-permissions -C "$STAGING"
chmod 0755 "$STAGING/bin/syndicate" "$STAGING/bin/syndicate-terminal-host" "$STAGING/runtime/node/bin/node"
[[ "$(<"$STAGING/VERSION")" == "$VERSION" ]] || die "release archive VERSION does not match $VERSION"
grep -Eq '"installerContract"[[:space:]]*:[[:space:]]*2([,[:space:]]|})' "$STAGING/runtime-manifest.json" \
  || die "release runtime is incompatible with this installer; use install.sh from the same versioned release"

# Record a digest of every regular file about to be installed. The staging tree
# is exactly the archive whose SHA-256 was matched against the Ed25519-signed
# SHA256SUMS above, so authenticity is already established here and re-reading
# these same bytes could not add to it. This is a *record*, verified later
# against the activated tree; see verify_tree_against_manifest.
#
# Exact-version reinstalls are always replaced from this freshly verified
# staging tree; existing bytes are never trusted or silently reused.
(
  cd "$STAGING"
  find . -type f ! -name INSTALL_MANIFEST.sha256 -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > INSTALL_MANIFEST.sha256
)
# An exact-version reinstall replaces the old tree wholesale, but its manifest
# is the one integrity record that predates this run, so report drift before
# discarding it. This is advisory: the replacement below is the remedy.
if [[ -d "$VERSION_DIR" ]] && ! verify_tree_against_manifest "$VERSION_DIR"; then
  log "Warning: the existing $VERSION installation no longer matches its recorded manifest; replacing it"
fi
[[ "$($STAGING/runtime/node/bin/node --version)" == "v24.14.1" ]] \
  || die "staged runtime failed preflight: bundled Node.js must be v24.14.1"

# Capture the state footprint before the installer creates anything. Rollback
# uses these markers to restore a pre-existing files-only installation and to
# remove every state artifact introduced by a failed clean first activation.
if [[ -e "$STATE_DIR" ]]; then
  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || die "state directory must be a real directory, not a link"
  STATE_DIR_EXISTED=1
fi
if [[ -e "$STATE_DIR/data" ]]; then
  [[ -d "$STATE_DIR/data" && ! -L "$STATE_DIR/data" ]] || die "state data path must be a real directory, not a link"
  DATA_EXISTED=1
fi
[[ -e "$STATE_DIR/local.key" ]] && LOCAL_KEY_EXISTED=1
[[ -d "$STATE_DIR/run" && ! -L "$STATE_DIR/run" ]] && RUN_DIR_EXISTED=1
[[ -e "$STATE_DIR/host.lock" ]] && HOST_LOCK_EXISTED=1
[[ -d "$STATE_DIR/backups" && ! -L "$STATE_DIR/backups" ]] && BACKUPS_DIR_EXISTED=1
[[ -d "$STATE_DIR/proxy-tls" && ! -L "$STATE_DIR/proxy-tls" ]] && PROXY_TLS_DIR_EXISTED=1

# The native runtime and Node Host authenticate over a same-user Unix socket.
# Provision the shared 256-bit secret locally; upgrades never replace it.
mkdir -p -- "$STATE_DIR/run"
chmod 0700 "$STATE_DIR" "$STATE_DIR/run"
if [[ ! -e "$STATE_DIR/local.key" ]]; then
  umask 077
  head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > "$STATE_DIR/local.key.tmp.$$"
  [[ "$(wc -c < "$STATE_DIR/local.key.tmp.$$")" -eq 43 ]] || die "could not generate the local runtime authentication key"
  chmod 0600 "$STATE_DIR/local.key.tmp.$$"
  mv -- "$STATE_DIR/local.key.tmp.$$" "$STATE_DIR/local.key"
fi
[[ -f "$STATE_DIR/local.key" && ! -L "$STATE_DIR/local.key" ]] || die "local runtime authentication key must be a regular file"
[[ "$(wc -c < "$STATE_DIR/local.key")" -eq 43 ]] && grep -Eq '^[A-Za-z0-9_-]{43}$' "$STATE_DIR/local.key" \
  || die "local runtime authentication key is malformed"
chmod 0600 "$STATE_DIR/local.key"

if (( LAN_PROXY )); then
  [[ -f "$STAGING/runtime/managed-proxy.mjs" ]] || die "release archive does not contain the managed LAN proxy runtime"
  PROXY_TLS_DIR="$STATE_DIR/proxy-tls"
  mkdir -p -- "$PROXY_TLS_DIR"
  chmod 0700 "$PROXY_TLS_DIR"
  # The server certificate names one IP address. A new LAN address, or an old certificate near
  # expiry, means a fresh server key and certificate under the existing CA; only a missing CA
  # starts over, because the CA is what operators have already installed in their browsers.
  REGENERATE_TLS=0
  REGENERATE_CA=0
  if [[ ! -e "$PROXY_TLS_DIR/ca.key" || ! -e "$PROXY_TLS_DIR/ca.crt" ]]; then
    REGENERATE_TLS=1; REGENERATE_CA=1
  elif [[ ! -e "$PROXY_TLS_DIR/server.key" || ! -e "$PROXY_TLS_DIR/server.crt" ]]; then
    REGENERATE_TLS=1
  elif ! openssl x509 -in "$PROXY_TLS_DIR/server.crt" -noout -ext subjectAltName 2>/dev/null \
      | grep -Fq "IP Address:$LAN_PROXY_ADDRESS"; then
    log "Managed proxy certificate names a different address; issuing a new one for $LAN_PROXY_ADDRESS"
    REGENERATE_TLS=1
  elif ! openssl x509 -in "$PROXY_TLS_DIR/server.crt" -noout -checkend 2592000 >/dev/null 2>&1; then
    log "Managed proxy certificate expires within 30 days; issuing a new one"
    REGENERATE_TLS=1
  fi
  if (( REGENERATE_TLS )); then
    if (( REGENERATE_CA )); then rm -f -- "$PROXY_TLS_DIR/ca.key" "$PROXY_TLS_DIR/ca.crt"; fi
    rm -f -- "$PROXY_TLS_DIR/server.key" "$PROXY_TLS_DIR/server.crt" \
      "$PROXY_TLS_DIR/server.csr" "$PROXY_TLS_DIR/server.ext"
    umask 077
    if (( REGENERATE_CA )); then
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
      -subj "/CN=Syndicate LAN CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "$PROXY_TLS_DIR/ca.key" -out "$PROXY_TLS_DIR/ca.crt" >/dev/null 2>&1
    fi
    openssl req -new -newkey rsa:3072 -nodes -sha256 \
      -subj "/CN=$LAN_PROXY_ADDRESS" \
      -keyout "$PROXY_TLS_DIR/server.key" -out "$PROXY_TLS_DIR/server.csr" >/dev/null 2>&1
    printf '%s\n' \
      "subjectAltName=IP:$LAN_PROXY_ADDRESS" \
      "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature,keyEncipherment" \
      "extendedKeyUsage=serverAuth" > "$PROXY_TLS_DIR/server.ext"
    openssl x509 -req -sha256 -days 825 \
      -in "$PROXY_TLS_DIR/server.csr" -CA "$PROXY_TLS_DIR/ca.crt" -CAkey "$PROXY_TLS_DIR/ca.key" \
      -set_serial "0x$(openssl rand -hex 16)" -extfile "$PROXY_TLS_DIR/server.ext" \
      -out "$PROXY_TLS_DIR/server.crt" >/dev/null 2>&1
    rm -f -- "$PROXY_TLS_DIR/server.csr" "$PROXY_TLS_DIR/server.ext"
  fi
  [[ -f "$PROXY_TLS_DIR/ca.key" && ! -L "$PROXY_TLS_DIR/ca.key" \
    && -f "$PROXY_TLS_DIR/ca.crt" && ! -L "$PROXY_TLS_DIR/ca.crt" \
    && -f "$PROXY_TLS_DIR/server.key" && ! -L "$PROXY_TLS_DIR/server.key" \
    && -f "$PROXY_TLS_DIR/server.crt" && ! -L "$PROXY_TLS_DIR/server.crt" ]] \
    || die "managed proxy TLS identity must use regular files"
  chmod 0600 "$PROXY_TLS_DIR/ca.key" "$PROXY_TLS_DIR/ca.crt" "$PROXY_TLS_DIR/server.key" "$PROXY_TLS_DIR/server.crt"
  LAN_PROXY_ORIGIN="https://$LAN_PROXY_ADDRESS:$LAN_PROXY_PORT"
fi

# Use the same deterministic executable search path for both user services.
# systemd does not expand $HOME in Environment= values, so resolve it here.
SERVICE_ENV_PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
printf -v SERVICE_PATH_VALUE '%q' "$SERVICE_ENV_PATH"
printf -v SERVICE_EXEC_VALUE '%q' "$PREFIX/current/bin/syndicate"
LAUNCHER_STAGED="$TMP_DIR/service-launcher"
cat > "$LAUNCHER_STAGED" <<EOF
#!/bin/bash
set -euo pipefail
export PATH=$SERVICE_PATH_VALUE
exec $SERVICE_EXEC_VALUE "\$@"
EOF
chmod 0700 "$LAUNCHER_STAGED"

if (( NO_SERVICE == 0 )); then
  mkdir -p -- "$SERVICE_DIR"
  umask 077
  SERVICE_TMP="$TMP_DIR/$SERVICE_NAME"
  TERMINAL_SERVICE_TMP="$TMP_DIR/$TERMINAL_SERVICE_NAME"
  PROXY_SERVICE_TMP="$TMP_DIR/$PROXY_SERVICE_NAME"
  cat > "$TERMINAL_SERVICE_TMP" <<EOF
[Unit]
Description=Syndicate durable terminal runtime
After=network.target

[Service]
Type=simple
WorkingDirectory=$PREFIX/current
Environment=PATH=$SERVICE_ENV_PATH
Environment=SYNDICATE_CONFIG_PATH=$SYNDICATE_CONFIG_PATH
ExecStart=$PREFIX/current/bin/syndicate-terminal-host --daemon $STATE_DIR/run/syndicate-terminal-host.sock --auth-file $STATE_DIR/local.key
Restart=always
RestartSec=2s
KillMode=control-group
TimeoutStopSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
  cat > "$SERVICE_TMP" <<EOF
[Unit]
Description=Syndicate private coding-agent host
Requires=$TERMINAL_SERVICE_NAME
After=network.target $TERMINAL_SERVICE_NAME

[Service]
Type=simple
WorkingDirectory=$PREFIX/current
Environment=SYNDICATE_PORT=4317
Environment=SYNDICATE_HOME=$STATE_DIR
Environment=SYNDICATE_CONFIG_PATH=$SYNDICATE_CONFIG_PATH
Environment=SYNDICATE_CONTROL_SOCKET_PATH=$STATE_DIR/run/host.sock
Environment=SYNDICATE_TERMINAL_HOST_PATH=$PREFIX/current/bin/syndicate-terminal-host
Environment=SYNDICATE_TERMINAL_HOST_SOCKET=$STATE_DIR/run/syndicate-terminal-host.sock
ExecStart=$PREFIX/service-launcher host run
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
  if (( LAN_PROXY )); then
    cat > "$PROXY_SERVICE_TMP" <<EOF
[Unit]
Description=Syndicate managed HTTPS LAN proxy
Requires=$SERVICE_NAME
After=network-online.target $SERVICE_NAME

[Service]
Type=simple
WorkingDirectory=$PREFIX/current
Environment=SYNDICATE_PROXY_LISTEN_HOST=0.0.0.0
Environment=SYNDICATE_PROXY_LISTEN_PORT=$LAN_PROXY_PORT
Environment=SYNDICATE_PROXY_PUBLIC_ORIGIN=$LAN_PROXY_ORIGIN
Environment=SYNDICATE_PROXY_UPSTREAM_PORT=4317
Environment=SYNDICATE_PROXY_CERTIFICATE_PATH=$PROXY_TLS_DIR/server.crt
Environment=SYNDICATE_PROXY_PRIVATE_KEY_PATH=$PROXY_TLS_DIR/server.key
ExecStart=$PREFIX/current/runtime/node/bin/node $PREFIX/current/runtime/managed-proxy.mjs
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
  fi
  chmod 0600 "$SERVICE_TMP" "$TERMINAL_SERVICE_TMP"
  (( LAN_PROXY == 0 )) || chmod 0600 "$PROXY_SERVICE_TMP"
fi

if [[ -L "$PREFIX/current" ]]; then
  PREVIOUS_CURRENT="$(readlink "$PREFIX/current")"
  [[ "$PREVIOUS_CURRENT" == versions/* && "$PREVIOUS_CURRENT" != *".."* ]] \
    || die "current install link has an unsafe target: $PREVIOUS_CURRENT"
elif [[ -e "$PREFIX/current" ]]; then
  die "$PREFIX/current must be a symbolic link"
fi
if (( DEFER_ACTIVATION )) && [[ -n "$PREVIOUS_CURRENT" ]]; then
  die "--defer-activation is only supported for a first installation"
fi

if (( NO_SERVICE == 0 )) && [[ -n "$PREVIOUS_CURRENT" && -f "$SERVICE_DIR/$WORKSTATION_SERVICE_NAME" ]] \
  && systemctl_user is-enabled --quiet "$WORKSTATION_SERVICE_NAME" >/dev/null 2>&1; then
  WORKSTATION_WAS_ENABLED=1
  previous_presentation="$(read_workstation_state "$TMP_DIR/workstation-before.json")" \
    || die "cannot inspect the enabled workstation before upgrading; run syndicate workstation status --json and repair or explicitly disable its boot unit first"
  if [[ "$previous_presentation" == "running" ]]; then WORKSTATION_WAS_RUNNING=1; fi
  "$PREFIX/current/bin/syndicate" workstation list --json > "$TMP_DIR/workstations-before.json" \
    || die "cannot read configured workstation identities before upgrading"
  WORKSTATION_KEY="$("$PREFIX/current/runtime/node/bin/node" -e '
    const fs = require("node:fs");
    const status = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const listed = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const match = listed.workstations?.find(value => value.key === status.key && value.repositoryPath === status.repositoryPath);
    if (!match || !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(match.key)) process.exit(2);
    process.stdout.write(match.key);
  ' "$TMP_DIR/workstation-before.json" "$TMP_DIR/workstations-before.json")" \
    || die "the workstation identity does not match its saved mapping; upgrade refused before stopping the Host"
fi

# Record the pre-activation state of the PATH launcher link so rollback can
# restore it exactly. A regular file or directory at that path is never
# replaced: it belongs to the user, not to this installer.
if [[ -L "$LAUNCHER_LINK" ]]; then
  LAUNCHER_LINK_EXISTED=1
  LAUNCHER_LINK_PREVIOUS="$(readlink "$LAUNCHER_LINK")"
  LAUNCHER_LINK_MANAGED=1
elif [[ -e "$LAUNCHER_LINK" ]]; then
  LAUNCHER_LINK_MANAGED=0
  log "Warning: $LAUNCHER_LINK already exists and is not a symbolic link; leaving it untouched"
else
  LAUNCHER_LINK_MANAGED=1
fi
if [[ -d "$LAUNCHER_LINK_DIR" && ! -L "$LAUNCHER_LINK_DIR" ]]; then
  LAUNCHER_LINK_DIR_EXISTED=1
elif [[ -e "$LAUNCHER_LINK_DIR" ]]; then
  LAUNCHER_LINK_MANAGED=0
  log "Warning: $LAUNCHER_LINK_DIR is not a directory; the syndicate command will not be placed on PATH"
fi

# Snapshot every rollback input without changing the running installation.
if [[ -e "$SYNDICATE_CONFIG_PATH" || -L "$SYNDICATE_CONFIG_PATH" ]]; then
  [[ -f "$SYNDICATE_CONFIG_PATH" && ! -L "$SYNDICATE_CONFIG_PATH" ]] || die "configuration must be a regular file before activation"
  cp -a -- "$SYNDICATE_CONFIG_PATH" "$TMP_DIR/old-config.json"
  OLD_CONFIG_SAVED=1
fi
CONFIG_SNAPSHOT_TAKEN=1
if [[ -f "$PREFIX/service-launcher" ]]; then cp -a -- "$PREFIX/service-launcher" "$TMP_DIR/old-service-launcher"; OLD_LAUNCHER_SAVED=1; fi
if (( NO_SERVICE == 0 )); then
  if [[ -f "$SERVICE_PATH" ]]; then cp -a -- "$SERVICE_PATH" "$TMP_DIR/old-$SERVICE_NAME"; OLD_SERVICE_SAVED=1; fi
  if [[ -f "$TERMINAL_SERVICE_PATH" ]]; then cp -a -- "$TERMINAL_SERVICE_PATH" "$TMP_DIR/old-$TERMINAL_SERVICE_NAME"; OLD_TERMINAL_SERVICE_SAVED=1; fi
  if [[ -f "$PROXY_SERVICE_PATH" ]]; then cp -a -- "$PROXY_SERVICE_PATH" "$TMP_DIR/old-$PROXY_SERVICE_NAME"; OLD_PROXY_SERVICE_SAVED=1; fi
  if [[ -f "$LEGACY_TERMINAL_SERVICE_PATH" ]]; then cp -a -- "$LEGACY_TERMINAL_SERVICE_PATH" "$TMP_DIR/old-$LEGACY_TERMINAL_SERVICE_NAME"; OLD_LEGACY_TERMINAL_SERVICE_SAVED=1; fi
  if systemctl_user is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1; then HOST_SERVICE_WAS_ACTIVE=1; fi
  if systemctl_user is-active --quiet "$TERMINAL_SERVICE_NAME" >/dev/null 2>&1; then TERMINAL_SERVICE_WAS_ACTIVE=1; fi
  if systemctl_user is-active --quiet "$PROXY_SERVICE_NAME" >/dev/null 2>&1; then PROXY_SERVICE_WAS_ACTIVE=1; fi
  if [[ -f "$LEGACY_TERMINAL_SERVICE_PATH" ]] \
    && systemctl_user is-active --quiet "$LEGACY_TERMINAL_SERVICE_NAME" >/dev/null 2>&1; then
    LEGACY_TERMINAL_SERVICE_WAS_ACTIVE=1
  fi
fi
# Complete read-only validation and every rollback snapshot before activation.
# An early refusal must not stop services or delete an untouched same-version tree.
WORKSTATION_LAUNCHER_PATH="$(dirname -- "$SYNDICATE_CONFIG_PATH")/workstation-start.sh"
if (( NO_SERVICE == 0 )) && [[ -f "$SERVICE_DIR/$WORKSTATION_SERVICE_NAME" \
  && -f "$WORKSTATION_LAUNCHER_PATH" && ! -L "$WORKSTATION_LAUNCHER_PATH" ]] \
  && grep -Fqx "ExecStart=$WORKSTATION_LAUNCHER_PATH" "$SERVICE_DIR/$WORKSTATION_SERVICE_NAME" \
  && grep -Fq 'syndicate-workstation: the Host did not become ready on loopback' "$WORKSTATION_LAUNCHER_PATH" \
  && grep -Fq "$PREFIX/current/bin/syndicate" "$WORKSTATION_LAUNCHER_PATH"; then
  cp -a -- "$WORKSTATION_LAUNCHER_PATH" "$TMP_DIR/old-workstation-start.sh"
  OLD_WORKSTATION_LAUNCHER_SAVED=1
fi
ACTIVATION_ACTIVE=1
if (( NO_SERVICE == 0 )); then
  # Stop only the Node Host. A successful `systemctl stop` is a synchronous
  # database quiescence boundary; syndicate-terminal-host remains alive across compatible
  # upgrades so its PTYs survive.
  if ! systemctl_user stop "$SERVICE_NAME"; then
    systemctl_user is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1 \
      && die "could not stop the existing Syndicate Host before backing up SQLite state"
  fi
  if (( LEGACY_TERMINAL_SERVICE_WAS_ACTIVE )); then
    log "Migrating the legacy syndicate-packet-host service to syndicate-terminal-host; existing terminal processes will stop once"
    systemctl_user stop "$LEGACY_TERMINAL_SERVICE_NAME"
  fi
fi

if (( DATA_EXISTED )); then
  BACKUP_DIR="$STATE_DIR/backups/activation-$(date -u +%Y%m%dT%H%M%SZ)-$VERSION-$$"
  mkdir -p -- "$BACKUP_DIR"
  chmod 0700 "$STATE_DIR/backups" "$BACKUP_DIR"
  # The Host is stopped above, so the database, `-wal`, and `-shm` sidecars form
  # one coherent SQLite snapshot. Copy the whole directory, never only the main
  # database file and never while the Host can still write it.
  cp -a -- "$STATE_DIR/data" "$BACKUP_DIR/data"
  if [[ -f "$STATE_DIR/local.key" ]]; then cp -a -- "$STATE_DIR/local.key" "$BACKUP_DIR/local.key"; fi
  printf '%s\n' "${PREVIOUS_CURRENT:-none}" > "$BACKUP_DIR/previous-current"
  log "Backed up activation state at $BACKUP_DIR"
fi
STATE_ROLLBACK_READY=1

if [[ -e "$VERSION_DIR" ]]; then
  rm -rf -- "$VERSION_ROLLBACK"
  mv -- "$VERSION_DIR" "$VERSION_ROLLBACK"
  OLD_VERSION_SAVED=1
fi
mv -- "$STAGING" "$VERSION_DIR"
VERSION_INSTALLED=1
ln -s -- "versions/$VERSION" "$PREFIX/.current-$$"
mv -Tf -- "$PREFIX/.current-$$" "$PREFIX/current"

# Verify the manifest against the files that are actually installed, reached
# through the activated `current` link rather than the staging path it was
# written from. This proves three things the staging-time record cannot: that
# every recorded file survived activation with the recorded bytes, that nothing
# unrecorded is present in the installed tree, and that `current` resolves to
# the version directory this run just wrote. A failure here rolls back.
verify_tree_against_manifest "$PREFIX/current" \
  || die "installed files at $PREFIX/current do not match the manifest recorded from the verified release archive"
log "Verified $(grep -c . "$VERSION_DIR/INSTALL_MANIFEST.sha256") installed files against INSTALL_MANIFEST.sha256"

cp -a -- "$LAUNCHER_STAGED" "$PREFIX/service-launcher"

# Put `syndicate` on the user's PATH. The link points at the stable `current`
# path, so it keeps resolving across upgrades without being rewritten.
if (( LAUNCHER_LINK_MANAGED )); then
  mkdir -p -- "$LAUNCHER_LINK_DIR"
  rm -f -- "$LAUNCHER_LINK.staging-$$"
  ln -s -- "$PREFIX/current/bin/syndicate" "$LAUNCHER_LINK.staging-$$"
  mv -Tf -- "$LAUNCHER_LINK.staging-$$" "$LAUNCHER_LINK"
fi

if (( NO_SERVICE == 0 )); then
  if (( OLD_WORKSTATION_LAUNCHER_SAVED )); then write_default_workstation_launcher; fi
  cp -a -- "$TERMINAL_SERVICE_TMP" "$TERMINAL_SERVICE_PATH"
  cp -a -- "$SERVICE_TMP" "$SERVICE_PATH"
  HAD_MANAGED_PROXY=0
  [[ -e "$PROXY_SERVICE_PATH" ]] && HAD_MANAGED_PROXY=1
  if (( LAN_PROXY )); then
    cp -a -- "$PROXY_SERVICE_TMP" "$PROXY_SERVICE_PATH"
  else
    # Disable before removing, or a dangling default.target.wants link outlives the unit.
    if (( HAD_MANAGED_PROXY )); then systemctl_user disable --now "$PROXY_SERVICE_NAME" || true; fi
    rm -f -- "$PROXY_SERVICE_PATH"
  fi
  systemctl_user daemon-reload
  if (( DEFER_ACTIVATION == 0 )); then
    if (( LAN_PROXY )); then
      "$PREFIX/current/bin/syndicate" setup --non-interactive --managed-dashboard-origin "$LAN_PROXY_ORIGIN"
      systemctl_user enable "$TERMINAL_SERVICE_NAME" "$SERVICE_NAME" "$PROXY_SERVICE_NAME"
    else
      # A Host left pointing at the removed HTTPS origin refuses every loopback browser mutation
      # as a foreign origin and hands out login links nothing answers.
      if (( HAD_MANAGED_PROXY )); then "$PREFIX/current/bin/syndicate" setup --non-interactive --loopback-dashboard; fi
      systemctl_user enable "$TERMINAL_SERVICE_NAME" "$SERVICE_NAME"
    fi
    # Start does not replace an already-running syndicate-terminal-host. This preserves PTYs;
    # the new Host must negotiate with that runtime or readiness rolls back.
    systemctl_user start "$TERMINAL_SERVICE_NAME"
    systemctl_user restart "$SERVICE_NAME"
    health_ready || die "new Host did not become ready after $HEALTHCHECK_ATTEMPTS attempts"
    log "Verified Host readiness at $HEALTHCHECK_URL"
    if (( LAN_PROXY )); then systemctl_user restart "$PROXY_SERVICE_NAME"; fi
  else
    log "Installed user services without enabling or starting them; run setup before activation"
  fi
  if [[ -f "$LEGACY_TERMINAL_SERVICE_PATH" ]]; then
    systemctl_user disable "$LEGACY_TERMINAL_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$LEGACY_TERMINAL_SERVICE_PATH"
    systemctl_user daemon-reload
    log "Removed the retired $LEGACY_TERMINAL_SERVICE_NAME unit"
  fi
fi

ACTIVATION_ACTIVE=0
if (( OLD_VERSION_SAVED )); then rm -rf -- "$VERSION_ROLLBACK"; fi

# Host/database activation is now committed. Re-convergence may create new live
# PTYs, so a presentation failure after this boundary must NOT restore an older
# database and orphan those writers. Keep the healthy Host and its native daemon,
# report a precise recovery action, and distinguish partial provider readiness.
if (( NO_SERVICE == 0 && DEFER_ACTIVATION == 0 && WORKSTATION_WAS_ENABLED && WORKSTATION_WAS_RUNNING )); then
  log "Re-converging the previously running workstation against the upgraded Host"
  restore_status=0
  "$PREFIX/current/bin/syndicate" workstation recover "$WORKSTATION_KEY" --detach || restore_status=$?
  restore_command_status="$restore_status"
  presentation="$(read_workstation_state "$TMP_DIR/workstation-after.json" "$WORKSTATION_KEY")" \
    || die "Host upgrade succeeded, but workstation status could not be verified; native PTYs are retained. Run: $PREFIX/current/bin/syndicate workstation recover $WORKSTATION_KEY --detach"
  if [[ "$presentation" == "running" ]] && "$PREFIX/current/runtime/node/bin/node" -e '
    const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    process.exit(value.readiness === "degraded" ? 0 : 1);
  ' "$TMP_DIR/workstation-after.json" \
    && [[ "$restore_command_status" == "0" || "$restore_command_status" == "2" ]]; then
    log "Warning: Host upgrade succeeded; selected workstation providers remain unavailable. Run: $PREFIX/current/bin/syndicate workstation status --json"
  elif [[ "$restore_status" == "0" && "$presentation" == "running" ]] \
    && "$PREFIX/current/runtime/node/bin/node" -e '
      const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      process.exit(value.readiness === "ready" ? 0 : 1);
    ' "$TMP_DIR/workstation-after.json"; then
    log "Verified workstation presentation after upgrade"
  else
    die "Host upgrade succeeded, but workstation restoration failed; native PTYs are retained and no database rollback was attempted. Run: $PREFIX/current/bin/syndicate workstation recover $WORKSTATION_KEY --detach"
  fi
fi

if (( ENABLE_LINGER )); then
  if command -v loginctl >/dev/null 2>&1; then
    if ! run loginctl enable-linger "$(id -un)"; then
      log "Could not enable lingering without administrator policy. Ask an administrator to run:"
      log "  sudo loginctl enable-linger $(id -un)"
    fi
  else
    log "loginctl is unavailable; the user service may stop after logout."
  fi
fi

log "Syndicate $VERSION installed at $PREFIX"
log "Persistent state and managed worktrees live at $STATE_DIR"
if (( LAUNCHER_LINK_MANAGED )); then
  log "Linked the syndicate command at $LAUNCHER_LINK"
  case ":${PATH:-}:" in
    *":$LAUNCHER_LINK_DIR:"*) ;;
    *)
      log "Warning: $LAUNCHER_LINK_DIR is not on your PATH, so 'syndicate' will not be found."
      log "  Add it for future shells with:"
      log "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.profile"
      log "  Until then, run the command by its full path: $LAUNCHER_LINK"
      ;;
  esac
else
  log "Warning: the syndicate command was not placed on PATH; run it as $PREFIX/current/bin/syndicate"
fi
if (( NO_SERVICE )); then
  log "No service was installed. Start manually with: $PREFIX/current/bin/syndicate"
else
  if (( LAN_PROXY )); then
    log "Managed LAN access: $LAN_PROXY_ORIGIN"
    log "Certificate authority to trust on LAN clients: $PROXY_TLS_DIR/ca.crt"
    invitation="$($PREFIX/current/bin/syndicate dashboard --no-open 2>/dev/null || true)"
    [[ -z "$invitation" ]] || log "Open this one-time login URL: $invitation"
  else
    log "The host listens on loopback only: http://127.0.0.1:4317"
  fi
  log "For unattended operation after logout, rerun with --enable-linger or ask an administrator."
  log "View logs with: journalctl --user -u $SERVICE_NAME -u $TERMINAL_SERVICE_NAME -u $PROXY_SERVICE_NAME -f"
fi

}
syndicate_install_main "$@"
