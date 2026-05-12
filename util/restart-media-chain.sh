#!/bin/bash
# Restarts the Decypharr → CSI-Rclone → Media Apps chain in the correct order.
#
# Usage: ./util/restart-media-chain.sh [--wait-timeout SECONDS]
#
# Order:
#   1. Scale down all media consumers that use the CSI rclone mount
#   2. Restart Decypharr (WebDAV source for the rclone mount)
#   3. Restart CSI-Rclone node DaemonSet (refreshes all FUSE mounts)
#   4. Scale consumers back up and wait for readiness
#
# Default wait timeout per rollout: 300s

set -euo pipefail

TIMEOUT="${1:-300}"
if [[ "$TIMEOUT" == "--wait-timeout" ]]; then
    shift
    TIMEOUT="${1:-300}"
fi

NAMESPACE="media"
CSI_NAMESPACE="csi-rclone"

# Apps that consume the CSI rclone mount (exclude decypharr — it is restarted separately)
CONSUMERS=(
    jellyfin
    media-debug
    plex
    radarr
    radarr4k
    sonarr
    sonarr4k
)

# Decypharr also mounts itself via CSI rclone, so it is both a source and a consumer
SOURCE="decypharr"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; }

# ---------------------------------------------------------------------------
# Step 1: Scale down consumers so they release CSI rclone mounts
# ---------------------------------------------------------------------------
info "Step 1/5 — Scaling down media consumers..."
for app in "${CONSUMERS[@]}" "$SOURCE"; do
    if kubectl get deployment "$app" -n "$NAMESPACE" &>/dev/null; then
        kubectl scale deployment "$app" -n "$NAMESPACE" --replicas=0
        info "  Scaled down $app"
    else
        warn "  Deployment $app not found in $NAMESPACE, skipping"
    fi
done

info "Waiting for scaled-down pods to terminate..."
for app in "${CONSUMERS[@]}" "$SOURCE"; do
    if kubectl get deployment "$app" -n "$NAMESPACE" &>/dev/null; then
        kubectl wait --for=delete pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$app" --timeout="${TIMEOUT}s" 2>/dev/null || true
    fi
done
ok "All scaled-down pods terminated."

# ---------------------------------------------------------------------------
# Step 2: Restart Decypharr (the WebDAV backend)
# ---------------------------------------------------------------------------
info "Step 2/5 — Restarting Decypharr..."
kubectl scale deployment "$SOURCE" -n "$NAMESPACE" --replicas=1
kubectl rollout status deployment "$SOURCE" -n "$NAMESPACE" --timeout="${TIMEOUT}s"
ok "Decypharr is healthy."

# ---------------------------------------------------------------------------
# Step 3: Restart CSI-Rclone node DaemonSet to refresh FUSE mounts
# ---------------------------------------------------------------------------
info "Step 3/5 — Restarting CSI-Rclone node DaemonSet..."
kubectl rollout restart daemonset/csi-rclone-node -n "$CSI_NAMESPACE"
kubectl rollout status daemonset/csi-rclone-node -n "$CSI_NAMESPACE" --timeout="${TIMEOUT}s"
ok "CSI-Rclone node DaemonSet rolled out."

# Brief pause to let CSI node plugin register and stabilize
info "Waiting 10s for CSI node plugin to stabilize..."
sleep 10

# ---------------------------------------------------------------------------
# Step 4: Scale consumers back up
# ---------------------------------------------------------------------------
info "Step 4/5 — Scaling up media consumers..."
for app in "${CONSUMERS[@]}"; do
    if kubectl get deployment "$app" -n "$NAMESPACE" &>/dev/null; then
        kubectl scale deployment "$app" -n "$NAMESPACE" --replicas=1
        info "  Scaled up $app"
    fi
done

# ---------------------------------------------------------------------------
# Step 5: Wait for all consumers to become ready
# ---------------------------------------------------------------------------
info "Step 5/5 — Waiting for all consumers to become ready..."
FAIL=0
for app in "${CONSUMERS[@]}"; do
    if kubectl get deployment "$app" -n "$NAMESPACE" &>/dev/null; then
        if kubectl rollout status deployment "$app" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; then
            ok "$app is ready."
        else
            fail "$app failed to become ready within ${TIMEOUT}s."
            FAIL=1
        fi
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    ok "Media chain restart complete — all deployments healthy."
else
    fail "Some deployments did not become ready. Check pod events for details."
    exit 1
fi
