#!/usr/bin/env bash
# Syndicate Linux installer. This file is intentionally self-contained so the
# curl pipe is the only downloaded code that executes before artifact checks.
set -euo pipefail

PROGRAM="syndicate-install"
REPOSITORY="${SYNDICATE_INSTALL_REPOSITORY:-packetloss404/syndicate-releases}"
VERSION="${SYNDICATE_INSTALL_VERSION:-latest}"
PREFIX="${SYNDICATE_INSTALL_PREFIX:-${HOME:?HOME must be set}/.local/share/syndicate}"
STATE_DIR="${SYNDICATE_INSTALL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/syndicate}"
DRY_RUN=0
UNINSTALL=0
ENABLE_LINGER=0
NO_SERVICE=0
KEEP_DOWNLOADS=0
RELEASE_BASE_URL="${SYNDICATE_INSTALL_RELEASE_BASE_URL:-}"
CHECKSUMS_URL="${SYNDICATE_INSTALL_CHECKSUMS_URL:-}"
SYSTEMCTL_USER="${SYNDICATE_INSTALL_SYSTEMCTL_USER:-systemctl --user}"
ALLOW_FILE_URL="${SYNDICATE_INSTALL_ALLOW_FILE_URL:-0}"
HEALTHCHECK_URL="${SYNDICATE_INSTALL_HEALTHCHECK_URL:-http://127.0.0.1:4317/api/v1/health}"
HEALTHCHECK_ATTEMPTS="${SYNDICATE_INSTALL_HEALTHCHECK_ATTEMPTS:-30}"
SERVICE_NAME="syndicate.service"
PACKET_SERVICE_NAME="syndicate-packet-host.service"
TMP_DIR=""
ACTIVATION_ACTIVE=0

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
  --prefix PATH          Install root (default: ~/.local/share/syndicate).
  --dry-run              Print planned actions without downloading or writing.
  --no-service           Install files but do not write/enable a user service.
  --enable-linger        Ask loginctl to keep the user service alive after logout.
  --uninstall            Disable the service and remove the selected prefix.
  --keep-downloads       Retain the temporary download directory for inspection.
  -h, --help             Show this help.

Release contract:
  The selected GitHub release must publish both files below for this platform:
    syndicate-VERSION-linux-ARCH.tar.gz
    SHA256SUMS
    SHA256SUMS.sig

  The archive must contain bin/syndicate, bin/syndicate-packet-host, and the
  built dashboard at apps/dashboard/dist. Each version is installed under
  PREFIX/versions/VERSION, then PREFIX/current changes atomically. The installer
  downloads data only, verifies SHA256SUMS with Syndicate's pinned Ed25519
  release key, verifies the archive with SHA-256, rejects unsafe archive paths,
  and then extracts it. It never executes another downloaded installer.

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

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$KEEP_DOWNLOADS" -eq 0 ]]; then
    rm -rf -- "$TMP_DIR"
  elif [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Downloads retained at $TMP_DIR"
  fi
}

finish() {
  local status=$?
  trap - EXIT
  if (( status != 0 && ACTIVATION_ACTIVE )); then rollback_activation; fi
  cleanup
  exit "$status"
}
trap finish EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || die "--prefix requires a value"
      PREFIX="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-service) NO_SERVICE=1; shift ;;
    --enable-linger) ENABLE_LINGER=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --keep-downloads) KEEP_DOWNLOADS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (run with --help)" ;;
  esac
done

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

SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_PATH="$SERVICE_DIR/$SERVICE_NAME"
PACKET_SERVICE_PATH="$SERVICE_DIR/$PACKET_SERVICE_NAME"

