#!/usr/bin/env bash
set -Eeuo pipefail

AVAGATO_VERSION="1.1.0"
GUAC_VERSION="1.6.0"
TOMCAT="/opt/apache-guacamole/tomcat9"
GUAC_HOME="/etc/guacamole"
EXT_DIR="$GUAC_HOME/extensions"
THEME_JAR="$EXT_DIR/guacamole-avagato-dark-theme.jar"
LEGACY_THEME_JAR="$EXT_DIR/guacamole-dark-theme.jar"
TOTP_JAR="$EXT_DIR/guacamole-auth-totp-${GUAC_VERSION}.jar"
MYSQL_JAR="$EXT_DIR/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar"
ROOT_DIR="$TOMCAT/webapps/ROOT"
ROOT_ORIGINAL="$TOMCAT/ROOT.original"
DISABLED="$TOMCAT/disabled-webapps"

bold='\033[1m'; red='\033[31m'; green='\033[32m'; yellow='\033[33m'; cyan='\033[36m'; reset='\033[0m'

say(){ printf '%b\n' "$*"; }
die(){ say "${red}ERROR:${reset} $*" >&2; exit 1; }
require_commands(){ local cmd; for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done; }
pause(){ read -r -p "Press Enter to continue..." _; }
confirm(){ local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
restart_tomcat(){ systemctl restart tomcat; }

backup_warning(){
  say "${yellow}${bold}BACKUP FIRST${reset}"
  say "Avagato is designed to preserve the files it changes, but its restore features are not a substitute"
  say "for a full Proxmox backup or snapshot. Take one before modifying this Guacamole installation."
  say
}

check_environment(){
  [[ $EUID -eq 0 ]] || die "Run Avagato as root."
  require_commands systemctl unzip sed head grep
  [[ -d "$TOMCAT" ]] || die "Expected Tomcat directory not found: $TOMCAT"
  [[ -d "$GUAC_HOME" ]] || die "Expected Guacamole configuration directory not found: $GUAC_HOME"
  [[ -f "$TOMCAT/webapps/guacamole.war" ]] || die "Guacamole WAR not found in the expected location."
  systemctl cat tomcat >/dev/null 2>&1 || die "tomcat.service was not found."
  [[ -f "$MYSQL_JAR" ]] || die "Expected Guacamole ${GUAC_VERSION} MySQL JDBC authentication extension not found. This Avagato release supports the tested Community Scripts layout only."
  INSTALLED_GUAC_VERSION="$(unzip -p "$TOMCAT/webapps/guacamole.war" META-INF/maven/org.apache.guacamole/guacamole/pom.properties 2>/dev/null | sed -n 's/^version=//p' | head -n1)"
  [[ -n "$INSTALLED_GUAC_VERSION" ]] || die "Unable to determine the installed Apache Guacamole version from guacamole.war."
  [[ "$INSTALLED_GUAC_VERSION" == "$GUAC_VERSION" ]] || die "Unsupported Apache Guacamole version: detected ${INSTALLED_GUAC_VERSION}; this release supports ${GUAC_VERSION} only."
}

root_is_ours(){
  [[ -f "$ROOT_DIR/index.jsp" ]] && grep -Fq 'response.sendRedirect(request.getContextPath() + "/guacamole/")' "$ROOT_DIR/index.jsp"
}

status(){
  local root="Not installed" stock="Enabled" totp="Not installed" theme="Not installed"
  root_is_ours && root="Installed"
  [[ -d "$DISABLED" ]] && stock="Disabled (recommended)"
  [[ -f "$TOTP_JAR" ]] && totp="Installed"
  [[ -f "$THEME_JAR" ]] && theme="Installed"
  [[ -f "$LEGACY_THEME_JAR" && ! -f "$THEME_JAR" ]] && theme="Legacy development filename"
  say "${bold}Current status${reset}"
  printf '  %-31s %s\n' 'Tomcat root redirect' "$root"
  printf '  %-31s %s\n' 'Tomcat stock applications' "$stock"
  printf '  %-31s %s\n' 'TOTP extension' "$totp"
  printf '  %-31s %s\n' 'Avagato Theme' "$theme"
  printf '  %-31s %s\n' 'Guacamole detected' "$INSTALLED_GUAC_VERSION"
  printf '  %-31s %s\n' 'Guacamole supported' "$GUAC_VERSION"
}

install_tomcat_cleanup(){
  require_commands install
  say "${bold}Tomcat cleanup and root redirect${reset}"
  say "This preserves the original Tomcat ROOT application and moves docs, examples, manager, and"
  say "host-manager outside webapps. / will redirect to Guacamole; Guacamole remains at /guacamole/."
  say
  say "${green}${bold}RECOMMENDED FOR THIS NATIVE INSTALLATION${reset}"
  say "These stock Tomcat applications are not required by Guacamole. Disabling the unused applications"
  say "reduces exposed endpoints, and Avagato preserves them so they can be restored later."
  say
  backup_warning
  confirm "Continue?" || return 0

  if [[ -e "$ROOT_ORIGINAL" ]] && ! root_is_ours; then
    die "$ROOT_ORIGINAL already exists but the live ROOT does not appear to be Avagato's redirect. Refusing to overwrite anything."
  fi

  if ! root_is_ours; then
    [[ -d "$ROOT_DIR" ]] || die "Original Tomcat ROOT application is missing."
    [[ ! -e "$ROOT_ORIGINAL" ]] || die "$ROOT_ORIGINAL already exists. Refusing to overwrite it."
  fi

  local app
  for app in docs examples manager host-manager; do
    if [[ -e "$TOMCAT/webapps/$app" && -e "$DISABLED/$app" ]]; then
      die "Both live and disabled copies of $app exist. Refusing to modify Tomcat."
    fi
  done

  if ! root_is_ours; then
    mv "$ROOT_DIR" "$ROOT_ORIGINAL"
    install -d -o tomcat -g tomcat -m 755 "$ROOT_DIR"
    printf '%s\n' '<%@ page language="java" %>' '<% response.sendRedirect(request.getContextPath() + "/guacamole/"); %>' > "$ROOT_DIR/index.jsp"
    chown tomcat:tomcat "$ROOT_DIR/index.jsp"
    chmod 644 "$ROOT_DIR/index.jsp"
  fi

  install -d -m 755 "$DISABLED"
  for app in docs examples manager host-manager; do
    if [[ -d "$TOMCAT/webapps/$app" ]]; then
      mv "$TOMCAT/webapps/$app" "$DISABLED/$app"
    fi
  done
  restart_tomcat
  say "${green}SUCCESS:${reset} Tomcat cleanup/root redirect is installed."
}

restore_tomcat(){
  say "${bold}Restore stock Tomcat applications/root${reset}"
  backup_warning
  confirm "Restore the Tomcat files preserved by Avagato?" || return 0
  root_is_ours || die "The current ROOT application does not match Avagato's redirect. Refusing to remove it."
  [[ -d "$ROOT_ORIGINAL" ]] || die "Preserved original ROOT application not found."
  rm -rf "$ROOT_DIR"
  mv "$ROOT_ORIGINAL" "$ROOT_DIR"
  local app
  for app in docs examples manager host-manager; do
    if [[ -e "$DISABLED/$app" ]]; then
      [[ ! -e "$TOMCAT/webapps/$app" ]] || die "Cannot restore $app because a live copy already exists."
      mv "$DISABLED/$app" "$TOMCAT/webapps/$app"
    fi
  done
  rmdir "$DISABLED" 2>/dev/null || true
  restart_tomcat
  say "${green}SUCCESS:${reset} Stock Tomcat ROOT and preserved applications restored."
}

install_totp(){
  require_commands curl tar mktemp install
  say "${bold}Install Apache Guacamole TOTP authentication${reset}"
  say "Your existing Guacamole credentials must already work. TOTP becomes an additional authentication"
  say "factor and enrollment occurs when applicable users next log in. Accurate system time is required."
  say
  backup_warning
  confirm "Install the official Apache Guacamole ${GUAC_VERSION} TOTP extension?" || return 0
  [[ ! -f "$TOTP_JAR" ]] || { say "TOTP is already installed."; return 0; }
  local tmp tgz src
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
  tgz="$tmp/totp.tar.gz"
  src="https://archive.apache.org/dist/guacamole/${GUAC_VERSION}/binary/guacamole-auth-totp-${GUAC_VERSION}.tar.gz"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 "$src" -o "$tgz"
  tar -xzf "$tgz" -C "$tmp"
  local found="$tmp/guacamole-auth-totp-${GUAC_VERSION}/guacamole-auth-totp-${GUAC_VERSION}.jar"
  [[ -f "$found" ]] || die "The downloaded Apache archive did not contain the expected TOTP JAR."
  install -o root -g root -m 644 "$found" "$TOTP_JAR"
  restart_tomcat
  trap - RETURN; rm -rf "$tmp"
  say "${green}SUCCESS:${reset} Official Guacamole TOTP extension installed."
}

totp_removal_warning(){
  say "${yellow}${bold}WARNING — TOTP enrollment data will remain${reset}"
  say "Removing the extension stops Guacamole from requiring TOTP, but does NOT erase users' existing"
  say "TOTP enrollment data. If TOTP is installed again later, previously enrolled users may be expected"
  say "to use their existing authenticator enrollment. Avagato will not modify the Guacamole database."
  say
  say "If a user later loses the enrolled authenticator, an administrator can clear that user's TOTP"
  say "secret and force re-enrollment. Official Apache documentation:"
  say "https://guacamole.apache.org/doc/gug/totp-auth.html#resetting-totp-data"
  say
}

remove_totp(){
  [[ -f "$TOTP_JAR" ]] || { say "TOTP extension is not installed."; return 0; }
  totp_removal_warning
  backup_warning
  confirm "Remove the TOTP extension only?" || return 0
  rm -f "$TOTP_JAR"
  restart_tomcat
  say "${green}SUCCESS:${reset} TOTP extension removed. Enrollment data was left untouched."
}

theme_jar_is_ours(){
  local jar_path="$1" manifest
  [[ -f "$jar_path" ]] || return 1
  manifest="$(unzip -p "$jar_path" guac-manifest.json 2>/dev/null || true)"
  [[ "$manifest" == *'"guacamoleVersion":"1.6.0"'* ]] &&
  { [[ "$manifest" == *'"name":"Avagato Theme"'* ]] || [[ "$manifest" == *'"name":"Avagato Dark Theme"'* ]]; } &&
  { [[ "$manifest" == *'"namespace":"avagato-dark-theme"'* ]] || [[ "$manifest" == *'"namespace":"dark-theme"'* ]]; }
}

build_theme()(
  local out="$1" work
  work="$(mktemp -d)"
  trap 'rm -rf "${work:-}"' EXIT
  cat > "$work/guac-manifest.json" <<'JSON'
{"guacamoleVersion":"1.6.0","name":"Avagato Theme","namespace":"avagato-dark-theme","css":["dark.css"]}
JSON
  cat > "$work/dark.css" <<'CSS'
/* Avagato Theme - Apache Guacamole 1.6.0 */
html,body,#content,.login-ui{background:#121416!important;color:#e5e7e9!important}.login-ui .login-dialog,.menu,.menu-content,.menu-body,.settings,.notification,.modal{background:#1c1f22!important;color:#e5e7e9!important}.header,.menu-content .header,.transfer-manager .header,#filesystem-menu .header{background:#24282c!important;color:#f1f3f4!important}h1,h2,h3,h4,h5,label,.caption,.field-header,.name,.description,p,span{color:inherit}a{color:#75baff}a:hover{color:#a8d4ff}input,select,textarea{background:#292d31!important;color:#f1f3f4!important;border-color:#4a5056!important}input:focus,select:focus,textarea:focus{background:#30353a!important;border-color:#6b9fc8!important}input:disabled,input[disabled],input[readonly],select:disabled,select[disabled],textarea:disabled,textarea[disabled]{background:#24282c!important;color:#9ca3af!important;border-color:#454b50!important;opacity:1!important}button,.button,input[type=submit]{background:#343a40!important;color:#f1f3f4!important;border-color:#555d64!important}button:hover,.button:hover,input[type=submit]:hover{background:#41484f!important}table,tbody,tr,td,th{color:#e5e7e9}.list-item{color:#e5e7e9!important}.list-item:hover{background:#292e32!important}.page-tabs,.page-tabs .page-list{background:#1c1f22!important;color:#e5e7e9!important}.page-tabs .page-list li a{color:#cfd3d6!important}.page-tabs .page-list li a:hover,.page-tabs .page-list li a.current{color:#fff!important;background:#292e32!important}.menu-section h3{color:#aeb5ba!important}.menu-dropdown,.menu-contents{background:#1c1f22!important;color:#e5e7e9!important}.user-menu .menu-contents,.user-menu .menu-contents li,.user-menu .menu-contents li a,.user-menu .menu-contents li a:visited,.user-menu .menu-contents li a:hover{color:#e5e7e9!important}.user-menu .menu-contents li a:hover{background:#30353a!important}.user-list .list-item,.user-list .list-item a,.user-list .list-item .name,.user-list .list-item .caption,.user-list .user a,.user-list .user a:visited,.user-list .username,.user-list .username a,.user-list td a,.user-list td a:visited{color:#e5e7e9!important}.logged-out-modal guac-modal,.automatic-login-rejected-modal guac-modal{background:#121416!important;color:#e5e7e9!important}.logged-out-modal .notification,.automatic-login-rejected-modal .notification{background:#1c1f22!important;color:#e5e7e9!important}.filter input,.search-field input,input[placeholder="Filter"]{background:#121416!important;color:#e5e7e9!important;border:1px solid #9ca3af!important;border-radius:4px!important}.filter input::placeholder,.search-field input::placeholder,input[placeholder="Filter"]::placeholder{color:#b8bec4!important;opacity:1!important}.filter input:focus,.search-field input:focus,input[placeholder="Filter"]:focus{background:#121416!important;color:#fff!important;border-color:#b9d7eb!important;outline:none!important}.location-chooser div.location{background:#292d31!important;color:#f1f3f4!important;border-color:#4a5056!important;cursor:pointer!important}.location-chooser div.location:hover{background:#30353a!important;border-color:#6b9fc8!important}.location-chooser .dropdown{background:#1c1f22!important;color:#e5e7e9!important;border-color:#4a5056!important}.location-chooser .dropdown .list-item,.location-chooser .dropdown .list-item .name,.location-chooser .dropdown .connection-group,.location-chooser .dropdown .connection-group .name{color:#e5e7e9!important}.location-chooser .dropdown .list-item:hover,.location-chooser .dropdown .list-item:not(.selected) .caption:hover{background:#30353a!important}.location-chooser .dropdown .list-item.selected{background:#343a40!important;color:#fff!important}.settings .connection .name,.settings .connection a,.settings .connection a:visited,.all-connections .connection a,.all-connections .connection a:visited,.all-connections .connection a:hover,.all-connections .connection .name,.recent-connections .connection a,.recent-connections .connection a:visited,.recent-connections .connection a:hover,.recent-connections .connection .name,.recent-connections .connection .caption{color:#e5e7e9!important}.recent-connections .connection:hover,.all-connections .list-item:not(.selected) .caption:hover{background:#30353a!important;color:#fff!important}.recent-connections .connection:hover a,.recent-connections .connection:hover .name,.recent-connections .connection:hover .caption,.all-connections .list-item:not(.selected) .caption:hover,.all-connections .list-item:not(.selected) .caption:hover .name,.all-connections .list-item:not(.selected) .caption:hover a{color:#fff!important}.settings .connection:hover,.settings .list-item:not(.selected) .caption:hover{background:#30353a!important;color:#fff!important}.settings .connection:hover a,.settings .connection:hover .name,.settings .connection:hover .caption,.settings .list-item:not(.selected) .caption:hover,.settings .list-item:not(.selected) .caption:hover .name,.settings .list-item:not(.selected) .caption:hover a{color:#fff!important}.login-ui .login-fields .labeled-field .field-header{color:#b8bec4!important;opacity:1!important}.login-ui .login-fields .labeled-field.empty input{background:transparent!important}.login-ui .login-fields .labeled-field input:focus{background:#30353a!important}.client,.client .display,.viewport{color:initial}hr{border-color:#3b4146!important}
CSS
  (cd "$work" && jar cf "$out" guac-manifest.json dark.css)
)

install_theme(){
  require_commands jar mktemp install
  say "${bold}Install Avagato Theme${reset}"
  backup_warning
  confirm "Install the Avagato theme?" || return 0
  if [[ -f "$THEME_JAR" ]] && ! theme_jar_is_ours "$THEME_JAR"; then
    die "$(basename "$THEME_JAR") exists but does not appear to be an Avagato theme. Refusing to overwrite it."
  fi
  if [[ -f "$LEGACY_THEME_JAR" ]] && ! theme_jar_is_ours "$LEGACY_THEME_JAR"; then
    die "$(basename "$LEGACY_THEME_JAR") exists but does not appear to be the Avagato development theme. Refusing to remove it."
  fi
  local tmp
  tmp="$(mktemp)"; rm -f "$tmp"; tmp="${tmp}.jar"
  trap 'rm -f "${tmp:-}"' RETURN
  build_theme "$tmp"
  install -o root -g root -m 644 "$tmp" "$THEME_JAR"
  [[ -f "$LEGACY_THEME_JAR" ]] && rm -f "$LEGACY_THEME_JAR"
  trap - RETURN; rm -f "$tmp"
  restart_tomcat
  say "${green}SUCCESS:${reset} Avagato Theme installed as $(basename "$THEME_JAR")."
}

remove_theme(){
  [[ -f "$THEME_JAR" || -f "$LEGACY_THEME_JAR" ]] || { say "Avagato Theme is not installed."; return 0; }
  if [[ -f "$THEME_JAR" ]] && ! theme_jar_is_ours "$THEME_JAR"; then
    die "$(basename "$THEME_JAR") does not appear to be an Avagato theme. Refusing to remove it."
  fi
  if [[ -f "$LEGACY_THEME_JAR" ]] && ! theme_jar_is_ours "$LEGACY_THEME_JAR"; then
    die "$(basename "$LEGACY_THEME_JAR") does not appear to be the Avagato development theme. Refusing to remove it."
  fi
  confirm "Remove the Avagato Theme?" || return 0
  rm -f "$THEME_JAR" "$LEGACY_THEME_JAR"
  restart_tomcat
  say "${green}SUCCESS:${reset} Avagato Theme removed."
}

install_all(){ install_tomcat_cleanup; install_totp; install_theme; }
restore_all(){
  [[ -f "$TOTP_JAR" ]] && totp_removal_warning
  backup_warning
  confirm "Restore everything managed by Avagato?" || return 0

  if [[ -f "$THEME_JAR" ]] && ! theme_jar_is_ours "$THEME_JAR"; then
    die "$(basename "$THEME_JAR") does not appear to be an Avagato theme. Refusing to remove it."
  fi
  if [[ -f "$LEGACY_THEME_JAR" ]] && ! theme_jar_is_ours "$LEGACY_THEME_JAR"; then
    die "$(basename "$LEGACY_THEME_JAR") does not appear to be the Avagato development theme. Refusing to remove it."
  fi
  if root_is_ours || [[ -e "$ROOT_ORIGINAL" ]] || [[ -d "$DISABLED" ]]; then
    root_is_ours || die "Tomcat has Avagato-preserved files, but the live ROOT does not match Avagato's redirect. Refusing partial restore."
    [[ -d "$ROOT_ORIGINAL" ]] || die "Preserved original ROOT application not found. Refusing partial restore."
    local app
    for app in docs examples manager host-manager; do
      if [[ -e "$DISABLED/$app" && -e "$TOMCAT/webapps/$app" ]]; then
        die "Cannot restore $app because both preserved and live copies exist. Refusing partial restore."
      fi
    done
  fi

  [[ -f "$THEME_JAR" || -f "$LEGACY_THEME_JAR" ]] && rm -f "$THEME_JAR" "$LEGACY_THEME_JAR"
  [[ -f "$TOTP_JAR" ]] && rm -f "$TOTP_JAR"
  if root_is_ours && [[ -d "$ROOT_ORIGINAL" ]]; then
    rm -rf "$ROOT_DIR"; mv "$ROOT_ORIGINAL" "$ROOT_DIR"
    local app; for app in docs examples manager host-manager; do
      if [[ -e "$DISABLED/$app" ]]; then mv "$DISABLED/$app" "$TOMCAT/webapps/$app"; fi
    done
    rmdir "$DISABLED" 2>/dev/null || true
  fi
  restart_tomcat
  say "${green}SUCCESS:${reset} Avagato-managed extensions removed and preserved Tomcat applications restored. TOTP database enrollment data was not changed."
}

menu(){
  while true; do
    clear || true
    say "${green}${bold}                 .-''''-.${reset}"
    say "${green}${bold}               .'  .--.  '.${reset}"
    say "${green}${bold}              /   (o  o)   \\${reset}"
    say "${green}${bold}             |      /\\      |${reset}"
    say "${green}${bold}              \\    '  '    /${reset}"
    say "${green}${bold}               '.  ----  .'${reset}"
    say "${green}${bold}                 '-.__.-'${reset}"
    say
    say "${bold}                    AVAGATO${reset}"
    say "             A little extra seasoning"
    say "                for Apache Guacamole"
    say
    say "Avagato ${AVAGATO_VERSION}  •  Apache Guacamole ${INSTALLED_GUAC_VERSION}"
    say "Native installation  •  Proxmox VE Community Scripts layout"
    say
    status
    say
    say "${bold}Install / Configure${reset}"
    say "  1. Clean up Tomcat & redirect / → /guacamole/  (recommended)"
    say "  2. Install TOTP authentication"
    say "  3. Install Avagato Theme"
    say "  4. Apply all enhancements"
    say
    say "${bold}Restore${reset}"
    say "  5. Restore stock Tomcat web applications/root"
    say "  6. Remove TOTP extension"
    say "  7. Remove Avagato Theme"
    say "  8. Restore everything managed by Avagato"
    say
    say "  Q. Quit"
    say
    read -r -p "Selection: " choice
    case "$choice" in
      1) install_tomcat_cleanup; pause;; 2) install_totp; pause;; 3) install_theme; pause;; 4) install_all; pause;;
      5) restore_tomcat; pause;; 6) remove_totp; pause;; 7) remove_theme; pause;; 8) restore_all; pause;;
      q|Q) exit 0;; *) say "Invalid selection."; sleep 1;;
    esac
  done
}

check_environment
backup_warning
menu
