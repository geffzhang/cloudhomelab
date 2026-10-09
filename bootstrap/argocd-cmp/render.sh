#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'domain renderer: %s\n' "$*" >&2
  exit 1
}

repo_dir="$PWD"
config_file=""
for _ in 0 1 2 3; do
  if [[ -f "$repo_dir/config/domains.env" ]]; then
    config_file="$repo_dir/config/domains.env"
    break
  fi
  parent_dir="$(dirname "$repo_dir")"
  [[ "$parent_dir" != "$repo_dir" ]] || break
  repo_dir="$parent_dir"
done
[[ -n "$config_file" ]] || fail "cannot find config/domains.env from $PWD"

domain=""
domain_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  case "$line" in
    ''|'#'*) continue ;;
    CLUSTER_DOMAIN=*)
      domain_count=$((domain_count + 1))
      [[ "$domain_count" -eq 1 ]] || fail "CLUSTER_DOMAIN must be defined exactly once"
      domain="${line#CLUSTER_DOMAIN=}"
      ;;
    *)
      fail "unsupported setting in $config_file"
      ;;
  esac
done < "$config_file"

[[ "$domain_count" -eq 1 ]] || fail "CLUSTER_DOMAIN must be defined exactly once in $config_file"
[[ "${#domain}" -le 253 ]] || fail "CLUSTER_DOMAIN exceeds the DNS name length limit"
if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
  fail "CLUSTER_DOMAIN must be a lowercase DNS suffix without scheme, wildcard, port, path, or whitespace"
fi

file_list="$(mktemp)"
trap 'rm -f "$file_list"' EXIT
if ! find . -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | LC_ALL=C sort -z > "$file_list"; then
  fail "failed to enumerate YAML files under $PWD"
fi
[[ -s "$file_list" ]] || fail "no YAML files found under $PWD"

while IFS= read -r -d '' file; do
  sed "s|\${CLUSTER_DOMAIN}|${domain}|g" "$file"
done < "$file_list"
