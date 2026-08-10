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

check_allowlist() {
    local pattern=$1
    local allowlist_name=$2
    local description=$3
    local file
    local -n allowlist=$allowlist_name

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if [[ -z "${allowlist[$file]+present}" ]]; then
            report_failure "unapproved ${description}: ${file}"
        fi
    done < <(rg -l "$pattern" kubernetes || true)
}

while IFS= read -r file; do
    digest=$(mise exec -- yq eval -r '.spec.ref.digest // ""' "$file")
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        report_failure "OCIRepository is not digest-pinned: ${file}"
    fi
done < <(rg -l '^kind: OCIRepository$' kubernetes)

while IFS= read -r file; do
    bad_images=$(mise exec -- yq eval -r '
        .. | select(tag == "!!map") |
        select(has("repository") and has("tag")) |
        select(
            (((.tag | tostring) | contains("@sha256:")) == false) and
            (((.digest // "") | test("^sha256:[0-9a-f]{64}$")) == false)
        ) |
        (.repository | tostring) + ":" + (.tag | tostring)
    ' "$file")
    if [[ -n "$bad_images" ]]; then
        report_failure "HelmRelease has mutable explicit image(s) in ${file}: ${bad_images//$'\n'/, }"
    fi
done < <(rg --files kubernetes -g 'helmrelease.yaml')

while IFS= read -r finding; do
    [[ -n "$finding" ]] || continue
    report_failure "mutable scalar image reference: ${finding}"
done < <(rg --pcre2 -n '^\s+(?:image|imageName):\s+(?!&)(?!.*@sha256:)\S+' kubernetes || true)

check_allowlist '^\s+privileged:\s+true' privileged_allowlist "privileged container"
check_allowlist 'hostPath:\s+/dev/fuse' fuse_allowlist "FUSE host device"
check_allowlist '^\s+hostNetwork:\s+true' host_network_allowlist "host networking"

if ((failures > 0)); then
    echo "Security invariant check failed with ${failures} issue(s)." >&2
    exit 1
fi

echo "Security invariants passed."
