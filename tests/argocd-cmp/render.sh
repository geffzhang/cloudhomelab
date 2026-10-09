#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

echo 'PASS: domain rendering'
