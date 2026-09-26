#!/usr/bin/env bash
# Environment discovery. Detection is intentionally non-destructive.

detect_native_community_scripts(){
  [[ -d /opt/apache-guacamole/tomcat9 ]] &&
  [[ -d /etc/guacamole ]] &&
  [[ -f /opt/apache-guacamole/tomcat9/webapps/guacamole.war ]]
}

detect_docker_engine(){ command -v docker >/dev/null 2>&1; }
detect_docker_compose(){ docker compose version >/dev/null 2>&1; }
detect_avagato_docker(){ [[ -f /opt/avagato/compose.yaml ]]; }

detect_environment(){
  AVAGATO_NATIVE=0 AVAGATO_DOCKER=0 AVAGATO_COMPOSE=0 AVAGATO_DOCKER_STACK=0
  if detect_native_community_scripts; then AVAGATO_NATIVE=1; fi
  if detect_docker_engine; then AVAGATO_DOCKER=1; fi
  if [[ "$AVAGATO_DOCKER" == 1 ]] && detect_docker_compose; then AVAGATO_COMPOSE=1; fi
  if detect_avagato_docker; then AVAGATO_DOCKER_STACK=1; fi
}
