#!/bin/sh
set -e

EXPORT_PATH="${EXPORT_PATH:-/data}"
EXPORT_OPTS="${EXPORT_OPTS:-*(ro,fsid=0,async,no_subtree_check,no_auth_nlm,insecure,no_root_squash)}"

# Wait for the export path to exist (rclone may not have mounted yet)
while [ ! -d "$EXPORT_PATH" ]; do
  echo "Waiting for $EXPORT_PATH to exist..."
  sleep 2
done

echo "${EXPORT_PATH} ${EXPORT_OPTS}" > /etc/exports

rpcbind 2>/dev/null || true
rpc.nfsd -N 2 -N 3 8
rpc.mountd -N 2 -N 3 --foreground &

exportfs -ra
echo "NFS server ready, exporting ${EXPORT_PATH}"

exec sleep infinity
