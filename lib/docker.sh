#!/usr/bin/env bash
# Avagato Docker deployment and management for Apache Guacamole 1.6.0.

AVAGATO_DIR="/opt/avagato"
COMPOSE_FILE="$AVAGATO_DIR/compose.yaml"
ENV_FILE="$AVAGATO_DIR/.env"
GUAC_VERSION="1.6.0"
POSTGRES_MAJOR="17"
DOCKER_THEME_JAR="$AVAGATO_DIR/guacamole-home/extensions/guacamole-avagato-dark-theme.jar"

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
  local port="unknown" theme_status="Not installed"
  [[ -f "$ENV_FILE" ]] && port="$(sed -n 's/^GUACAMOLE_HTTP_PORT=//p' "$ENV_FILE" | head -n1)"
  if [[ -f "$DOCKER_THEME_JAR" ]]; then
    load_module lib/theme.sh
    if command -v unzip >/dev/null 2>&1 && theme_jar_is_ours "$DOCKER_THEME_JAR"; then
      theme_status="Installed"
    else
      theme_status="Unknown JAR present"
    fi
  fi
  say "${bold}Current status${reset}"
  printf '  %-25s %s\n' 'Deployment' 'Avagato Docker'
  printf '  %-25s %s\n' 'Guacamole version' "$GUAC_VERSION"
  printf '  %-25s %s\n' 'HTTP port' "$port"
  printf '  %-25s %s\n' 'TOTP' "$(grep -Eq '^[[:space:]]+TOTP_ENABLED:[[:space:]]*"?true"?' "$COMPOSE_FILE" 2>/dev/null && echo Enabled || echo Disabled)"
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
  if ! docker_compose config >/dev/null || ! docker_compose up -d guacamole; then
    cp "$env_backup" "$ENV_FILE"
    rm -f "$env_backup"
    docker_compose up -d guacamole >/dev/null 2>&1 || true
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
  say "Recommended: disable the built-in guacadmin login from that verified administrator account."
  say "If you intentionally keep guacadmin, change its default password before enabling TOTP."
  say
  confirm "Enable TOTP now?" || return 0
  sed -i '/WEBAPP_CONTEXT: ROOT/a\      TOTP_ENABLED: "true"' "$COMPOSE_FILE"
  if ! docker_compose config >/dev/null || ! docker_compose up -d guacamole; then
    sed -i '/^[[:space:]]*TOTP_ENABLED:/d' "$COMPOSE_FILE"
    docker_compose up -d guacamole >/dev/null 2>&1 || true
    say "${red}ERROR:${reset} TOTP could not be enabled; the previous configuration was restored."
    return 1
  fi
  say "${green}SUCCESS:${reset} TOTP enabled. Applicable users will enroll when they next log in."
}

disable_totp(){
  grep -Eq '^[[:space:]]+TOTP_ENABLED:' "$COMPOSE_FILE" || { say "TOTP is already disabled."; return 0; }
  say "${yellow}Disabling TOTP does not erase existing users' TOTP enrollment data.${reset}"
  confirm "Disable TOTP?" || return 0
  local compose_backup
  compose_backup="$(mktemp)"
  cp "$COMPOSE_FILE" "$compose_backup"
  sed -i '/^[[:space:]]*TOTP_ENABLED:/d' "$COMPOSE_FILE"
  if ! docker_compose config >/dev/null || ! docker_compose up -d guacamole; then
    cp "$compose_backup" "$COMPOSE_FILE"
    rm -f "$compose_backup"
    docker_compose up -d guacamole >/dev/null 2>&1 || true
    say "${red}ERROR:${reset} TOTP could not be disabled; the previous configuration was restored."
    return 1
  fi
  rm -f "$compose_backup"
  say "${green}SUCCESS:${reset} TOTP disabled. Existing enrollment data was left untouched."
}


install_docker_theme(){
  require_commands curl jar mktemp install unzip
  load_module lib/theme.sh
  say "${bold}Install / update Avagato Theme${reset}"
  confirm "Install the Avagato theme in this Docker deployment?" || return 0
  local tmp
  tmp="$(mktemp)"; rm -f "$tmp"; tmp="${tmp}.jar"
  trap 'rm -f "${tmp:-}"' RETURN
  build_theme "$tmp"
  install -o root -g root -m 644 "$tmp" "$DOCKER_THEME_JAR"
  trap - RETURN; rm -f "$tmp"
  docker_compose up -d guacamole
  say "${green}SUCCESS:${reset} Avagato Theme installed/updated."
}

remove_docker_theme(){
  [[ -f "$DOCKER_THEME_JAR" ]] || { say "Avagato Theme is not installed."; return 0; }
  load_module lib/theme.sh
  theme_jar_is_ours "$DOCKER_THEME_JAR" || die "The theme JAR does not appear to be Avagato-managed. Refusing to remove it."
  confirm "Remove the Avagato Theme from this Docker deployment?" || return 0
  rm -f "$DOCKER_THEME_JAR"
  docker_compose up -d guacamole
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
  prompt_rdp_drive
  say
  say "Installation summary:"
  say "  HTTP port:        $GUACAMOLE_HTTP_PORT"
  say "  Avagato Theme:    Enabled"
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
  load_module lib/theme.sh
  local theme_tmp
  theme_tmp="$(mktemp)"; rm -f "$theme_tmp"; theme_tmp="${theme_tmp}.jar"
  build_theme "$theme_tmp"
  install -o root -g root -m 644 "$theme_tmp" "$DOCKER_THEME_JAR"
  rm -f "$theme_tmp"
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
  say "${green}SUCCESS:${reset} Avagato Docker deployment created with the Avagato Theme."
  say "Open: http://<this-host>:$GUACAMOLE_HTTP_PORT/"
  say
  say "${bold}Required account bootstrap${reset}"
  say "  1. Sign in with the initial Guacamole bootstrap account."
  say "  2. Recommended: create a separate administrator account with full administrative permissions."
  say "  3. Log out and verify that the new administrator account can administer Guacamole."
  say "  4. From that verified account, disable login for guacadmin."
  say "     Alternatively, if you intend to keep guacadmin, change its default password immediately."
  say "  5. Run Avagato again when you are ready to optionally enable TOTP."
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
    say "  3. Install / update Avagato Theme"
    say "  4. Remove Avagato Theme"
    say "  5. Change HTTP port"
    say "  6. Start / reconcile deployment"
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
      6) docker_compose up -d; say "${green}SUCCESS:${reset} Deployment reconciled."; pause;;
      q|Q) return 0;;
      *) say "Invalid selection."; sleep 1;;
    esac
  done
}
