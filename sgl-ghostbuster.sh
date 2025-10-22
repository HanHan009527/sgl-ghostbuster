#!/bin/bash
# ============================================================
#  Name: sglang-ghostbuster.sh
#  Purpose: Auto-detect CI docker GPU leaks and fix them
#  Project: sglang-ghostbuster
#  Author: hank 2025-10-22
# ============================================================

LOG_DIR="/var/log/sg-ghostbuster"
mkdir -p "$LOG_DIR"
REBOOT_COUNT_FILE="$LOG_DIR/reboot_count_$(date +%F).txt"
FAIL_KEYWORD="completed with result: Failed"            # Failure keyword in CI logs
SUCCESS_KEYWORD="completed with result: Succeeded"      # Success keyword in CI logs
MAX_FAIL=5                                 # Consecutive failure threshold
GPU_LEAK_THRESHOLD=51200                   # Total VRAM usage MiB threshold for reboot (50GB = 51200MiB)
LOG_LINES=200                              # Number of log lines to check

timestamp() { date +"%F %T"; }

echo "[$(timestamp)] === sglang-ghostbuster check started ===" | tee -a "$LOG_DIR/guard.log"

# ------------------------------------------------------------
# Step 1. Find containers with consecutive failures in CI logs
# ------------------------------------------------------------
containers=$(docker ps --format '{{.ID}} {{.Names}}' 2>&1)
if [ $? -ne 0 ]; then
    echo "[$(timestamp)] Error: Failed to get container list: $containers" | tee -a "$LOG_DIR/guard.log"
    exit 1
fi

leak_flag=0
for c in $containers; do
    id=$(echo "$c" | awk '{print $1}')
    name=$(echo "$c" | awk '{print $2}')
    log_file=$(docker inspect --format='{{.LogPath}}' "$id" 2>/dev/null)

    if [ -f "$log_file" ]; then
        # Scan from latest logs forward, calculate consecutive failure count
        # Use a temporary file to store the count to avoid subshell issues
        temp_file=$(mktemp)
        continuous_fail_count=0
        
        # Get recent log lines, process from latest
        tail -n "$LOG_LINES" "$log_file" | tac | while IFS= read -r line; do
            if echo "$line" | grep -q "$FAIL_KEYWORD"; then
                continuous_fail_count=$((continuous_fail_count + 1))
                echo "$continuous_fail_count" > "$temp_file"
            elif echo "$line" | grep -q "$SUCCESS_KEYWORD"; then
                # Found success record, system is healthy, stop checking this container
                echo "[$(timestamp)] Container $name ($id) found success record, system healthy, skip check" | tee -a "$LOG_DIR/guard.log"
                echo "0" > "$temp_file"
                break
            fi
        done
        
        # Read the count from temp file
        if [ -f "$temp_file" ]; then
            continuous_fail_count=$(cat "$temp_file")
            rm -f "$temp_file"
        fi
        
        # Check if consecutive failure count reaches threshold
        if [ "$continuous_fail_count" -ge "$MAX_FAIL" ]; then
            echo "[$(timestamp)] Container $name ($id) consecutive failures: $continuous_fail_count" | tee -a "$LOG_DIR/guard.log"
            leak_flag=1
        fi
    fi
done

if [ "$leak_flag" -eq 0 ]; then
    echo "[$(timestamp)] No containers with consecutive $MAX_FAIL failures detected, exiting." | tee -a "$LOG_DIR/guard.log"
    exit 0
fi

# ------------------------------------------------------------
# Step 2. Record GPU status
# ------------------------------------------------------------
echo "[$(timestamp)] Recording GPU status before cleanup..." | tee -a "$LOG_DIR/guard.log"
if ! nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv > "$LOG_DIR/nvidia_before.txt" 2>&1; then
    echo "[$(timestamp)] Warning: nvidia-smi command failed, continuing with cleanup..." | tee -a "$LOG_DIR/guard.log"
fi

# Record VRAM status before cleanup to log
echo "[$(timestamp)] === GPU VRAM status before cleanup ===" | tee -a "$LOG_DIR/guard.log"
if [ -f "$LOG_DIR/nvidia_before.txt" ]; then
    echo "[$(timestamp)] GPU status CSV data before cleanup:" | tee -a "$LOG_DIR/guard.log"
    cat "$LOG_DIR/nvidia_before.txt" | while IFS= read -r line; do
        echo "[$(timestamp)] $line" | tee -a "$LOG_DIR/guard.log"
    done
else
    echo "[$(timestamp)] Warning: nvidia_before.txt file does not exist" | tee -a "$LOG_DIR/guard.log"
