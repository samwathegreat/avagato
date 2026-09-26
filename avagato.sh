#!/usr/bin/env bash
set -Eeuo pipefail

AVAGATO_VERSION="1.3.0"
AVAGATO_REPO="${AVAGATO_REPO:-https://raw.githubusercontent.com/samwathegreat/avagato/main}"
# BASH_SOURCE is unset when the documented launcher is executed via stdin
# (for example: curl .../avagato.sh | bash). In that case there is no local
# checkout to search, so module loading should fall back to AVAGATO_REPO.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
else
  SELF_DIR=""
fi
TMP_DIR=""

cleanup(){ [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

load_module(){
  local rel="$1"
  local local_path=""
  if [[ -n "$SELF_DIR" ]]; then
    local_path="$SELF_DIR/$rel"
  fi
  if [[ -n "$local_path" && -f "$local_path" ]]; then
    # shellcheck source=/dev/null
    source "$local_path"
    return
  fi
  command -v curl >/dev/null 2>&1 || { printf 'ERROR: curl is required to load Avagato modules.\n' >&2; exit 1; }
  [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"
  local_path="$TMP_DIR/$(basename "$rel")"
  local module_url="$AVAGATO_REPO/$rel"
  # Avoid stale child modules when the launcher itself is current. This is
  # internal only; users can keep using the clean, stable avagato.sh URL.
  if [[ "$module_url" == https://raw.githubusercontent.com/* ]]; then
    module_url="${module_url}?avagato=$(date +%s)"
  fi
  curl -fsSL --retry 3 --proto '=https' --tlsv1.2 "$module_url" -o "$local_path"
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
  if [[ "$AVAGATO_GUAC_DOCKER" == 1 ]]; then
    say "${yellow}Both a supported native Guacamole installation and a Docker Guacamole deployment were detected.${reset}"
    say "Avagato will not modify either installation automatically in this ambiguous state."
    say "Docker itself is not a conflict; the conflict is the additional Guacamole web application detected in Docker."
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
  load_module lib/docker.sh
  docker_menu
  exit 0
fi

if [[ "$AVAGATO_GUAC_DOCKER" == 1 ]]; then
  say "${yellow}An existing Docker-based Apache Guacamole deployment was detected, but it is not identified as Avagato-managed.${reset}"
  say "Avagato will not modify or replace an existing Docker Guacamole deployment it does not manage."
  exit 1
fi

if [[ "$AVAGATO_DOCKER" == 1 && "$AVAGATO_COMPOSE" == 1 ]]; then
  if [[ "$AVAGATO_NATIVE_EVIDENCE" == 1 ]]; then
    die "Native Guacamole evidence was detected, but it does not match Avagato's supported native layout. Avagato will not create a second Guacamole installation until the residual or unknown native installation is resolved."
  fi
  load_module lib/docker.sh
  docker_install
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
