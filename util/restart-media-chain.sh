#!/bin/bash
# Restarts the Altmount -> rclone sidecar mount chain in the correct order.
#
# Usage: ./util/restart-media-chain.sh [--wait-timeout SECONDS]
#
# Architecture (per-pod rclone-altmount sidecars, no CSI driver):
#   1. Restart Altmount (the WebDAV source all rclone sidecars mount from)
#   2. Restart every consumer deployment — each pod's rclone-altmount
#      sidecar re-runs `umount -l` + `rclone mount`, re-establishing its
#      FUSE mount against the fresh Altmount. The sidecar readiness probe
#      (`test -d /host-mount/rclone-<app>-altmount/complete`) gates rollout
#      success, so a completed rollout means the mount is live.
#   3. Restart altmount-sync-helper (talks to the Altmount API and refreshes
#      Plex libraries) once source and consumers are healthy.
#
# Apps whose Flux Kustomization is currently unwired (for example decypharr,
# nzbdav, and their sync-helpers) are warn-skipped if not present.
#
# Default wait timeout per rollout: 300s

set -euo pipefail

TIMEOUT="${1:-300}"
if [[ "$TIMEOUT" == "--wait-timeout" ]]; then
    shift
    TIMEOUT="${1:-300}"
fi

NAMESPACE="media"

# The single WebDAV source for all rclone-altmount sidecar mounts
SOURCE="altmount"

# Apps that run the rclone-altmount sidecar (FUSE mount consumers)
CONSUMERS=(
    jellyfin
    media-debug
    plex
    radarr
    radarr4k
    sonarr
    sonarr4k
)

# API consumer: depends on altmount and plex being healthy, no FUSE mount
POST_TASKS=(
    altmount-sync-helper
)

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; }

deployment_exists() {
    kubectl get deployment "$1" -n "$NAMESPACE" &>/dev/null
}

wait_for_rollout() {
    local app="$1"
    if kubectl rollout status deployment/"$app" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; then
        ok "$app is ready."
    else
        fail "$app failed to become ready within ${TIMEOUT}s."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1/3: Restart Altmount (the WebDAV source for every sidecar mount)
# ---------------------------------------------------------------------------
info "Step 1/3 — Restarting Altmount..."
if deployment_exists "$SOURCE"; then
    kubectl rollout restart deployment/"$SOURCE" -n "$NAMESPACE"
    wait_for_rollout "$SOURCE"
else
    warn "  Deployment $SOURCE not found in $NAMESPACE, aborting."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2/3: Restart all mount consumers so their sidecars re-mount
# ---------------------------------------------------------------------------
info "Step 2/3 — Restarting rclone-altmount consumers..."
RESTARTED=()
for app in "${CONSUMERS[@]}"; do
    if deployment_exists "$app"; then
        kubectl rollout restart deployment/"$app" -n "$NAMESPACE"
        RESTARTED+=("$app")
        info "  Restarted $app"
    else
        warn "  Deployment $app not found in $NAMESPACE, skipping"
    fi
done

info "Waiting for consumers to become ready (rollout success = mount live)..."
FAIL=0
for app in "${RESTARTED[@]}"; do
    wait_for_rollout "$app" || FAIL=1
done

# ---------------------------------------------------------------------------
# Step 3/3: Restart API-based helpers once source and consumers are healthy
# ---------------------------------------------------------------------------
info "Step 3/3 — Restarting post-task helpers..."
for app in "${POST_TASKS[@]}"; do
    if deployment_exists "$app"; then
        kubectl rollout restart deployment/"$app" -n "$NAMESPACE"
        wait_for_rollout "$app" || FAIL=1
    else
        warn "  Deployment $app not found in $NAMESPACE, skipping"
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    ok "Media chain restart complete — altmount and all mount consumers healthy."
else
    fail "Some deployments did not become ready. Check pod events for details."
    exit 1
fi
