#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
RENDERER="$(cd -- "$SCRIPT_DIR/../../bootstrap/argocd-cmp" && pwd)/render.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/repo/config" "$TEST_ROOT/repo/apps/demo"
printf 'CLUSTER_DOMAIN=lab.example.net\n' > "$TEST_ROOT/repo/config/domains.env"
cat > "$TEST_ROOT/repo/apps/demo/ingress.yaml" <<'YAML'
host: argo.${CLUSTER_DOMAIN}
callback: https://argo.${CLUSTER_DOMAIN}/auth/callback
secret: ${ADMIN_PASSWORD}
YAML

OUTPUT="$(cd "$TEST_ROOT/repo/apps/demo" && "$RENDERER")"
grep -Fq 'host: argo.lab.example.net' <<< "$OUTPUT"
grep -Fq 'callback: https://argo.lab.example.net/auth/callback' <<< "$OUTPUT"
grep -Fq 'secret: ${ADMIN_PASSWORD}' <<< "$OUTPUT"
! grep -Fq '${CLUSTER_DOMAIN}' <<< "$OUTPUT"

assert_failure() {
  local case_name="$1"
  local config_content="$2"
  local expected_error="$3"
  local case_root="$TEST_ROOT/$case_name"
  mkdir -p "$case_root/repo/apps/demo"
  if [[ "$case_name" != "missing-config" ]]; then
    mkdir -p "$case_root/repo/config"
    printf '%s' "$config_content" > "$case_root/repo/config/domains.env"
  fi
  printf 'host: argo.${CLUSTER_DOMAIN}\n' > "$case_root/repo/apps/demo/ingress.yaml"

  if (cd "$case_root/repo/apps/demo" && "$RENDERER") > "$case_root/stdout" 2> "$case_root/stderr"; then
    echo "FAIL: $case_name unexpectedly rendered successfully" >&2
    exit 1
  fi
  grep -Fq "$expected_error" "$case_root/stderr" || {
    echo "FAIL: $case_name did not report '$expected_error'" >&2
    cat "$case_root/stderr" >&2
    exit 1
  }
}

assert_failure missing-config '' 'cannot find config/domains.env'
assert_failure missing-domain '' 'CLUSTER_DOMAIN must be defined exactly once'
assert_failure duplicate-domain $'CLUSTER_DOMAIN=one.example.net\nCLUSTER_DOMAIN=two.example.net\n' 'CLUSTER_DOMAIN must be defined exactly once'
assert_failure unknown-key $'OTHER=value\n' 'unsupported setting'
assert_failure empty-domain $'CLUSTER_DOMAIN=\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
assert_failure url-domain $'CLUSTER_DOMAIN=https://example.net\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
assert_failure wildcard-domain $'CLUSTER_DOMAIN=*.example.net\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
assert_failure empty-label $'CLUSTER_DOMAIN=bad..example.net\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
assert_failure path-domain $'CLUSTER_DOMAIN=example.net/path\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
assert_failure whitespace-domain $'CLUSTER_DOMAIN=example .net\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
assert_failure leading-hyphen $'CLUSTER_DOMAIN=-bad.example.net\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
assert_failure trailing-hyphen $'CLUSTER_DOMAIN=bad-.example.net\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
LONG_LABEL="$(printf '%064d' 0 | tr '0' 'a')"
assert_failure overlong-label "CLUSTER_DOMAIN=$LONG_LABEL.example.net"$'\n' 'CLUSTER_DOMAIN must be a lowercase DNS suffix'
VALID_MAX_LABEL="$(printf '%063d' 0 | tr '0' 'a')"
assert_failure overlong-domain "CLUSTER_DOMAIN=$VALID_MAX_LABEL.$VALID_MAX_LABEL.$VALID_MAX_LABEL.$VALID_MAX_LABEL"$'\n' 'exceeds the DNS name length limit'

INTEGRATION_ROOT="$TEST_ROOT/integration"
mkdir -p "$INTEGRATION_ROOT/config" "$INTEGRATION_ROOT/apps" "$INTEGRATION_ROOT/platform"
printf 'CLUSTER_DOMAIN=lab.example.net\n' > "$INTEGRATION_ROOT/config/domains.env"
cp -R "$REPO_ROOT/apps/9router" "$INTEGRATION_ROOT/apps/9router"
cp -R "$REPO_ROOT/apps/keycloak" "$INTEGRATION_ROOT/apps/keycloak"
cp -R "$REPO_ROOT/apps/opensandbox" "$INTEGRATION_ROOT/apps/opensandbox"
cp -R "$REPO_ROOT/platform/config" "$INTEGRATION_ROOT/platform/config"

render_app() {
  local app_dir="$1"
  (cd "$app_dir" && "$RENDERER")
}

NINEROUTER_OUTPUT="$(render_app "$INTEGRATION_ROOT/apps/9router")"
grep -Fq 'host: 9router.lab.example.net' <<< "$NINEROUTER_OUTPUT"
grep -Fqx '    type: Opaque' <<< "$NINEROUTER_OUTPUT"
grep -Fxq 'apiVersion: v1' <<< "$NINEROUTER_OUTPUT"
KEYCLOAK_OUTPUT="$(render_app "$INTEGRATION_ROOT/apps/keycloak")"
grep -Fq 'keycloak.lab.example.net' <<< "$KEYCLOAK_OUTPUT"
grep -Fq 'https://argo.lab.example.net/auth/callback' <<< "$KEYCLOAK_OUTPUT"
grep -Fq '${ADMIN_PASSWORD}' <<< "$KEYCLOAK_OUTPUT"
grep -Fq '${ARGOCD_CLIENT_SECRET}' <<< "$KEYCLOAK_OUTPUT"
OPENSANDBOX_OUTPUT="$(render_app "$INTEGRATION_ROOT/apps/opensandbox")"
grep -Fq 'sandbox.lab.example.net' <<< "$OPENSANDBOX_OUTPUT"
grep -Fq 'gateway.address = "sandbox-gateway.lab.example.net"' <<< "$OPENSANDBOX_OUTPUT"
PLATFORM_CONFIG_OUTPUT="$(render_app "$INTEGRATION_ROOT/platform/config")"
grep -Fq 'host: argo.lab.example.net' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'host: grafana.lab.example.net' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'name: monitoring-grafana' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'secretName: grafana-tls' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'homelab.csharpkit.com/description' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'grafana.lab.example.net.' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'argo.lab.example.net.' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq '9router.lab.example.net.' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'sandbox.lab.example.net.' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -Fq 'keycloak.lab.example.net.' <<< "$PLATFORM_CONFIG_OUTPUT"
grep -A1 '^  ingress:' "$REPO_ROOT/platform/monitoring/values.yaml" | grep -Fq 'enabled: false'
grep -Fq '# *.lab.example.net DNS' <<< "$OPENSANDBOX_OUTPUT"

echo 'PASS: domain rendering'
