#!/bin/bash
# ============================================================
#  Name: sgl-rdma-healthcheck.sh
#  Purpose: Check RDMA/MLX health using the same CI image Mooncake uses
#  Project: sglang-ghostbuster
# ============================================================

LOG_DIR="${LOG_DIR:-/var/log/sgl-ghostbuster}"
mkdir -p "$LOG_DIR"

RDMA_CI_CONTAINER_NAME="${RDMA_CI_CONTAINER_NAME:-sgl-ci-v2}"
RDMA_EXPECTED_DEVICES="${RDMA_EXPECTED_DEVICES:-mlx5_1,mlx5_2,mlx5_3,mlx5_4}"
RDMA_HEALTHCHECK_TIMEOUT="${RDMA_HEALTHCHECK_TIMEOUT:-90}"
RDMA_MOONCAKE_IMPORT_CHECK="${RDMA_MOONCAKE_IMPORT_CHECK:-1}"
RDMA_MOONCAKE_INIT_CHECK="${RDMA_MOONCAKE_INIT_CHECK:-1}"
RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK="${RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK:-1}"
RDMA_TENSOR_CUDA_DEVICE="${RDMA_TENSOR_CUDA_DEVICE:-0}"
RDMA_TENSOR_NUM_BYTES="${RDMA_TENSOR_NUM_BYTES:-1024}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$SCRIPT_DIR/sgl-rdma-container-check.sh" ]; then
    DEFAULT_SUPPORT_DIR="$SCRIPT_DIR"
else
    DEFAULT_SUPPORT_DIR="/usr/local/lib/sgl-ghostbuster"
fi
RDMA_HEALTHCHECK_SUPPORT_DIR="${RDMA_HEALTHCHECK_SUPPORT_DIR:-$DEFAULT_SUPPORT_DIR}"
RDMA_CONTAINER_CHECK_DIR="${RDMA_CONTAINER_CHECK_DIR:-/tmp/sgl-rdma-healthcheck}"

timestamp() { date +"%F %T"; }

log() {
    echo "[$(timestamp)] $*" | tee -a "$LOG_DIR/guard.log"
}

check_host_rdma_devices() {
    old_ifs="$IFS"
    IFS=','
    set -- $RDMA_EXPECTED_DEVICES
    IFS="$old_ifs"

    for dev in "$@"; do
        dev=$(echo "$dev" | xargs)
        [ -n "$dev" ] || continue

        port_path="/sys/class/infiniband/$dev/ports/1"
        if [ ! -d "$port_path" ]; then
            log "RDMA host check failed: missing $port_path"
            return 1
        fi

        state=$(cat "$port_path/state" 2>/dev/null || true)
        rate=$(cat "$port_path/rate" 2>/dev/null || true)
        log "RDMA host device $dev state='$state' rate='$rate'"
        if ! echo "$state" | grep -qi "ACTIVE"; then
            log "RDMA host check failed: $dev is not ACTIVE"
            return 1
        fi
    done
}

