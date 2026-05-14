#!/bin/sh
set -e

EXPORT_PATH="${EXPORT_PATH:-/data}"
EXPORT_OPTS="${EXPORT_OPTS:-*(ro,fsid=0,async,no_subtree_check,no_auth_nlm,insecure,no_root_squash)}"

echo "${EXPORT_PATH} ${EXPORT_OPTS}" > /etc/exports

rpcbind
rpc.nfsd -N 2 -N 3 8
rpc.mountd -N 2 -N 3 --foreground &

exportfs -ra
echo "NFS server ready, exporting ${EXPORT_PATH}"

exec sleep infinity
