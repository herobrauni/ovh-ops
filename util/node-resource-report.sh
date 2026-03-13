#!/usr/bin/env bash

set -euo pipefail

BAR_WIDTH=20

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
  C_CYAN=''
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

percent() {
  awk -v used="$1" -v total="$2" 'BEGIN { if (total == 0) printf "0.0"; else printf "%.1f", (used / total) * 100 }'
}

format_bytes() {
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B --format='%.1f' "$1"
  else
    awk -v bytes="$1" '
      BEGIN {
        split("B KiB MiB GiB TiB PiB", units, " ")
        value = bytes + 0
        idx = 1
        while (value >= 1024 && idx < 6) {
          value /= 1024
          idx++
        }
        printf "%.1f%s", value, units[idx]
      }
    '
  fi
}

format_cpu() {
  printf '%sm' "$1"
}

repeat_char() {
  local count="$1"
  local char="$2"
  local out=''

  while (( count > 0 )); do
    out+="$char"
    ((count--))
  done

  printf '%s' "$out"
}

render_bar() {
  local pct="$1"
  local filled empty

  filled=$(awk -v pct="$pct" -v width="$BAR_WIDTH" 'BEGIN {
    n = int(((pct > 100 ? 100 : pct) / 100) * width + 0.5)
    if (n < 0) n = 0
    print n
  }')
  empty=$((BAR_WIDTH - filled))

  printf '[%s%s] %5s%%' "$(repeat_char "$filled" '#')" "$(repeat_char "$empty" '-')" "$pct"
}

level_color() {
  local pct="$1"

  awk -v pct="$pct" 'BEGIN {
    if (pct >= 90) print "red"
    else if (pct >= 70) print "yellow"
    else print "green"
  }'
}

apply_color() {
  local text="$1"
  local level="$2"

  case "$level" in
    red) printf '%s%s%s' "$C_RED" "$text" "$C_RESET" ;;
    yellow) printf '%s%s%s' "$C_YELLOW" "$text" "$C_RESET" ;;
    *) printf '%s%s%s' "$C_GREEN" "$text" "$C_RESET" ;;
  esac
}

print_metric_line() {
  local label="$1"
  local used="$2"
  local total="$3"
  local kind="$4"
  local pct value

  pct=$(percent "$used" "$total")

  if [[ "$kind" == "cpu" ]]; then
    value="$(format_cpu "$used") / $(format_cpu "$total")"
  else
    value="$(format_bytes "$used") / $(format_bytes "$total")"
  fi

  printf '  %-12s %s  %s\n' \
    "$label" \
    "$(apply_color "$(render_bar "$pct")" "$(level_color "$pct")")" \
    "$value"
}

print_free_line() {
  local label="$1"
  local free="$2"
  local total="$3"
  local kind="$4"
  local pct value

  pct=$(percent "$free" "$total")

  if [[ "$kind" == "cpu" ]]; then
    value="$(format_cpu "$free") / $(format_cpu "$total")"
  else
    value="$(format_bytes "$free") / $(format_bytes "$total")"
  fi

  printf '  %-12s %s  %s\n' \
    "$label" \
    "$(apply_color "$(render_bar "$pct")" "green")" \
    "$value"
}

require_cmd kubectl
require_cmd jq

if ! kubectl get nodes >/dev/null 2>&1; then
  printf 'kubectl cannot reach the cluster or your context is not authorized.\n' >&2
  exit 1
fi

if ! kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null 2>&1; then
  printf 'The metrics API is unavailable. Make sure metrics-server is installed and healthy.\n' >&2
  exit 1
fi

nodes_json=$(kubectl get nodes -o json)
pods_json=$(kubectl get pods -A -o json)
metrics_json=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes)
current_context=$(kubectl config current-context 2>/dev/null || printf 'unknown')

declare -A alloc_cpu_m=()
declare -A alloc_mem_b=()
declare -A req_cpu_m=()
declare -A req_mem_b=()
declare -A used_cpu_m=()
declare -A used_mem_b=()

