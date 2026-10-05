#!/usr/bin/env bash

configure_k3s_registry_mirror() {
  local config_file="$1"
  local k3s_installed="$2"
  local service=""

  case "$k3s_installed" in
    true|false) ;;
    *)
      echo "Expected k3s-installed to be true or false; got '$k3s_installed'." >&2
      return 2
      ;;
  esac

  if [[ -e "$config_file" ]]; then
    if awk '
      /^mirrors:[[:space:]]*($|#)/ { in_mirrors = 1; next }
      /^[^[:space:]#]/ { in_mirrors = 0; in_docker = 0 }
      in_mirrors && /^  docker\.io:[[:space:]]*($|#)/ { in_docker = 1; next }
      in_mirrors && /^  [^[:space:]#]/ { in_docker = 0 }
      in_docker && /^[[:space:]]*-[[:space:]]*["\047]?https:\/\/mirror\.ccs\.tencentyun\.com["\047]?[[:space:]]*(#.*)?$/ { found = 1 }
      END { exit !found }
    ' "$config_file"; then
      return 0
    fi

    echo "Existing registry config '$config_file' does not configure https://mirror.ccs.tencentyun.com for docker.io." >&2
    echo "Preserving it unchanged; manually merge the Tencent docker.io mirror, then rerun bootstrap." >&2
    return 1
  fi

  if [[ "$k3s_installed" == true ]]; then
    if systemctl cat k3s.service >/dev/null 2>&1; then
      service="k3s.service"
    elif systemctl cat k3s-agent.service >/dev/null 2>&1; then
      service="k3s-agent.service"
    else
      echo "K3s is installed, but neither k3s.service nor k3s-agent.service exists; cannot apply registry config." >&2
      return 1
    fi
  fi

  install -d -m 0755 "$(dirname -- "$config_file")"
  cat > "$config_file" <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://mirror.ccs.tencentyun.com"
EOF

  if [[ -n "$service" ]] && ! systemctl restart "$service"; then
    echo "Failed to restart $service after creating '$config_file'." >&2
    echo "Apply the registry config manually with: systemctl restart $service" >&2
    return 1
  fi
}
