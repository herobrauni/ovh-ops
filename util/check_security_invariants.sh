#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

failures=0

report_failure() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}

declare -A privileged_allowlist=(
    [kubernetes/apps/media/altmount/app/helmrelease.yaml]=1
    [kubernetes/apps/media/decypharr-sync-helper/app/helmrelease.yaml]=1
    [kubernetes/apps/media/decypharr/app/helmrelease.yaml]=1
    [kubernetes/apps/media/jellyfin/app/helmrelease.yaml]=1
    [kubernetes/apps/media/media-debug/app/helmrelease.yaml]=1
    [kubernetes/apps/media/nzbdav-sync-helper/app/helmrelease.yaml]=1
    [kubernetes/apps/media/plex/app/helmrelease.yaml]=1
    [kubernetes/apps/media/radarr/app/helmrelease.yaml]=1
    [kubernetes/apps/media/radarr4k/app/helmrelease.yaml]=1
    [kubernetes/apps/media/sonarr/app/helmrelease.yaml]=1
    [kubernetes/apps/media/sonarr4k/app/helmrelease.yaml]=1
)

declare -A fuse_allowlist=(
    [kubernetes/apps/media/altmount/app/helmrelease.yaml]=1
    [kubernetes/apps/media/decypharr-sync-helper/app/helmrelease.yaml]=1
    [kubernetes/apps/media/decypharr/app/helmrelease.yaml]=1
    [kubernetes/apps/media/jellyfin/app/helmrelease.yaml]=1
    [kubernetes/apps/media/media-debug/app/helmrelease.yaml]=1
    [kubernetes/apps/media/nzbdav-sync-helper/app/helmrelease.yaml]=1
    [kubernetes/apps/media/plex/app/helmrelease.yaml]=1
    [kubernetes/apps/media/radarr/app/helmrelease.yaml]=1
    [kubernetes/apps/media/radarr4k/app/helmrelease.yaml]=1
    [kubernetes/apps/media/sonarr/app/helmrelease.yaml]=1
    [kubernetes/apps/media/sonarr4k/app/helmrelease.yaml]=1
)

declare -A host_network_allowlist=(
    [kubernetes/apps/rook-ceph/ceph-csi-drivers/app/helmrelease.yaml]=1
)

mapfile -d '' yaml_files < <(find kubernetes -type f -name '*.yaml' -print0)

check_allowlist() {
    local expression=$1
    local allowlist_name=$2
    local description=$3
    local file
    local -n allowlist=$allowlist_name

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if [[ -z "${allowlist[$file]+present}" ]]; then
            report_failure "unapproved ${description}: ${file}"
        fi
    done < <(mise exec -- yq eval -r -N "$expression | filename" "${yaml_files[@]}")
}

while IFS=$'\t' read -r file digest; do
    [[ -n "$file" ]] || continue
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        report_failure "OCIRepository is not digest-pinned: ${file}"
    fi
done < <(mise exec -- yq eval -r -N 'select(.kind == "OCIRepository") | filename + "\t" + (.spec.ref.digest // "missing")' "${yaml_files[@]}")

while IFS=$'\t' read -r file image; do
    [[ -n "$file" ]] || continue
    report_failure "mutable explicit image in ${file}: ${image}"
done < <(mise exec -- yq eval -r -N '
    .. | select(tag == "!!map") |
    select(has("repository") and has("tag")) |
    select(
        (((.tag | tostring) | contains("@sha256:")) == false) and
        (((.digest // "") | test("^sha256:[0-9a-f]{64}$")) == false)
    ) |
    filename + "\t" + ((.repository | tostring) + ":" + (.tag | tostring))
' "${yaml_files[@]}")

while IFS=$'\t' read -r file image; do
    [[ -n "$file" ]] || continue
    report_failure "mutable scalar image reference in ${file}: ${image}"
done < <(mise exec -- yq eval -r -N '
    .. | select(tag == "!!map") | to_entries[] |
    select(.key == "image" or .key == "imageName") |
    select(.value | tag == "!!str") |
    select((.value | contains("@sha256:")) == false) |
    filename + "\t" + .value
' "${yaml_files[@]}")

check_allowlist '.. | select(tag == "!!map" and .privileged == true)' privileged_allowlist "privileged container"
check_allowlist '.. | select(tag == "!!str" and . == "/dev/fuse")' fuse_allowlist "FUSE host device"
check_allowlist '.. | select(tag == "!!map" and .hostNetwork == true)' host_network_allowlist "host networking"

if ((failures > 0)); then
    echo "Security invariant check failed with ${failures} issue(s)." >&2
    exit 1
fi

echo "Security invariants passed."