run_rdma_healthcheck_container() {
    image=$(docker inspect --format='{{.Config.Image}}' "$RDMA_CI_CONTAINER_NAME" 2>/dev/null)
    if [ -z "$image" ]; then
        log "RDMA healthcheck failed: cannot resolve image from container $RDMA_CI_CONTAINER_NAME"
        return 1
    fi

    for file in \
        sgl-rdma-container-check.sh \
        sgl-rdma-mooncake-import-check.py \
        sgl-rdma-mooncake-init-check.py \
        sgl-rdma-mooncake-tensor-transfer-check.py
    do
        if [ ! -f "$RDMA_HEALTHCHECK_SUPPORT_DIR/$file" ]; then
            log "RDMA healthcheck failed: missing support file $RDMA_HEALTHCHECK_SUPPORT_DIR/$file"
            return 1
        fi
    done

    name="sgl-rdma-healthcheck-$$"
    log "Starting RDMA healthcheck container $name with image $image and devices $RDMA_EXPECTED_DEVICES"
    output_file="$LOG_DIR/rdma_healthcheck_$(date +%s).log"
    docker create \
        --name "$name" \
        --runtime=nvidia \
        --privileged \
        --network host \
        --ipc host \
        --cap-add ALL \
        --security-opt seccomp=unconfined \
        --security-opt label=disable \
        --ulimit memlock=-1:-1 \
        --ulimit stack=67108864:67108864 \
        -e RDMA_EXPECTED_DEVICES="$RDMA_EXPECTED_DEVICES" \
        -e RDMA_MOONCAKE_IMPORT_CHECK="$RDMA_MOONCAKE_IMPORT_CHECK" \
        -e RDMA_MOONCAKE_INIT_CHECK="$RDMA_MOONCAKE_INIT_CHECK" \
        -e RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK="$RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK" \
        -e RDMA_TENSOR_CUDA_DEVICE="$RDMA_TENSOR_CUDA_DEVICE" \
        -e RDMA_TENSOR_NUM_BYTES="$RDMA_TENSOR_NUM_BYTES" \
        "$image" \
        sleep "$RDMA_HEALTHCHECK_TIMEOUT" > /dev/null 2> "$output_file"
    ret=$?

    if [ "$ret" -eq 0 ]; then
        docker start "$name" >/dev/null 2>> "$output_file"
        ret=$?
    fi

    if [ "$ret" -eq 0 ]; then
        docker exec "$name" mkdir -p "$RDMA_CONTAINER_CHECK_DIR" >> "$output_file" 2>&1
        ret=$?
    fi

    if [ "$ret" -eq 0 ]; then
        docker cp "$RDMA_HEALTHCHECK_SUPPORT_DIR/." "$name:$RDMA_CONTAINER_CHECK_DIR" >> "$output_file" 2>&1
        ret=$?
    fi

    if [ "$ret" -eq 0 ]; then
        timeout "$RDMA_HEALTHCHECK_TIMEOUT" docker exec \
            -e RDMA_EXPECTED_DEVICES="$RDMA_EXPECTED_DEVICES" \
            -e RDMA_MOONCAKE_IMPORT_CHECK="$RDMA_MOONCAKE_IMPORT_CHECK" \
            -e RDMA_MOONCAKE_INIT_CHECK="$RDMA_MOONCAKE_INIT_CHECK" \
            -e RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK="$RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK" \
            -e RDMA_TENSOR_CUDA_DEVICE="$RDMA_TENSOR_CUDA_DEVICE" \
            -e RDMA_TENSOR_NUM_BYTES="$RDMA_TENSOR_NUM_BYTES" \
            "$name" \
            /bin/bash "$RDMA_CONTAINER_CHECK_DIR/sgl-rdma-container-check.sh" >> "$output_file" 2>&1
        ret=$?
    fi

    expected_count=$(echo "$RDMA_EXPECTED_DEVICES" | tr ',' '\n' | awk 'NF {count++} END {print count+0}')
    discovered_count=$(grep -aoE "Found [0-9]+ HCAs" "$output_file" | tail -n 1 | awk '{print $2}')
    if grep -aqE "Failed to open device|Skipping unavailable device|Failed to allocate new protection domain|Disable device|Failed to create QP" "$output_file"; then
        log "RDMA healthcheck detected unavailable expected device in Mooncake output"
        ret=21
    elif [ -n "$discovered_count" ] && [ "$discovered_count" -lt "$expected_count" ]; then
        log "RDMA healthcheck found only $discovered_count HCAs, expected $expected_count"
        ret=22
    fi

    while IFS= read -r line; do
        log "RDMA container: $line"
    done < "$output_file"

    docker rm -f "$name" >/dev/null 2>&1 || true

    if [ "$ret" -ne 0 ]; then
        log "RDMA healthcheck container failed with exit code $ret"
    fi
    return "$ret"
}

run_rdma_healthcheck() {
    if ! command -v docker >/dev/null 2>&1; then
        log "RDMA healthcheck failed: docker command not found"
        return 1
    fi

    if [ ! -d /dev/infiniband ]; then
        log "RDMA healthcheck failed: /dev/infiniband is missing"
        return 1
    fi

    check_host_rdma_devices || return 1
    run_rdma_healthcheck_container
}

run_rdma_healthcheck
