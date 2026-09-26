#!/usr/bin/env bash
# Environment discovery. Detection is intentionally non-destructive.

detect_native_community_scripts(){
  [[ -d /opt/apache-guacamole/tomcat9 ]] &&
  [[ -d /etc/guacamole ]] &&
  [[ -f /opt/apache-guacamole/tomcat9/webapps/guacamole.war ]]
}

# Broader conflict detection used before creating a new Docker deployment.
# This intentionally catches incomplete/moved native installations which are
# not safe for Avagato to manage as a supported native layout.
detect_native_guacamole_evidence(){
  [[ -d /etc/guacamole ]] && return 0
  [[ -f /opt/apache-guacamole/tomcat9/webapps/guacamole.war ]] && return 0
  [[ -f /var/lib/tomcat9/webapps/guacamole.war ]] && return 0
  [[ -f /var/lib/tomcat10/webapps/guacamole.war ]] && return 0
  [[ -f /var/lib/tomcat10/webapps/guacamole/WEB-INF/web.xml ]] && return 0
  [[ -f /var/lib/tomcat9/webapps/guacamole/WEB-INF/web.xml ]] && return 0
  if command -v systemctl >/dev/null 2>&1; then
    local unit
    for unit in tomcat tomcat9 tomcat10; do
      if systemctl cat "$unit" >/dev/null 2>&1 &&
         systemctl cat "$unit" 2>/dev/null | grep -Eqi 'guacamole|apache-guacamole'; then
        return 0
      fi
    done
  fi
  return 1
}

detect_docker_engine(){ command -v docker >/dev/null 2>&1; }
detect_docker_compose(){ docker compose version >/dev/null 2>&1; }

# Detect the Guacamole web application by configured container image, not by
# container name. guacd alone does not count as a Guacamole installation.
detect_guacamole_docker(){
  docker ps -a --format '{{.Image}}' 2>/dev/null |
    grep -Eq '(^|/)(guacamole/)?guacamole(:|@|$)'
}

# Avagato ownership is explicit. New stacks carry the managed label; the
# compose-file check retains recognition of development stacks created before
# that label existed.
detect_avagato_docker(){
  docker ps -a --filter 'label=org.avagato.managed=true' --format '{{.ID}}' 2>/dev/null |
    grep -q . && return 0
  [[ -f /opt/avagato/docker-compose.yaml ]] && detect_guacamole_docker
}

detect_environment(){
  AVAGATO_NATIVE=0 AVAGATO_NATIVE_EVIDENCE=0 AVAGATO_DOCKER=0 AVAGATO_COMPOSE=0 AVAGATO_GUAC_DOCKER=0 AVAGATO_DOCKER_STACK=0
  if detect_native_community_scripts; then AVAGATO_NATIVE=1; fi
  if detect_native_guacamole_evidence; then AVAGATO_NATIVE_EVIDENCE=1; fi
  if detect_docker_engine; then AVAGATO_DOCKER=1; fi
  if [[ "$AVAGATO_DOCKER" == 1 ]] && detect_docker_compose; then AVAGATO_COMPOSE=1; fi
  if [[ "$AVAGATO_DOCKER" == 1 ]] && detect_guacamole_docker; then AVAGATO_GUAC_DOCKER=1; fi
  if [[ "$AVAGATO_DOCKER" == 1 ]] && detect_avagato_docker; then AVAGATO_DOCKER_STACK=1; fi
}
