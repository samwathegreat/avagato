#!/usr/bin/env bash
# Avagato Docker deployment and management for Apache Guacamole 1.6.0.

AVAGATO_DIR="/opt/avagato"
COMPOSE_FILE="$AVAGATO_DIR/compose.yaml"
ENV_FILE="$AVAGATO_DIR/.env"
GUAC_VERSION="1.6.0"
POSTGRES_MAJOR="17"
DOCKER_DARK_THEME_JAR="$AVAGATO_DIR/guacamole-home/extensions/guacamole-avagato-dark-theme.jar"
DOCKER_LIGHT_THEME_JAR="$AVAGATO_DIR/guacamole-home/extensions/guacamole-avagato-light-theme.jar"

docker_compose(){ docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

docker_port_in_use(){
  local port="$1"
  if command -v ss >/dev/null 2>&1 && ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"; then return 0; fi
  docker ps -a --format '{{.Ports}}' 2>/dev/null | grep -Eq "(^|[^0-9])$port->|:$port->" && return 0
  return 1
}

prompt_http_port(){
  local default="${1:-8080}" p
  while true; do
    read -r -p "Guacamole HTTP port [$default]: " p
    p="${p:-$default}"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || { say "${yellow}Enter a TCP port from 1 through 65535.${reset}"; continue; }
    if docker_port_in_use "$p"; then
      if [[ -n "${AVAGATO_ALLOW_CURRENT_PORT:-}" && "$p" == "$AVAGATO_ALLOW_CURRENT_PORT" ]]; then
        :
      else
        say "${yellow}Port $p is already in use. Choose another port or resolve the conflict.${reset}"
        continue
      fi
    fi
    GUACAMOLE_HTTP_PORT="$p"
    return 0
  done
}

generate_password(){ openssl rand -hex 24; }

docker_preflight(){
  local arch free_kb
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "Unsupported or untested CPU architecture: $arch" ;;
  esac

  free_kb="$(df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 2097152 )); then
    say "${yellow}WARNING:${reset} Less than 2 GiB of free space is available under /opt."
    confirm "Continue anyway?" || return 1
  fi
}

prompt_rdp_drive(){
  AVAGATO_RDP_DRIVE=0
  say
  say "Optional RDP drive sharing exposes /opt/avagato/data/drive to guacd as /drive."
  if confirm "Enable RDP drive sharing?"; then
    AVAGATO_RDP_DRIVE=1
  fi
  return 0
}

write_compose(){
  cat > "$COMPOSE_FILE" <<'YAML'
services:
  postgres:
    image: postgres:17
    container_name: avagato-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: guacamole_db
      POSTGRES_USER: guacamole_user
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets:
      - postgres_password
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d:ro
    labels:
      org.avagato.managed: "true"
      org.avagato.component: "postgres"

  guacd:
    image: guacamole/guacd:1.6.0
    container_name: avagato-guacd
    restart: unless-stopped
    labels:
      org.avagato.managed: "true"
      org.avagato.component: "guacd"
__AVAGATO_GUACD_DRIVE__

  guacamole:
    image: guacamole/guacamole:1.6.0
    container_name: avagato-guacamole
    restart: unless-stopped
    depends_on:
      - guacd
      - postgres
    environment:
      GUACD_HOSTNAME: guacd
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_DATABASE: guacamole_db
      POSTGRESQL_USERNAME: guacamole_user
      POSTGRESQL_PASSWORD: "${POSTGRESQL_PASSWORD}"
      WEBAPP_CONTEXT: ROOT
    ports:
      - "${GUACAMOLE_HTTP_PORT}:8080"
    volumes:
      - ./guacamole-home:/etc/guacamole:ro
    labels:
      org.avagato.managed: "true"
      org.avagato.component: "guacamole"

secrets:
  postgres_password:
    file: ./secrets/postgres_password
YAML
  if [[ "${AVAGATO_RDP_DRIVE:-0}" == 1 ]]; then
    sed -i 's|^__AVAGATO_GUACD_DRIVE__$|    volumes:\n      - ./data/drive:/drive|' "$COMPOSE_FILE"
  else
    sed -i '/^__AVAGATO_GUACD_DRIVE__$/d' "$COMPOSE_FILE"
  fi
}

write_env(){
  local db_password
  db_password="$(cat "$AVAGATO_DIR/secrets/postgres_password")"
  {
    printf 'GUACAMOLE_HTTP_PORT=%s\n' "$GUACAMOLE_HTTP_PORT"
    printf 'POSTGRESQL_PASSWORD=%s\n' "$db_password"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

generate_schema(){
  say "Generating the official Guacamole PostgreSQL schema..."
  docker run --rm "guacamole/guacamole:${GUAC_VERSION}" /opt/guacamole/bin/initdb.sh --postgresql > "$AVAGATO_DIR/init/001-guacamole.sql"
  [[ -s "$AVAGATO_DIR/init/001-guacamole.sql" ]] || die "Guacamole database schema generation failed."
}

docker_status(){
  local port="unknown" theme_status="Not installed" theme_jar="" variant="" installed="" available="" rdp_drive_status="Disabled"
  [[ -f "$ENV_FILE" ]] && port="$(sed -n 's/^GUACAMOLE_HTTP_PORT=//p' "$ENV_FILE" | head -n1)"
  grep -Fq -- '- ./data/drive:/drive' "$COMPOSE_FILE" 2>/dev/null && rdp_drive_status="Enabled"
  load_module lib/theme.sh
  if [[ -f "$DOCKER_DARK_THEME_JAR" && -f "$DOCKER_LIGHT_THEME_JAR" ]]; then
    theme_status="Conflict: Dark and Light are both installed"
  elif [[ -f "$DOCKER_DARK_THEME_JAR" ]]; then theme_jar="$DOCKER_DARK_THEME_JAR"
  elif [[ -f "$DOCKER_LIGHT_THEME_JAR" ]]; then theme_jar="$DOCKER_LIGHT_THEME_JAR"
  fi
  if [[ -n "$theme_jar" ]]; then
    variant="$(theme_jar_variant "$theme_jar" 2>/dev/null || true)"
    if [[ -z "$variant" ]]; then theme_status="Unknown JAR present"
    else
      installed="$(theme_jar_version "$theme_jar")"; available="$(theme_variant_version "$variant")"
      if [[ -z "$installed" ]]; then theme_status="${variant^} (unversioned; available: $available)"
      elif [[ "$installed" == "$available" ]]; then theme_status="${variant^} ($installed; current)"
      else theme_status="${variant^} ($installed; available: $available)"
      fi
    fi
  fi
  say "${bold}Current status${reset}"
  printf '  %-25s %s\n' 'Deployment' 'Avagato Docker'
  printf '  %-25s %s\n' 'Guacamole version' "$GUAC_VERSION"
  printf '  %-25s %s\n' 'HTTP port' "$port"
  printf '  %-25s %s\n' 'TOTP' "$(grep -Eq '^[[:space:]]+TOTP_ENABLED:[[:space:]]*\"?true\"?' "$COMPOSE_FILE" 2>/dev/null && echo Enabled || echo Disabled)"
  printf '  %-25s %s\n' 'Avagato Theme' "$theme_status"
  say
  docker_compose ps 2>/dev/null || true
}
change_http_port(){
  local old
  old="$(sed -n 's/^GUACAMOLE_HTTP_PORT=//p' "$ENV_FILE" | head -n1)"
  AVAGATO_ALLOW_CURRENT_PORT="$old" prompt_http_port "$old"
  [[ "$GUACAMOLE_HTTP_PORT" == "$old" ]] && { say "HTTP port unchanged."; return 0; }
  local env_backup
  env_backup="$(mktemp)"
  cp "$ENV_FILE" "$env_backup"
  write_env
  if ! docker_compose config >/dev/null || ! docker_compose up -d --force-recreate guacamole; then
    cp "$env_backup" "$ENV_FILE"
    rm -f "$env_backup"
    docker_compose up -d --force-recreate guacamole >/dev/null 2>&1 || true
    say "${red}ERROR:${reset} Port change failed. The previous Avagato configuration was restored."
    return 1
  fi
  rm -f "$env_backup"
  say "${green}SUCCESS:${reset} Guacamole HTTP port changed from $old to $GUACAMOLE_HTTP_PORT."
}

enable_totp(){
  grep -Eq '^[[:space:]]+TOTP_ENABLED:' "$COMPOSE_FILE" && { say "TOTP is already enabled."; return 0; }
  say "${bold}Enable TOTP authentication${reset}"
  say "For a new deployment, first create and verify your intended administrator account."
  say "Recommended: log in as that verified administrator before disabling the built-in guacadmin login."
  say "WARNING: guacadmin can disable its own login; doing that before verifying another administrator can lock you out."
  say "If you intentionally keep guacadmin, change its default password before enabling TOTP."
  say
  confirm "Enable TOTP now?" || return 0
  sed -i '/WEBAPP_CONTEXT: ROOT/a\      TOTP_ENABLED: "true"' "$COMPOSE_FILE"
  if ! docker_compose config >/dev/null || ! docker_compose up -d --force-recreate guacamole; then
    sed -i '/^[[:space:]]*TOTP_ENABLED:/d' "$COMPOSE_FILE"
    docker_compose up -d --force-recreate guacamole >/dev/null 2>&1 || true
    say "${red}ERROR:${reset} TOTP could not be enabled; the previous configuration was restored."
    return 1
  fi
  say "${green}SUCCESS:${reset} TOTP enabled. Applicable users will enroll when they next log in."
  say
  say "${bold}${yellow}IMPORTANT — HARD-REFRESH GUACAMOLE BEFORE CONTINUING${reset}"
  say "Guacamole was recreated to enable TOTP. Any browser tab that was already open may"
  say "still have stale Guacamole files loaded and can show a broken TOTP enrollment screen."
  say
  say "Desktop:"
  say "  - Windows/Linux: press Ctrl+Shift+R (or Ctrl+F5)."
  say "  - macOS: press Command+Shift+R."
  say
  say "Phone/tablet:"
  say "  - Close the Guacamole tab, open a new tab, and load Guacamole again."
  say "  - If the enrollment page still looks wrong, clear this site's browser data/cache"
  say "    and reopen Guacamole."
  say
  say "Do this before scanning the TOTP QR code or attempting enrollment."
}

disable_totp(){
  grep -Eq '^[[:space:]]+TOTP_ENABLED:' "$COMPOSE_FILE" || { say "TOTP is already disabled."; return 0; }
  say "${yellow}Disabling TOTP does not erase existing users' TOTP enrollment data.${reset}"
  confirm "Disable TOTP?" || return 0
  local compose_backup
  compose_backup="$(mktemp)"
  cp "$COMPOSE_FILE" "$compose_backup"
  sed -i '/^[[:space:]]*TOTP_ENABLED:/d' "$COMPOSE_FILE"
  if ! docker_compose config >/dev/null || ! docker_compose up -d --force-recreate guacamole; then
    cp "$compose_backup" "$COMPOSE_FILE"
    rm -f "$compose_backup"
    docker_compose up -d --force-recreate guacamole >/dev/null 2>&1 || true
    say "${red}ERROR:${reset} TOTP could not be disabled; the previous configuration was restored."
    return 1
  fi
  rm -f "$compose_backup"
  say "${green}SUCCESS:${reset} TOTP disabled. Existing enrollment data was left untouched."
  say "${yellow}IMPORTANT:${reset} Hard-refresh any open Guacamole browser tabs before continuing."
}



rdp_drive_enabled(){
  grep -Fq -- '- ./data/drive:/drive' "$COMPOSE_FILE" 2>/dev/null
}

configure_rdp_drive(){
  local compose_backup
  say "${bold}Configure RDP drive sharing${reset}"
  say "Host path:      $AVAGATO_DIR/data/drive"
  say "guacd path:     /drive"
  say

  if rdp_drive_enabled; then
    say "RDP drive sharing is currently enabled."
    confirm "Disable RDP drive sharing?" || return 0
    compose_backup="$(mktemp)"
    cp "$COMPOSE_FILE" "$compose_backup"
    # Remove only Avagato's own guacd drive mapping. Preserve any other
    # user-added guacd volume entries. If the volumes list becomes empty,
    # remove only that now-empty key so the Compose file remains valid.
    awk '
      BEGIN { in_guacd=0; in_volumes=0; kept_volume=0 }
      /^  guacd:$/ { in_guacd=1 }
      in_guacd && /^  [^ ]/ && !/^  guacd:$/ { in_guacd=0; in_volumes=0 }
      in_guacd && /^    volumes:$/ {
        in_volumes=1
        volumes_line=$0
        kept_volume=0
        next
      }
      in_guacd && in_volumes {
        if (/^      - \.\/data\/drive:\/drive$/) next
        if (/^      - /) {
          if (!kept_volume) print volumes_line
          kept_volume=1
          print
          next
        }
        if (!kept_volume && !/^[[:space:]]*$/) {
          # No remaining list entries: intentionally omit the volumes key.
        }
        in_volumes=0
      }
      { print }
      END {
        if (in_guacd && in_volumes && kept_volume == 0) {
          # Empty trailing volumes key is intentionally omitted.
        }
      }
    ' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp"
    mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
    if ! docker_compose config >/dev/null || ! docker_compose up -d --force-recreate guacd; then
      cp "$compose_backup" "$COMPOSE_FILE"
      rm -f "$compose_backup"
      docker_compose up -d --force-recreate guacd >/dev/null 2>&1 || true
      say "${red}ERROR:${reset} RDP drive sharing could not be disabled; the previous configuration was restored."
      return 1
    fi
    rm -f "$compose_backup"
    say "${green}SUCCESS:${reset} RDP drive sharing disabled."
    say
    say "${yellow}IMPORTANT:${reset} Avagato did not delete the host directory or anything stored in it."
    say "The path still exists at:"
    say "  $AVAGATO_DIR/data/drive"
    say "Inspect that directory before manually removing any files or the directory itself."
    return 0
  fi

  say "RDP drive sharing is currently disabled."
  say "Enabling it exposes $AVAGATO_DIR/data/drive to guacd as /drive."
  confirm "Enable RDP drive sharing?" || return 0
  install -d -m 755 "$AVAGATO_DIR/data/drive"
  compose_backup="$(mktemp)"
  cp "$COMPOSE_FILE" "$compose_backup"
  sed -i '/^[[:space:]]*org\.avagato\.component: "guacd"$/a\    volumes:\n      - ./data/drive:/drive' "$COMPOSE_FILE"
  if ! docker_compose config >/dev/null || ! docker_compose up -d --force-recreate guacd; then
    cp "$compose_backup" "$COMPOSE_FILE"
    rm -f "$compose_backup"
    docker_compose up -d --force-recreate guacd >/dev/null 2>&1 || true
    say "${red}ERROR:${reset} RDP drive sharing could not be enabled; the previous configuration was restored."
    return 1
  fi
  rm -f "$compose_backup"
  say "${green}SUCCESS:${reset} RDP drive sharing enabled."
  say "Host path:  $AVAGATO_DIR/data/drive"
  say "guacd path: /drive"
}

install_docker_theme(){
  require_commands curl jar mktemp install unzip
  load_module lib/theme.sh
  say "${bold}Install / switch / update Avagato Theme${reset}"
  say "  1. Dark"
  say "  2. Light"
  local choice variant target other label
  read -r -p "Theme [1-2]: " choice
  case "$choice" in
    1) variant=dark; target="$DOCKER_DARK_THEME_JAR"; other="$DOCKER_LIGHT_THEME_JAR"; label=Dark ;;
    2) variant=light; target="$DOCKER_LIGHT_THEME_JAR"; other="$DOCKER_DARK_THEME_JAR"; label=Light ;;
    *) say "Invalid selection."; return 0 ;;
  esac
  say "Available version: $(theme_variant_version "$variant")"
  confirm "Install / switch to Avagato $label?" || return 0
  warn_other_visual_extensions "$AVAGATO_DIR/guacamole-home/extensions" || { say "Theme installation cancelled."; return 0; }
  [[ ! -f "$target" ]] || theme_jar_is_ours "$target" || die "$(basename "$target") is not an Avagato-managed theme. Refusing to overwrite it."
  [[ ! -f "$other" ]] || theme_jar_is_ours "$other" || die "$(basename "$other") is not an Avagato-managed theme. Refusing to remove it."
  local tmp
  tmp="$(mktemp)"; rm -f "$tmp"; tmp="${tmp}.jar"
  trap 'rm -f "${tmp:-}"' RETURN
  build_theme_variant "$variant" "$tmp"
  install -o root -g root -m 644 "$tmp" "$target"
  rm -f "$other"
  trap - RETURN; rm -f "$tmp"
  docker_compose up -d --force-recreate guacamole
  say "${green}SUCCESS:${reset} Avagato $label installed."
}
remove_docker_theme(){
  load_module lib/theme.sh
  local found=0 jar
  for jar in "$DOCKER_DARK_THEME_JAR" "$DOCKER_LIGHT_THEME_JAR"; do
    [[ -f "$jar" ]] || continue
    found=1
    theme_jar_is_ours "$jar" || die "$(basename "$jar") does not appear to be an Avagato-managed theme. Refusing to remove it."
  done
  [[ "$found" == 1 ]] || { say "Avagato Theme is not installed."; return 0; }
  confirm "Remove the Avagato Theme from this Docker deployment?" || return 0
  rm -f "$DOCKER_DARK_THEME_JAR" "$DOCKER_LIGHT_THEME_JAR"
  docker_compose up -d --force-recreate guacamole
  say "${green}SUCCESS:${reset} Avagato Theme removed."
}
docker_install(){
  require_commands docker openssl sed awk grep install curl df uname
  docker_preflight || return 0
  [[ "$AVAGATO_DOCKER_STACK" == 0 ]] || { docker_menu; return; }
  avagato_banner
  say
  say "${bold}Welcome to Avagato!${reset}"
  say
  say "No existing Apache Guacamole installation was detected."
  say
  say "Avagato can create a new Docker-based installation containing:"
  say "  - Apache Guacamole ${GUAC_VERSION}"
  say "  - guacd ${GUAC_VERSION}"
  say "  - PostgreSQL ${POSTGRES_MAJOR}"
  say "  - Avagato Theme"
  say
  say "The installation will be managed under ${AVAGATO_DIR}."
  say "TOTP authentication can be enabled after the initial administrator account setup is complete."
  say
  confirm "Install a new Avagato Docker deployment?" || return 0
  say
  say "${bold}Docker installation setup${reset}"
  say
  prompt_http_port 8080

  AVAGATO_THEME_ENABLED=1
  say
  say "Avagato Theme applies Avagato branding to Guacamole."
  AVAGATO_THEME_VARIANT=dark
  if confirm "Enable Avagato Theme?"; then
    say "  1. Dark"
    say "  2. Light"
    while true; do
      read -r -p "Theme [1-2]: " theme_choice
      case "$theme_choice" in
        1) AVAGATO_THEME_VARIANT=dark; break ;;
        2) AVAGATO_THEME_VARIANT=light; break ;;
        *) say "Enter 1 for Dark or 2 for Light." ;;
      esac
    done
  else
    AVAGATO_THEME_ENABLED=0
  fi

  prompt_rdp_drive
  say
  say "Installation summary:"
  say "  HTTP port:        $GUACAMOLE_HTTP_PORT"
  say "  Avagato Theme:    $([[ "$AVAGATO_THEME_ENABLED" == 1 ]] && echo "${AVAGATO_THEME_VARIANT^}" || echo Disabled)"
  say "  TOTP:             Disabled for initial bootstrap"
  say "  RDP drive share:  $([[ "$AVAGATO_RDP_DRIVE" == 1 ]] && echo Enabled || echo Disabled)"
  say
  confirm "Create this Avagato Docker deployment?" || return 0

  install -d -m 755 "$AVAGATO_DIR" "$AVAGATO_DIR/init" "$AVAGATO_DIR/data/postgres" "$AVAGATO_DIR/data/drive" "$AVAGATO_DIR/guacamole-home/extensions"
  install -d -o root -g root -m 700 "$AVAGATO_DIR/secrets"
  generate_password > "$AVAGATO_DIR/secrets/postgres_password"
  chmod 644 "$AVAGATO_DIR/secrets/postgres_password"
  write_env
  write_compose
  generate_schema
  if [[ "$AVAGATO_THEME_ENABLED" == 1 ]]; then
    load_module lib/theme.sh
    local theme_tmp
    theme_tmp="$(mktemp)"; rm -f "$theme_tmp"; theme_tmp="${theme_tmp}.jar"
    build_theme_variant "$AVAGATO_THEME_VARIANT" "$theme_tmp"
    local initial_theme_jar="$DOCKER_DARK_THEME_JAR"
    [[ "$AVAGATO_THEME_VARIANT" == light ]] && initial_theme_jar="$DOCKER_LIGHT_THEME_JAR"
    install -o root -g root -m 644 "$theme_tmp" "$initial_theme_jar"
    rm -f "$theme_tmp"
  fi
  docker_compose config >/dev/null || die "Generated Compose configuration failed validation."
  docker_compose up -d

  say "Waiting for Guacamole to become reachable..."
  local tries=0
  until curl -fsS --max-time 3 "http://127.0.0.1:$GUACAMOLE_HTTP_PORT/" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if (( tries >= 30 )); then
      say "${yellow}WARNING:${reset} Containers were started, but Guacamole did not answer HTTP within about 60 seconds."
      say "Run Avagato again and inspect Docker status before continuing account setup."
      return 1
    fi
    sleep 2
  done

  say
  say "${green}SUCCESS:${reset} Avagato Docker deployment created."
  say "Open: http://<this-host>:$GUACAMOLE_HTTP_PORT/"
  say
  say "${bold}Required account bootstrap${reset}"
  say "  Initial username: guacadmin"
  say "  Initial password: guacadmin"
  say
  say "  1. Sign in with the initial Guacamole bootstrap account above."
  say "  2. Recommended: create a separate administrator account."
  say "     Under Permissions, enable all permission checkboxes for this administrator."
  say "  3. Log out of guacadmin and sign in as the new administrator."
  say "  4. Verify that the new account can administer Guacamole (including managing users)."
  say "  5. Only while signed in as that verified administrator, disable login for guacadmin."
  say "     WARNING: Guacamole allows guacadmin to disable its own login. Doing so before"
  say "     verifying another administrator can lock you out of the installation."
  say "     Alternatively, if you intentionally keep guacadmin, change its default password immediately."
  say "  6. Run Avagato again when you are ready to optionally enable TOTP."
}

docker_menu(){
  [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || die "Avagato Docker metadata is incomplete under $AVAGATO_DIR."
  while true; do
    clear || true
    avagato_banner
    say "Docker deployment • Apache Guacamole ${GUAC_VERSION}"
    say
    docker_status
    say
    say "${bold}Manage${reset}"
    say "  1. Enable TOTP authentication"
    say "  2. Disable TOTP authentication"
    say "  3. Install / switch / update Avagato Theme"
    say "  4. Remove Avagato Theme"
    say "  5. Change HTTP port"
    say "  6. Configure RDP drive sharing"
    say "  7. Start / reconcile deployment"
    say
    say "  Q. Quit"
    say
    read -r -p "Selection: " choice
    case "$choice" in
      1) enable_totp; pause;;
      2) disable_totp; pause;;
      3) install_docker_theme; pause;;
      4) remove_docker_theme; pause;;
      5) change_http_port; pause;;
      6) configure_rdp_drive; pause;;
      7) docker_compose up -d; say "${green}SUCCESS:${reset} Deployment reconciled."; pause;;
      q|Q) return 0;;
      *) say "Invalid selection."; sleep 1;;
    esac
  done
}
