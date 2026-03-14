#!/usr/bin/env bash

set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_CYAN=''
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Usage: util/node-drive-free-space.sh [--nodes node1,node2,...]

Reports free space for block-backed Talos mounts on each node.
By default it queries all nodes reachable via the current talosctl context.
EOF
}

require_cmd talosctl
require_cmd jq

declare -a talos_args=()

while (($# > 0)); do
  case "$1" in
    --nodes)
      [[ $# -ge 2 ]] || {
        printf '--nodes requires a comma-separated value\n' >&2
        exit 1
      }
      talos_args+=("-n" "$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mountstatus_json=$(talosctl get mountstatus "${talos_args[@]}" -o json | jq -s '.')
mounts_table=$(talosctl mounts "${talos_args[@]}")

declare -A include_targets=()
declare -A mount_sources=()

while IFS=$'\t' read -r node target source filesystem; do
  key="${node}|${target}"
  include_targets["$key"]=1
  mount_sources["$key"]="$source"
done < <(
  jq -r '
    .[]
    | select(.spec.filesystem != "none")
    | select(.spec.source | startswith("/dev/"))
    | [.node, .spec.target, .spec.source, .spec.filesystem]
    | @tsv
  ' <<<"$mountstatus_json"
)

if [[ ${#include_targets[@]} -eq 0 ]]; then
  printf 'No block-backed Talos mounts found.\n' >&2
  exit 1
fi

rows=()

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  [[ "$line" == NODE* ]] && continue

  read -r -a fields <<<"$line"
  (( ${#fields[@]} >= 7 )) || continue

  node="${fields[0]}"
  mounted_on="${fields[6]}"
  key="${node}|${mounted_on}"

  [[ -n "${include_targets[$key]:-}" ]] || continue

  rows+=("${node}"$'\t'"${mounted_on}"$'\t'"${mount_sources[$key]}"$'\t'"${fields[2]}"$'\t'"${fields[3]}"$'\t'"${fields[4]}"$'\t'"${fields[5]}")
done <<<"$mounts_table"

if [[ ${#rows[@]} -eq 0 ]]; then
  printf 'No matching drive usage rows found in talosctl mounts output.\n' >&2
  exit 1
fi

IFS=$'\n' sorted_rows=($(printf '%s\n' "${rows[@]}" | sort))
unset IFS

printf '%sNode Drive Free Space%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
printf 'Generated: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '%-14s %-24s %-12s %10s %10s %10s %10s\n' 'Node' 'Mount' 'Device' 'Size(GB)' 'Used(GB)' 'Free(GB)' 'Used%'

for row in "${sorted_rows[@]}"; do
  IFS=$'\t' read -r node mounted_on device size used free used_pct <<<"$row"
  printf '%-14s %-24s %-12s %10s %10s %10s %10s\n' \
    "$node" \
    "$mounted_on" \
    "$device" \
    "$size" \
    "$used" \
    "$free" \
    "$used_pct"
done