systemctl_user() {
  local -a command
  read -r -a command <<< "$SYSTEMCTL_USER"
  [[ ${#command[@]} -gt 0 ]] || die "empty SYNDICATE_INSTALL_SYSTEMCTL_USER"
  run "${command[@]}" "$@"
}

if (( UNINSTALL )); then
  log "Uninstalling Syndicate from $PREFIX"
  if (( NO_SERVICE == 0 )); then
    systemctl_user disable --now "$SERVICE_NAME" "$PACKET_SERVICE_NAME" || true
    run rm -f -- "$SERVICE_PATH" "$PACKET_SERVICE_PATH"
    systemctl_user daemon-reload || true
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
  run mkdir -p -- "$PREFIX"
  if (( NO_SERVICE == 0 )); then
    run mkdir -p -- "$SERVICE_DIR"
    run install -m 0600 /dev/null "$SERVICE_PATH"
    run install -m 0600 /dev/null "$PACKET_SERVICE_PATH"
    systemctl_user daemon-reload
    systemctl_user enable --now "$PACKET_SERVICE_NAME" "$SERVICE_NAME"
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
  bin/syndicate-packet-host \
  runtime/host.mjs \
  runtime/node/bin/node \
  runtime-manifest.json \
  SBOM.spdx.json \
  release-metadata.json \
  THIRD_PARTY_NOTICES.md \
  licenses/node/LICENSE \
  licenses/syndicate-packet-host/NOTICE \
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
chmod 0755 "$STAGING/bin/syndicate" "$STAGING/bin/syndicate-packet-host" "$STAGING/runtime/node/bin/node"
[[ "$(<"$STAGING/VERSION")" == "$VERSION" ]] || die "release archive VERSION does not match $VERSION"

# Record and verify every installed regular file. Exact-version reinstalls are
# always replaced from this freshly verified staging tree; existing bytes are
# never trusted or silently reused.
(
  cd "$STAGING"
  find . -type f ! -name INSTALL_MANIFEST.sha256 -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > INSTALL_MANIFEST.sha256
  sha256sum -c INSTALL_MANIFEST.sha256 >/dev/null
)
[[ "$($STAGING/runtime/node/bin/node --version)" == "v24.14.1" ]] \
  || die "staged runtime failed preflight: bundled Node.js must be v24.14.1"

# Capture the state footprint before the installer creates anything. Rollback
# uses these markers to restore a pre-existing files-only installation and to
# remove every state artifact introduced by a failed clean first activation.
STATE_DIR_EXISTED=0
DATA_EXISTED=0
LOCAL_KEY_EXISTED=0
RUN_DIR_EXISTED=0
HOST_LOCK_EXISTED=0
BACKUPS_DIR_EXISTED=0
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

# Preserve the caller's current agent/tool PATH for the user service. This is
# generated locally after artifact verification; it is not downloaded code.
printf -v SERVICE_PATH_VALUE '%q' "$PATH"
printf -v SERVICE_EXEC_VALUE '%q' "$PREFIX/current/bin/syndicate"
LAUNCHER_STAGED="$TMP_DIR/service-launcher"
cat > "$LAUNCHER_STAGED" <<EOF
#!/bin/bash
set -euo pipefail
export PATH=$SERVICE_PATH_VALUE
exec $SERVICE_EXEC_VALUE
EOF
chmod 0700 "$LAUNCHER_STAGED"

if (( NO_SERVICE == 0 )); then
  mkdir -p -- "$SERVICE_DIR"
  umask 077
  SERVICE_TMP="$TMP_DIR/$SERVICE_NAME"
  PACKET_SERVICE_TMP="$TMP_DIR/$PACKET_SERVICE_NAME"
  cat > "$PACKET_SERVICE_TMP" <<EOF
[Unit]
Description=Syndicate durable terminal runtime
After=network.target

[Service]
Type=simple
WorkingDirectory=$PREFIX/current
ExecStart=$PREFIX/current/bin/syndicate-packet-host --daemon $STATE_DIR/run/packet-host.sock --auth-file $STATE_DIR/local.key
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
Requires=$PACKET_SERVICE_NAME
After=network.target $PACKET_SERVICE_NAME

[Service]
Type=simple
WorkingDirectory=$PREFIX/current
Environment=SYNDICATE_PORT=4317
Environment=SYNDICATE_HOME=$STATE_DIR
Environment=SYNDICATE_PACKET_HOST_PATH=$PREFIX/current/bin/syndicate-packet-host
Environment=SYNDICATE_PACKET_HOST_SOCKET=$STATE_DIR/run/packet-host.sock
ExecStart=$PREFIX/service-launcher
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
  chmod 0600 "$SERVICE_TMP" "$PACKET_SERVICE_TMP"
fi

PREVIOUS_CURRENT=""
if [[ -L "$PREFIX/current" ]]; then
  PREVIOUS_CURRENT="$(readlink "$PREFIX/current")"
  [[ "$PREVIOUS_CURRENT" == versions/* && "$PREVIOUS_CURRENT" != *".."* ]] \
    || die "current install link has an unsafe target: $PREVIOUS_CURRENT"
elif [[ -e "$PREFIX/current" ]]; then
  die "$PREFIX/current must be a symbolic link"
fi

BACKUP_DIR=""
STATE_ROLLBACK_READY=0
OLD_VERSION_SAVED=0
OLD_LAUNCHER_SAVED=0
OLD_SERVICE_SAVED=0
OLD_PACKET_SERVICE_SAVED=0
HOST_SERVICE_WAS_ACTIVE=0
PACKET_SERVICE_WAS_ACTIVE=0

rollback_activation() {
  set +e
  log "Activation failed; restoring the previous Syndicate runtime and state"
  if (( NO_SERVICE == 0 )); then
    systemctl_user stop "$SERVICE_NAME" >/dev/null 2>&1
    if [[ -z "$PREVIOUS_CURRENT" ]]; then
      # A failed first install introduced both services. Remove that entire
      # service footprint rather than leaving a new packet-host daemon alive.
      systemctl_user disable --now "$SERVICE_NAME" "$PACKET_SERVICE_NAME" >/dev/null 2>&1
    elif (( PACKET_SERVICE_WAS_ACTIVE == 0 )); then
      # If this activation started a packet-host that was previously stopped,
      # do not leave the new binary resident after switching back to old files.
      systemctl_user stop "$PACKET_SERVICE_NAME" >/dev/null 2>&1
    fi
  fi

  rm -f -- "$PREFIX/current" "$PREFIX/.current-$$"
  if [[ -n "$PREVIOUS_CURRENT" ]]; then
    ln -s -- "$PREVIOUS_CURRENT" "$PREFIX/.current-rollback-$$"
    mv -Tf -- "$PREFIX/.current-rollback-$$" "$PREFIX/current"
  fi

  if [[ -e "$VERSION_DIR" ]]; then rm -rf -- "$VERSION_DIR"; fi
  if (( OLD_VERSION_SAVED )); then mv -- "$VERSION_ROLLBACK" "$VERSION_DIR"; fi

  if (( STATE_ROLLBACK_READY )); then
    if (( STATE_DIR_EXISTED == 0 )); then
      rm -rf -- "$STATE_DIR"
    else
      rm -rf -- "$STATE_DIR/data"
      if (( DATA_EXISTED )); then cp -a -- "$BACKUP_DIR/data" "$STATE_DIR/data"; fi
      if (( LOCAL_KEY_EXISTED == 0 )); then rm -f -- "$STATE_DIR/local.key"; fi
      if (( HOST_LOCK_EXISTED == 0 )); then rm -f -- "$STATE_DIR/host.lock"; fi
      if (( RUN_DIR_EXISTED == 0 && PACKET_SERVICE_WAS_ACTIVE == 0 )); then rm -rf -- "$STATE_DIR/run"; fi
      if [[ -n "$BACKUP_DIR" ]]; then rm -rf -- "$BACKUP_DIR"; fi
      if (( BACKUPS_DIR_EXISTED == 0 )); then rmdir -- "$STATE_DIR/backups" >/dev/null 2>&1 || true; fi
    fi
  fi

  if (( OLD_LAUNCHER_SAVED )); then
    cp -a -- "$TMP_DIR/old-service-launcher" "$PREFIX/service-launcher"
  else
    rm -f -- "$PREFIX/service-launcher"
  fi
  if (( NO_SERVICE == 0 )); then
    if (( OLD_SERVICE_SAVED )); then cp -a -- "$TMP_DIR/old-$SERVICE_NAME" "$SERVICE_PATH"; else rm -f -- "$SERVICE_PATH"; fi
    if (( OLD_PACKET_SERVICE_SAVED )); then cp -a -- "$TMP_DIR/old-$PACKET_SERVICE_NAME" "$PACKET_SERVICE_PATH"; else rm -f -- "$PACKET_SERVICE_PATH"; fi
    systemctl_user daemon-reload >/dev/null 2>&1
    # A packet-host that predated activation is deliberately not restarted: its
    # PTYs survive the Host rollback. Service activity is restored to its prior
    # state instead of unexpectedly starting a previously stopped installation.
    if [[ -n "$PREVIOUS_CURRENT" ]]; then
      if (( PACKET_SERVICE_WAS_ACTIVE )); then systemctl_user start "$PACKET_SERVICE_NAME" >/dev/null 2>&1; fi
      if (( HOST_SERVICE_WAS_ACTIVE )); then systemctl_user restart "$SERVICE_NAME" >/dev/null 2>&1; fi
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

# From this point onward an error must roll back the current link, services,
# exact-version directory, and any database migrations made by the new Host.
ACTIVATION_ACTIVE=1
if [[ -f "$PREFIX/service-launcher" ]]; then cp -a -- "$PREFIX/service-launcher" "$TMP_DIR/old-service-launcher"; OLD_LAUNCHER_SAVED=1; fi
if (( NO_SERVICE == 0 )); then
  if [[ -f "$SERVICE_PATH" ]]; then cp -a -- "$SERVICE_PATH" "$TMP_DIR/old-$SERVICE_NAME"; OLD_SERVICE_SAVED=1; fi
  if [[ -f "$PACKET_SERVICE_PATH" ]]; then cp -a -- "$PACKET_SERVICE_PATH" "$TMP_DIR/old-$PACKET_SERVICE_NAME"; OLD_PACKET_SERVICE_SAVED=1; fi
  if systemctl_user is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1; then HOST_SERVICE_WAS_ACTIVE=1; fi
  if systemctl_user is-active --quiet "$PACKET_SERVICE_NAME" >/dev/null 2>&1; then PACKET_SERVICE_WAS_ACTIVE=1; fi
  # Stop only the Node Host. A successful `systemctl stop` is a synchronous
  # database quiescence boundary; packet-host remains alive across compatible
  # upgrades so its PTYs survive.
  if ! systemctl_user stop "$SERVICE_NAME"; then
    systemctl_user is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1 \
      && die "could not stop the existing Syndicate Host before backing up SQLite state"
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
ln -s -- "versions/$VERSION" "$PREFIX/.current-$$"
mv -Tf -- "$PREFIX/.current-$$" "$PREFIX/current"
cp -a -- "$LAUNCHER_STAGED" "$PREFIX/service-launcher"

if (( NO_SERVICE == 0 )); then
  cp -a -- "$PACKET_SERVICE_TMP" "$PACKET_SERVICE_PATH"
  cp -a -- "$SERVICE_TMP" "$SERVICE_PATH"
  systemctl_user daemon-reload
  systemctl_user enable "$PACKET_SERVICE_NAME" "$SERVICE_NAME"
  # Start does not replace an already-running packet-host. This preserves PTYs;
  # the new Host must negotiate with that runtime or readiness rolls back.
  systemctl_user start "$PACKET_SERVICE_NAME"
  systemctl_user restart "$SERVICE_NAME"
  health_ready || die "new Host did not become ready after $HEALTHCHECK_ATTEMPTS attempts"
  log "Verified Host readiness at $HEALTHCHECK_URL"
fi

ACTIVATION_ACTIVE=0
if (( OLD_VERSION_SAVED )); then rm -rf -- "$VERSION_ROLLBACK"; fi

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
if (( NO_SERVICE )); then
  log "No service was installed. Start manually with: $PREFIX/current/bin/syndicate"
else
  log "The host listens on loopback only: http://127.0.0.1:4317"
  log "For unattended operation after logout, rerun with --enable-linger or ask an administrator."
  log "View logs with: journalctl --user -u $SERVICE_NAME -u $PACKET_SERVICE_NAME -f"
fi
