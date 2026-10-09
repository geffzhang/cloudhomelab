#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"
export MOCK_CALLS="$TEST_ROOT/calls"
export MOCK_PATCH="$TEST_ROOT/patch"
export MOCK_ROLLOUT_STATUS=0
: > "$MOCK_CALLS"

cat > "$MOCK_BIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_CALLS"
if [[ "$1" == "-n" ]]; then
  shift 2
fi
case "$1" in
  create)
    printf 'apiVersion: v1\nkind: ConfigMap\n'
    ;;
  apply)
    cat >/dev/null
    ;;
  get)
    printf 'quay.io/argoproj/argocd:v-test\n'
    ;;
  patch)
    printf '%s\n' "$*" > "$MOCK_PATCH"
    ;;
  rollout)
    exit "$MOCK_ROLLOUT_STATUS"
    ;;
  *)
    echo "unexpected kubectl call: $*" >&2
    exit 2
    ;;
esac
MOCK
chmod +x "$MOCK_BIN/kubectl"
export PATH="$MOCK_BIN:$PATH"
export KUBECTL=kubectl

source "$REPO_ROOT/bootstrap/argocd-cmp-install.sh"
configure_argocd_domain_cmp "$REPO_ROOT/bootstrap/argocd-cmp"
grep -Fq 'create configmap homelab-domain-cmp' "$MOCK_CALLS"
grep -Fq -- '--from-file=plugin.yaml=' "$MOCK_CALLS"
grep -Fq -- '--from-file=render.sh=' "$MOCK_CALLS"
grep -Fq 'apply --server-side -f -' "$MOCK_CALLS"
grep -Fq '"name":"homelab-domain-cmp"' "$MOCK_PATCH"
grep -Fq '"image":"quay.io/argoproj/argocd:v-test"' "$MOCK_PATCH"
grep -Fq '"runAsUser":999' "$MOCK_PATCH"
grep -Fq '"name":"cmp-tmp"' "$MOCK_PATCH"
EXPECTED_CHECKSUM="$({ cat "$REPO_ROOT/bootstrap/argocd-cmp/plugin.yaml"; printf '\0'; cat "$REPO_ROOT/bootstrap/argocd-cmp/render.sh"; } | sha256sum | awk '{print $1}')"
grep -Fq "\"homelab.csharpkit.com/domain-cmp-checksum\":\"$EXPECTED_CHECKSUM\"" "$MOCK_PATCH"
grep -Fq 'rollout status deployment/argocd-repo-server --timeout=300s' "$MOCK_CALLS"

MOCK_ROLLOUT_STATUS=1
if configure_argocd_domain_cmp "$REPO_ROOT/bootstrap/argocd-cmp" 2>"$TEST_ROOT/rollout-error"; then
  echo 'FAIL: failed repo-server rollout unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'repo-server rollout failed' "$TEST_ROOT/rollout-error"

echo 'PASS: Argo CD domain CMP bootstrap'
