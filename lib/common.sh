#!/usr/bin/env bash
# Shared Avagato helpers. Sourced by avagato.sh and environment modules.

bold='\033[1m'; red='\033[31m'; green='\033[32m'; yellow='\033[33m'; cyan='\033[36m'; reset='\033[0m'

say(){ printf '%b\n' "$*"; }
die(){ say "${red}ERROR:${reset} $*" >&2; exit 1; }
require_commands(){ local cmd; for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done; }
pause(){ read -r -p "Press Enter to continue..." _; }
confirm(){ local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

is_pve_host(){
  command -v pveversion >/dev/null 2>&1 &&
  [[ -d /etc/pve ]] &&
  command -v dpkg-query >/dev/null 2>&1 &&
  dpkg-query -W -f='${Status}' proxmox-ve 2>/dev/null | grep -Fq 'install ok installed'
}
