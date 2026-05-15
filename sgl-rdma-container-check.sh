#!/bin/bash
# ============================================================
#  Name: sgl-rdma-container-check.sh
#  Purpose: Run inside the healthcheck container
# ============================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "RDMA container check started on $(hostname)"
test -d /dev/infiniband
ls -l /dev/infiniband

if command -v ibv_devices >/dev/null 2>&1 && command -v ibv_devinfo >/dev/null 2>&1; then
    ibv_devices

    old_ifs="$IFS"
    IFS=","
    set -- ${RDMA_EXPECTED_DEVICES:-}
    IFS="$old_ifs"

    for dev in "$@"; do
        dev="$(echo "$dev" | xargs)"
        [ -n "$dev" ] || continue
        echo "Checking ibv_devinfo for $dev"
        ibv_devinfo -d "$dev" >/tmp/ibv_devinfo."$dev" 2>&1 || {
            cat /tmp/ibv_devinfo."$dev"
            exit 20
        }
        grep -E "hca_id:[[:space:]]*$dev|port:[[:space:]]+1|state:[[:space:]]+PORT_ACTIVE" /tmp/ibv_devinfo."$dev" || true
    done
else
    echo "ibv_devices/ibv_devinfo not found in container; host-level ibverbs check already ran"
fi

if [ "${RDMA_MOONCAKE_IMPORT_CHECK:-1}" = "1" ]; then
    python3 "$SCRIPT_DIR/sgl-rdma-mooncake-import-check.py"
fi

if [ "${RDMA_MOONCAKE_INIT_CHECK:-1}" = "1" ]; then
    python3 "$SCRIPT_DIR/sgl-rdma-mooncake-init-check.py"
fi

if [ "${RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK:-1}" = "1" ]; then
    python3 "$SCRIPT_DIR/sgl-rdma-mooncake-tensor-transfer-check.py"
fi

echo "RDMA container check passed"
