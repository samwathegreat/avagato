#!/usr/bin/env bash
set -Eeuo pipefail

AVAGATO_VERSION="1.3.0"
AVAGATO_REPO="${AVAGATO_REPO:-https://raw.githubusercontent.com/samwathegreat/avagato/main}"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR=""

cleanup(){ [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

load_module(){
  local rel="$1"
  local local_path="$SELF_DIR/$rel"
  if [[ -f "$local_path" ]]; then
    # shellcheck source=/dev/null
    source "$local_path"
    return
  fi
  command -v curl >/dev/null 2>&1 || { printf 'ERROR: curl is required to load Avagato modules.\n' >&2; exit 1; }
  [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"
  local_path="$TMP_DIR/$(basename "$rel")"
  curl -fsSL --retry 3 --proto '=https' --tlsv1.2 "$AVAGATO_REPO/$rel" -o "$local_path"
  # shellcheck source=/dev/null
  source "$local_path"
}

load_module lib/common.sh
load_module lib/detect.sh

[[ $EUID -eq 0 ]] || die "Run Avagato as root."

if is_pve_host; then
  die "Avagato must not be installed directly on a Proxmox VE host. Create a dedicated container or VM and run Avagato there."
fi

detect_environment

if [[ "$AVAGATO_NATIVE" == 1 ]]; then
  if [[ "$AVAGATO_DOCKER_STACK" == 1 ]]; then
    say "${yellow}Both a supported native Guacamole installation and an Avagato Docker stack were detected.${reset}"
    say "Avagato will not modify either installation automatically in this ambiguous state."
    exit 1
  fi
  if [[ "$AVAGATO_DOCKER" == 1 ]]; then
    say "${yellow}Existing native Apache Guacamole installation detected. Docker is also available.${reset}"
    say
    say "Avagato will manage the existing native installation and will not create a second Guacamole installation."
    say "Migration between native and Docker Guacamole installations is outside Avagato's scope."
    say
  fi
  load_module lib/native.sh
  check_environment
  backup_warning
  menu
  exit 0
fi

if [[ "$AVAGATO_DOCKER_STACK" == 1 ]]; then
  say "Existing Avagato Docker deployment detected."
  say "Docker management will be enabled after the Docker module is added."
  exit 0
fi

if [[ "$AVAGATO_DOCKER" == 1 && "$AVAGATO_COMPOSE" == 1 ]]; then
  say "Docker Engine and Docker Compose detected."
  say "No existing Guacamole installation was detected."
  say "Avagato's Docker deployment module is the next implementation stage."
  exit 0
fi

say "No existing supported Guacamole installation was detected."
say
say "Avagato's recommended installation method requires Docker Engine and Docker Compose."
say
say "For Proxmox VE users:"
say "  Create a dedicated Docker LXC using the Proxmox VE Community Scripts Docker installer,"
say "  then run Avagato inside that container."
say
say "For other supported Linux systems:"
say "  Install Docker Engine and the Docker Compose plugin using Docker's official instructions,"
say "  then run Avagato again."