fi

# ------------------------------------------------------------
# Step 3. Clean up user-space GPU processes
# ------------------------------------------------------------
echo "[$(timestamp)] Starting GPU user process cleanup..." | tee -a "$LOG_DIR/guard.log"
pids=$(lsof /dev/nvidia* 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
if [ -n "$pids" ]; then
    echo "[$(timestamp)] Found GPU related processes: $pids" | tee -a "$LOG_DIR/guard.log"
    echo "$pids" | xargs -r kill -9
    echo "[$(timestamp)] Process cleanup completed, checking VRAM status immediately..." | tee -a "$LOG_DIR/guard.log"
    # Check VRAM immediately to avoid new processes quickly occupying
    if ! nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv > "$LOG_DIR/nvidia_after.txt" 2>&1; then
        echo "[$(timestamp)] Warning: nvidia-smi command failed after process cleanup" | tee -a "$LOG_DIR/guard.log"
    fi
else
    echo "[$(timestamp)] No GPU user-space processes found." | tee -a "$LOG_DIR/guard.log"
    # Even without processes, check VRAM status immediately
    echo "[$(timestamp)] Checking current GPU status..." | tee -a "$LOG_DIR/guard.log"
    if ! nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv > "$LOG_DIR/nvidia_after.txt" 2>&1; then
        echo "[$(timestamp)] Warning: nvidia-smi command failed" | tee -a "$LOG_DIR/guard.log"
    fi
fi

# ------------------------------------------------------------
# Step 4. Check if still leaking
# ------------------------------------------------------------
# Parse VRAM usage from CSV format (skip header row, sum memory.used for all GPUs)
if [ -f "$LOG_DIR/nvidia_after.txt" ]; then
    used=$(tail -n +2 "$LOG_DIR/nvidia_after.txt" | awk -F',' '{gsub(/[^0-9]/, "", $3); sum += $3} END {print sum+0}')
    if [ -z "$used" ] || [ "$used" = "0" ]; then
        echo "[$(timestamp)] Warning: Could not parse VRAM usage, defaulting to 0" | tee -a "$LOG_DIR/guard.log"
        used=0
    fi
else
    echo "[$(timestamp)] Error: nvidia_after.txt not found, cannot check VRAM usage" | tee -a "$LOG_DIR/guard.log"
    used=0
fi

# Record detailed VRAM status to log
echo "[$(timestamp)] === GPU VRAM status details ===" | tee -a "$LOG_DIR/guard.log"
if [ -f "$LOG_DIR/nvidia_after.txt" ]; then
    echo "[$(timestamp)] GPU status CSV data:" | tee -a "$LOG_DIR/guard.log"
    cat "$LOG_DIR/nvidia_after.txt" | while IFS= read -r line; do
        echo "[$(timestamp)] $line" | tee -a "$LOG_DIR/guard.log"
    done
else
    echo "[$(timestamp)] Warning: nvidia_after.txt file does not exist" | tee -a "$LOG_DIR/guard.log"
fi

echo "[$(timestamp)] Current total VRAM usage: ${used}MiB" | tee -a "$LOG_DIR/guard.log"
echo "[$(timestamp)] VRAM leak threshold: ${GPU_LEAK_THRESHOLD}MiB" | tee -a "$LOG_DIR/guard.log"

if [ "$used" -gt "$GPU_LEAK_THRESHOLD" ]; then
    echo "[$(timestamp)] VRAM still occupied ${used}MiB, preparing to reboot host." | tee -a "$LOG_DIR/guard.log"

    count=$(cat "$REBOOT_COUNT_FILE" 2>/dev/null || echo 0)
    count=$((count+1))
    echo "[$(timestamp)] Updating reboot count: $count" | tee -a "$LOG_DIR/guard.log"
    echo "$count" > "$REBOOT_COUNT_FILE"
    echo "[$(timestamp)] Today reboot count: $count" | tee -a "$LOG_DIR/guard.log"

    echo "[$(timestamp)] Syncing filesystem..." | tee -a "$LOG_DIR/guard.log"
    sync
    echo "[$(timestamp)] Waiting 2 seconds before system reboot..." | tee -a "$LOG_DIR/guard.log"
    sleep 2
    echo "[$(timestamp)] Executing system reboot command..." | tee -a "$LOG_DIR/guard.log"
    /usr/bin/systemctl reboot
else
    echo "[$(timestamp)] VRAM cleanup successful, no reboot needed." | tee -a "$LOG_DIR/guard.log"
fi

echo "[$(timestamp)] === sglang-ghostbuster check completed ===" | tee -a "$LOG_DIR/guard.log"