#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../bootstrap/k3s-registry.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"
export MOCK_UNITS="$TEST_ROOT/units"
export MOCK_CALLS="$TEST_ROOT/systemctl-calls"
export MOCK_RESTART_STATUS=0
: > "$MOCK_UNITS"
: > "$MOCK_CALLS"

cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_CALLS"
case "$1" in
  cat)
    grep -Fxq "$2" "$MOCK_UNITS"
    ;;
  restart)
    exit "$MOCK_RESTART_STATUS"
    ;;
  *)
    echo "unexpected systemctl call: $*" >&2
    exit 2
    ;;
esac
MOCK
chmod +x "$MOCK_BIN/systemctl"
export PATH="$MOCK_BIN:$PATH"

CONFIG="$TEST_ROOT/etc/rancher/k3s/registries.yaml"
EXPECTED_CONFIG='mirrors:
  docker.io:
    endpoint:
      - "https://mirror.ccs.tencentyun.com"'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

reset_mocks() {
  : > "$MOCK_UNITS"
  : > "$MOCK_CALLS"
  MOCK_RESTART_STATUS=0
}

reset_mocks
configure_k3s_registry_mirror "$CONFIG" false
assert_equal "$(cat "$CONFIG")" "$EXPECTED_CONFIG"
assert_equal "$(cat "$MOCK_CALLS")" ""

reset_mocks
printf '%s\n' "$EXPECTED_CONFIG" > "$CONFIG"
BEFORE="$(cat "$CONFIG")"
configure_k3s_registry_mirror "$CONFIG" true
assert_equal "$(cat "$CONFIG")" "$BEFORE"
assert_equal "$(cat "$MOCK_CALLS")" ""

reset_mocks
printf 'mirrors:\n  docker.io:\n    endpoint:\n      - "https://other.example"\n' > "$CONFIG"
BEFORE="$(cat "$CONFIG")"
if configure_k3s_registry_mirror "$CONFIG" true 2>"$TEST_ROOT/error"; then
  fail "incompatible existing config unexpectedly succeeded"
fi
assert_equal "$(cat "$CONFIG")" "$BEFORE"
grep -q 'manually merge' "$TEST_ROOT/error" || fail "missing manual-merge guidance"
assert_equal "$(cat "$MOCK_CALLS")" ""

reset_mocks
rm -f "$CONFIG"
printf '%s\n' k3s.service > "$MOCK_UNITS"
configure_k3s_registry_mirror "$CONFIG" true
assert_equal "$(tail -n 1 "$MOCK_CALLS")" "restart k3s.service"

reset_mocks
rm -f "$CONFIG"
printf '%s\n' k3s-agent.service > "$MOCK_UNITS"
configure_k3s_registry_mirror "$CONFIG" true
assert_equal "$(tail -n 1 "$MOCK_CALLS")" "restart k3s-agent.service"

reset_mocks
rm -f "$CONFIG"
if configure_k3s_registry_mirror "$CONFIG" true 2>"$TEST_ROOT/error"; then
  fail "missing systemd unit unexpectedly succeeded"
fi
[[ ! -e "$CONFIG" ]] || fail "config was created despite missing systemd unit"
grep -q 'neither k3s.service nor k3s-agent.service' "$TEST_ROOT/error" || fail "missing unavailable-unit guidance"

reset_mocks
rm -f "$CONFIG"
printf '%s\n' k3s.service > "$MOCK_UNITS"
MOCK_RESTART_STATUS=1
if configure_k3s_registry_mirror "$CONFIG" true 2>"$TEST_ROOT/error"; then
  fail "failed service restart unexpectedly succeeded"
fi
grep -q 'systemctl restart k3s.service' "$TEST_ROOT/error" || fail "missing restart recovery command"

echo "PASS: Tencent K3s registry mirror scenarios"
