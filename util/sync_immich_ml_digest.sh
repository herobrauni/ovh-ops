#!/usr/bin/env bash
#
# Keep the immich-machine-learning image pin in lockstep with immich-server.
#
# Background: ghcr.io/immich-app/immich-machine-learning publishes a build per
# PR and per backend variant (>80,000 tags, still paginating after 80 pages),
# so Renovate's docker datasource never reaches the release tags and reports
# "Failed to look up docker package ...: no-result" - that image is invisible
# to Renovate and would silently freeze while immich-server moves on.
#
# immich-server *is* tracked, so a Renovate postUpgradeTask runs this script
# whenever the server image is upgraded (see the immich-server rule in
# .renovaterc.json5). It reads the new server tag out of the HelmRelease,
# resolves the matching machine-learning digest from the registry, and writes
# "<tag>@sha256:<digest>" into the ML pin, so both containers always ship the
# same release.
#
# Usage:
#   sync_immich_ml_digest.sh            # rewrite the ML pin in place
#   sync_immich_ml_digest.sh --check    # exit 1 if out of sync, never write
#   sync_immich_ml_digest.sh --tag v3.5.0 --file /tmp/hr.yaml
#
# Only bash + curl are required (both present in the Renovate container).
#
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helmrelease="${repo_root}/kubernetes/apps/selfhosted/immich/app/helmrelease.yaml"
server_image="ghcr.io/immich-app/immich-server"
ml_image="ghcr.io/immich-app/immich-machine-learning"
server_tag=""
mode="write"

while (($# > 0)); do
    case "$1" in
        --file)
            helmrelease="$2"
            shift 2
            ;;
        --tag)
            server_tag="$2"
            shift 2
            ;;
        --check)
            mode="check"
            shift
            ;;
        -h | --help)
            sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

[[ -f "$helmrelease" ]] || {
    echo "no such file: $helmrelease" >&2
    exit 2
}

# Print the "tag:" value that follows "repository: <image>".
tag_for_image() {
    local image="$1" line found=0
    while IFS= read -r line; do
        if ((found == 0)); then
            [[ $line =~ repository:[[:space:]]*${image}[[:space:]]*$ ]] && found=1
            continue
        fi
        if [[ $line =~ ^[[:space:]]*tag:[[:space:]]*([^[:space:]]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$helmrelease"
    return 1
}

# Resolve the manifest digest of <image>:<tag> straight from the registry.
registry_digest() {
    local image="$1" tag="$2" path body line digest=""
    path="${image#ghcr.io/}"

    body=$(curl -fsS --retry 3 --retry-delay 2 \
        "https://ghcr.io/token?scope=repository:${path}:pull&service=ghcr.io") || return 1
    [[ $body =~ \"token\":\"([^\"]*)\" ]] || {
        echo "no pull token for ${path}" >&2
        return 1
    }
    local token="${BASH_REMATCH[1]}"

    # GET (GHCR does not answer HEAD reliably) and keep only the headers.
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ ${line,,} == docker-content-digest:* ]] || continue
        digest="${line#*: }"
        break
    done < <(curl -fsS --retry 3 --retry-delay 2 -o /dev/null -D - \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
        "https://ghcr.io/v2/${path}/manifests/${tag}")

    [[ -n $digest ]] || {
        echo "no digest returned for ${image}:${tag}" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

if ! command -v curl >/dev/null 2>&1; then
    echo "warning: curl is not available; leaving the immich-machine-learning pin as is" >&2
    exit 0
fi

if [[ -z $server_tag ]]; then
    server_tag=$(tag_for_image "$server_image") || {
        echo "could not find the ${server_image} tag in ${helmrelease}" >&2
        exit 1
    }
fi
server_tag="${server_tag%%@*}"
current_tag=$(tag_for_image "$ml_image" || true)

if digest=$(registry_digest "$ml_image" "$server_tag"); then
    desired_tag="${server_tag}@${digest}"
else
    # A registry hiccup must not block the immich-server update itself; leave
    # the ML pin untouched and let the next Renovate run try again.
    echo "warning: could not resolve ${ml_image}:${server_tag}; leaving the pin as is" >&2
    exit 0
fi

if [[ ${current_tag:-} == "$desired_tag" ]]; then
    echo "immich-machine-learning already pinned to ${desired_tag}"
    exit 0
fi

if [[ $mode == check ]]; then
    echo "immich-machine-learning is ${current_tag:-unknown} but immich-server is ${server_tag}" >&2
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
found=0
while IFS= read -r line || [[ -n $line ]]; do
    if ((found == 0)) && [[ $line =~ repository:[[:space:]]*${ml_image}[[:space:]]*$ ]]; then
        found=1
        printf '%s\n' "$line"
        continue
    fi
    if ((found == 1)) && [[ $line =~ ^([[:space:]]*tag:[[:space:]]*).*$ ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "$desired_tag"
        found=2
        continue
    fi
    printf '%s\n' "$line"
done <"$helmrelease" >"$tmp"

if ((found != 2)); then
    echo "could not rewrite the ${ml_image} tag in ${helmrelease}" >&2
    exit 1
fi

mv "$tmp" "$helmrelease"
trap - EXIT
echo "immich-machine-learning: ${current_tag:-unknown} -> ${desired_tag}"