mapfile -t node_rows < <(
  jq -r '
    def cpu_to_m:
      if . == null or . == "" then 0
      elif endswith("n") then ((.[0:-1] | tonumber) / 1000000)
      elif endswith("u") then ((.[0:-1] | tonumber) / 1000)
      elif endswith("m") then (.[0:-1] | tonumber)
      else ((tonumber) * 1000)
      end;
    def mem_to_b:
      if . == null or . == "" then 0
      elif endswith("Ki") then ((.[0:-2] | tonumber) * 1024)
      elif endswith("Mi") then ((.[0:-2] | tonumber) * 1048576)
      elif endswith("Gi") then ((.[0:-2] | tonumber) * 1073741824)
      elif endswith("Ti") then ((.[0:-2] | tonumber) * 1099511627776)
      elif endswith("Pi") then ((.[0:-2] | tonumber) * 1125899906842624)
      elif endswith("Ei") then ((.[0:-2] | tonumber) * 1152921504606846976)
      elif endswith("K") then ((.[0:-1] | tonumber) * 1000)
      elif endswith("M") then ((.[0:-1] | tonumber) * 1000000)
      elif endswith("G") then ((.[0:-1] | tonumber) * 1000000000)
      elif endswith("T") then ((.[0:-1] | tonumber) * 1000000000000)
      elif endswith("P") then ((.[0:-1] | tonumber) * 1000000000000000)
      elif endswith("E") then ((.[0:-1] | tonumber) * 1000000000000000000)
      else (tonumber)
      end;
    .items[]
    | [.metadata.name, (.status.allocatable.cpu | cpu_to_m | round), (.status.allocatable.memory | mem_to_b | floor)]
    | @tsv
  ' <<<"$nodes_json"
)

