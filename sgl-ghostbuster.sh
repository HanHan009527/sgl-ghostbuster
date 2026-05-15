#!/bin/bash
# ============================================================
#  Name: sglang-ghostbuster.sh
#  Purpose: Auto-detect CI docker GPU leaks and fix them
#  Project: sglang-ghostbuster
#  Author: hank 2025-10-22
# ============================================================

LOG_DIR="${LOG_DIR:-/var/log/sgl-ghostbuster}"
mkdir -p "$LOG_DIR"
REBOOT_COUNT_FILE="$LOG_DIR/reboot_count_$(date +%F).txt"
LOCK_FILE="$LOG_DIR/guard.lock"
GPU_LEAK_THRESHOLD=51200                   # Total VRAM usage MiB threshold for reboot (50GB = 51200MiB)
LOG_LINES=200                              # Number of log lines to check
MAX_DAILY_REBOOTS="${MAX_DAILY_REBOOTS:-6}"

RDMA_HEALTHCHECK_ENABLED="${RDMA_HEALTHCHECK_ENABLED:-1}"
RDMA_HEALTHCHECK_SCRIPT="${RDMA_HEALTHCHECK_SCRIPT:-/usr/local/bin/sgl-rdma-healthcheck.sh}"
GHOSTBUSTER_DRY_RUN="${GHOSTBUSTER_DRY_RUN:-0}"

timestamp() { date +"%F %T"; }

log() {
    echo "[$(timestamp)] $*" | tee -a "$LOG_DIR/guard.log"
}

ci_runner_state() {
    found_idle_signal=0
    found_container=0
    if ! command -v docker >/dev/null 2>&1; then
        log "Cannot determine CI runner state: docker command not found"
        echo "unknown"
        return
    fi

    containers_output=$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "Cannot determine CI runner state: docker ps failed"
        echo "unknown"
        return
    fi

    while read -r id name; do
        [ -n "$id" ] || continue
        found_container=1
        log_file=$(docker inspect --format='{{.LogPath}}' "$id" 2>/dev/null)
        [ -f "$log_file" ] || continue
        last_state=$(tail -n "$LOG_LINES" "$log_file" | grep -aE "Running job:|Job .* completed with result:|Listening for Jobs" | tail -n 1)
        if echo "$last_state" | grep -q "Running job:"; then
            log "Active CI job detected in container $name ($id): $last_state"
            echo "active"
            return
        fi
        if echo "$last_state" | grep -qE "Job .* completed with result:|Listening for Jobs"; then
            log "Idle CI runner state detected in container $name ($id): $last_state"
            found_idle_signal=1
        fi
    done <<< "$containers_output"

    if [ "$found_idle_signal" = "1" ]; then
        echo "idle"
    elif [ "$found_container" = "1" ]; then
        echo "unknown"
    else
        log "No running Docker containers found; treating CI runner state as idle."
        echo "idle"
    fi
}

reboot_host() {
    reason="$1"

    count=$(cat "$REBOOT_COUNT_FILE" 2>/dev/null || echo 0)
    count=$((count+1))
    log "Reboot requested: $reason"
    log "Updating reboot count: $count"
    echo "$count" > "$REBOOT_COUNT_FILE"
    log "Today reboot count: $count"

    if [ "$count" -gt "$MAX_DAILY_REBOOTS" ]; then
        log "Daily reboot limit $MAX_DAILY_REBOOTS exceeded, not rebooting."
        return 1
    fi

    if [ "$GHOSTBUSTER_DRY_RUN" = "1" ]; then
        log "GHOSTBUSTER_DRY_RUN=1, reboot command skipped."
        return 0
    fi

    log "Syncing filesystem..."
    sync
    log "Waiting 2 seconds before system reboot..."
    sleep 2
    log "Executing system reboot command..."
    /usr/bin/systemctl reboot
}

run_rdma_healthcheck() {
    if [ "$RDMA_HEALTHCHECK_ENABLED" != "1" ]; then
        log "RDMA healthcheck disabled."
        return 0
    fi

    if [ ! -x "$RDMA_HEALTHCHECK_SCRIPT" ]; then
        log "RDMA healthcheck failed: script $RDMA_HEALTHCHECK_SCRIPT is missing or not executable"
        return 1
    fi

    "$RDMA_HEALTHCHECK_SCRIPT"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another sglang-ghostbuster check is already running, exiting."
    exit 0
fi

log "=== sglang-ghostbuster check started ==="

if ! run_rdma_healthcheck; then
    log "RDMA healthcheck failed."
    log "RDMA healthcheck failure is treated as fatal for active CI; reboot will not be deferred for active jobs."
    reboot_host "RDMA healthcheck failed"
    exit 1
fi

log "RDMA healthcheck passed."

# CI jobs normally occupy GPU memory. Only classify high VRAM as a leak when
# the runner is idle.
ci_state=$(ci_runner_state | tail -n 1)
case "$ci_state" in
    active)
        log "Active CI job detected; GPU memory use is expected, skipping GPU leak check."
        exit 0
        ;;
    idle)
        ;;
    *)
        log "CI runner state is unknown; skipping GPU leak check to avoid rebooting an active job."
        exit 0
        ;;
esac

# ------------------------------------------------------------
# Step 1. Check idle GPU memory usage
# ------------------------------------------------------------
log "No active CI job detected; checking GPU memory usage for leaks."

if ! nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv > "$LOG_DIR/nvidia_current.txt" 2>&1; then
    log "Error: nvidia-smi command failed, cannot check GPU memory leak."
    cat "$LOG_DIR/nvidia_current.txt" | while IFS= read -r line; do
        log "$line"
    done
    exit 1
fi

# Parse VRAM usage from CSV format (skip header row, sum memory.used for all GPUs)
used=$(tail -n +2 "$LOG_DIR/nvidia_current.txt" | awk -F',' '{gsub(/[^0-9]/, "", $3); sum += $3} END {print sum+0}')
if [ -z "$used" ]; then
    log "Error: Could not parse VRAM usage."
    exit 1
fi

# Record detailed VRAM status to log
log "=== GPU VRAM status details ==="
log "GPU status CSV data:"
cat "$LOG_DIR/nvidia_current.txt" | while IFS= read -r line; do
    log "$line"
done

log "Current total VRAM usage: ${used}MiB"
log "VRAM leak threshold: ${GPU_LEAK_THRESHOLD}MiB"

if [ "$used" -gt "$GPU_LEAK_THRESHOLD" ]; then
    log "GPU memory leak detected while no CI job is active; rebooting host."
    reboot_host "Idle GPU memory usage ${used}MiB exceeds threshold ${GPU_LEAK_THRESHOLD}MiB"
else
    log "No idle GPU memory leak detected."
fi

log "=== sglang-ghostbuster check completed ==="
