#!/usr/bin/env bash

configure_argocd_domain_cmp() {
  local cmp_dir="$1"
  local repo_server_image
  local patch

  [[ -f "$cmp_dir/plugin.yaml" ]] || {
    echo "CMP plugin config not found: $cmp_dir/plugin.yaml" >&2
    return 1
  }
  [[ -f "$cmp_dir/render.sh" ]] || {
    echo "CMP renderer not found: $cmp_dir/render.sh" >&2
    return 1
  }

  if ! $KUBECTL -n argocd create configmap homelab-domain-cmp \
    --from-file=plugin.yaml="$cmp_dir/plugin.yaml" \
    --from-file=render.sh="$cmp_dir/render.sh" \
    --dry-run=client -o yaml |
    $KUBECTL -n argocd apply --server-side -f -; then
    echo "failed to apply Argo CD domain CMP ConfigMap" >&2
    return 1
  fi

  repo_server_image="$($KUBECTL -n argocd get deployment argocd-repo-server \
    -o 'jsonpath={.spec.template.spec.containers[?(@.name=="argocd-repo-server")].image}')" || {
    echo "failed to read Argo CD repo-server image" >&2
    return 1
  }
  [[ -n "$repo_server_image" ]] || {
    echo "Argo CD repo-server image is empty" >&2
    return 1
  }

  patch="$(cat <<EOF | tr -d '[:space:]'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "homelab-domain-cmp",
          "image": "$repo_server_image",
          "command": ["/var/run/argocd/argocd-cmp-server"],
          "securityContext": {"runAsNonRoot": true, "runAsUser": 999},
          "resources": {
            "requests": {"cpu": "10m", "memory": "32Mi"},
            "limits": {"cpu": "100m", "memory": "128Mi"}
          },
          "volumeMounts": [
            {"name": "var-files", "mountPath": "/var/run/argocd"},
            {"name": "plugins", "mountPath": "/home/argocd/cmp-server/plugins"},
            {
              "name": "homelab-domain-cmp-config",
              "mountPath": "/home/argocd/cmp-server/config/plugin.yaml",
              "subPath": "plugin.yaml"
            },
            {
              "name": "homelab-domain-cmp-config",
              "mountPath": "/home/argocd/cmp-server/config/render.sh",
              "subPath": "render.sh"
            },
            {"name": "cmp-tmp", "mountPath": "/tmp"}
          ]
        }],
        "volumes": [
          {
            "name": "homelab-domain-cmp-config",
            "configMap": {"name": "homelab-domain-cmp"}
          },
          {"name": "cmp-tmp", "emptyDir": {}}
        ]
      }
    }
  }
}
EOF
)"

  $KUBECTL -n argocd patch deployment argocd-repo-server --type=strategic -p "$patch" || {
    echo "failed to patch Argo CD repo-server for domain CMP" >&2
    return 1
  }
  $KUBECTL -n argocd rollout status deployment/argocd-repo-server --timeout=300s || {
    echo "repo-server rollout failed" >&2
    return 1
  }
}