mapfile -t request_rows < <(
  jq -r '
    def cpu_to_m:
      if . == null or . == "" then 0
      elif endswith("n") then ((.[0:-1] | tonumber) / 1000000)
      elif endswith("u") then ((.[0:-1] | tonumber) / 1000)
      elif endswith("m") then (.[0:-1] | tonumber)
      else ((tonumber) * 1000)
      end;
    def mem_to_b:
      if . == null or . == "" then 0
      elif endswith("Ki") then ((.[0:-2] | tonumber) * 1024)
      elif endswith("Mi") then ((.[0:-2] | tonumber) * 1048576)
      elif endswith("Gi") then ((.[0:-2] | tonumber) * 1073741824)
      elif endswith("Ti") then ((.[0:-2] | tonumber) * 1099511627776)
      elif endswith("Pi") then ((.[0:-2] | tonumber) * 1125899906842624)
      elif endswith("Ei") then ((.[0:-2] | tonumber) * 1152921504606846976)
      elif endswith("K") then ((.[0:-1] | tonumber) * 1000)
      elif endswith("M") then ((.[0:-1] | tonumber) * 1000000)
      elif endswith("G") then ((.[0:-1] | tonumber) * 1000000000)
      elif endswith("T") then ((.[0:-1] | tonumber) * 1000000000000)
      elif endswith("P") then ((.[0:-1] | tonumber) * 1000000000000000)
      elif endswith("E") then ((.[0:-1] | tonumber) * 1000000000000000000)
      else (tonumber)
      end;
    [
      .items[]
      | select(.spec.nodeName != null)
      | {
          node: .spec.nodeName,
          cpu: (
            ((([.spec.containers[]?.resources.requests.cpu // "0"] | map(cpu_to_m) | add) // 0)
            + (([.spec.initContainers[]?.resources.requests.cpu // "0"] | map(cpu_to_m) | max) // 0)
            + ((.spec.overhead.cpu // "0") | cpu_to_m))
          ),
          mem: (
            ((([.spec.containers[]?.resources.requests.memory // "0"] | map(mem_to_b) | add) // 0)
            + (([.spec.initContainers[]?.resources.requests.memory // "0"] | map(mem_to_b) | max) // 0)
            + ((.spec.overhead.memory // "0") | mem_to_b))
          )
        }
    ]
    | sort_by(.node)
    | group_by(.node)[]
    | [.[0].node, (map(.cpu) | add | round), (map(.mem) | add | floor)]
    | @tsv
  ' <<<"$pods_json"
)

mapfile -t usage_rows < <(
  jq -r '
    def cpu_to_m:
      if . == null or . == "" then 0
      elif endswith("n") then ((.[0:-1] | tonumber) / 1000000)
      elif endswith("u") then ((.[0:-1] | tonumber) / 1000)
      elif endswith("m") then (.[0:-1] | tonumber)
      else ((tonumber) * 1000)
      end;
    def mem_to_b:
      if . == null or . == "" then 0
      elif endswith("Ki") then ((.[0:-2] | tonumber) * 1024)
      elif endswith("Mi") then ((.[0:-2] | tonumber) * 1048576)
      elif endswith("Gi") then ((.[0:-2] | tonumber) * 1073741824)
      elif endswith("Ti") then ((.[0:-2] | tonumber) * 1099511627776)
      elif endswith("Pi") then ((.[0:-2] | tonumber) * 1125899906842624)
      elif endswith("Ei") then ((.[0:-2] | tonumber) * 1152921504606846976)
      elif endswith("K") then ((.[0:-1] | tonumber) * 1000)
      elif endswith("M") then ((.[0:-1] | tonumber) * 1000000)
      elif endswith("G") then ((.[0:-1] | tonumber) * 1000000000)
      elif endswith("T") then ((.[0:-1] | tonumber) * 1000000000000)
      elif endswith("P") then ((.[0:-1] | tonumber) * 1000000000000000)
      elif endswith("E") then ((.[0:-1] | tonumber) * 1000000000000000000)
      else (tonumber)
      end;
    .items[]
    | [.metadata.name, (.usage.cpu | cpu_to_m | round), (.usage.memory | mem_to_b | floor)]
    | @tsv
  ' <<<"$metrics_json"
)

for row in "${node_rows[@]}"; do
  IFS=$'\t' read -r node cpu mem <<<"$row"
  alloc_cpu_m["$node"]="$cpu"
  alloc_mem_b["$node"]="$mem"
  req_cpu_m["$node"]=0
  req_mem_b["$node"]=0
  used_cpu_m["$node"]=0
  used_mem_b["$node"]=0
done

for row in "${request_rows[@]}"; do
  IFS=$'\t' read -r node cpu mem <<<"$row"
  req_cpu_m["$node"]="$cpu"
  req_mem_b["$node"]="$mem"
done

for row in "${usage_rows[@]}"; do
  IFS=$'\t' read -r node cpu mem <<<"$row"
  used_cpu_m["$node"]="$cpu"
  used_mem_b["$node"]="$mem"
done

total_alloc_cpu=0
total_req_cpu=0
total_used_cpu=0
total_alloc_mem=0
total_req_mem=0
total_used_mem=0

printf '%sNode Resource Report%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
printf '%sContext:%s %s\n' "$C_DIM" "$C_RESET" "$current_context"
printf '%sGenerated:%s %s\n\n' "$C_DIM" "$C_RESET" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

while IFS= read -r node; do
  total_alloc_cpu=$((total_alloc_cpu + alloc_cpu_m["$node"]))
  total_req_cpu=$((total_req_cpu + req_cpu_m["$node"]))
  total_used_cpu=$((total_used_cpu + used_cpu_m["$node"]))
  total_alloc_mem=$((total_alloc_mem + alloc_mem_b["$node"]))
  total_req_mem=$((total_req_mem + req_mem_b["$node"]))
  total_used_mem=$((total_used_mem + used_mem_b["$node"]))
done < <(printf '%s\n' "${!alloc_cpu_m[@]}" | sort)

printf '%sCluster Totals%s\n' "$C_BOLD" "$C_RESET"
print_metric_line 'CPU requested' "$total_req_cpu" "$total_alloc_cpu" cpu
print_metric_line 'CPU used' "$total_used_cpu" "$total_alloc_cpu" cpu
print_free_line 'CPU free' "$((total_alloc_cpu - total_used_cpu))" "$total_alloc_cpu" cpu
print_metric_line 'Mem requested' "$total_req_mem" "$total_alloc_mem" memory
print_metric_line 'Mem used' "$total_used_mem" "$total_alloc_mem" memory
print_free_line 'Mem free' "$((total_alloc_mem - total_used_mem))" "$total_alloc_mem" memory
printf '\n'

printf '%sPer Node%s\n' "$C_BOLD" "$C_RESET"

while IFS= read -r node; do
  node_alloc_cpu=${alloc_cpu_m["$node"]}
  node_req_cpu=${req_cpu_m["$node"]}
  node_used_cpu=${used_cpu_m["$node"]}
  node_alloc_mem=${alloc_mem_b["$node"]}
  node_req_mem=${req_mem_b["$node"]}
  node_used_mem=${used_mem_b["$node"]}

  printf '\n%s%s%s\n' "$C_BOLD" "$node" "$C_RESET"
  print_metric_line 'CPU request' "$node_req_cpu" "$node_alloc_cpu" cpu
  print_metric_line 'CPU used' "$node_used_cpu" "$node_alloc_cpu" cpu
  print_free_line 'CPU free' "$((node_alloc_cpu - node_used_cpu))" "$node_alloc_cpu" cpu
  print_metric_line 'Mem request' "$node_req_mem" "$node_alloc_mem" memory
  print_metric_line 'Mem used' "$node_used_mem" "$node_alloc_mem" memory
  print_free_line 'Mem free' "$((node_alloc_mem - node_used_mem))" "$node_alloc_mem" memory
done < <(printf '%s\n' "${!alloc_cpu_m[@]}" | sort)

printf '\n%sRequested%s comes from pod resource requests. %sUsed%s comes from the Kubernetes metrics API.\n' \
  "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
