# sglang-ghostbuster

A GPU leak detection and auto-fix system for CI environments using Docker containers.

## Overview

sglang-ghostbuster is an automated monitoring system that detects RDMA/MLX health failures and idle GPU memory leaks in CI environments, then automatically recovers the executor. It checks RDMA devices from a short-lived healthcheck container, treats active CI GPU memory usage as normal, and reboots when RDMA health fails or when high GPU memory remains while the runner is idle.

## Features

- **Idle GPU Leak Detection**: Checks GPU memory only when no CI job is active
- **Active CI Awareness**: Treats GPU memory usage during a running CI job as expected workload memory, not a leak
- **Memory Monitoring**: Uses nvidia-smi to monitor VRAM usage with CSV output
- **RDMA/MLX Health Check**: Starts a short-lived container from the CI image, verifies expected host InfiniBand devices with ibverbs, and performs lightweight Mooncake RDMA initialization and GPU tensor transfer checks
- **Automatic Recovery**: Performs system reboot when RDMA health fails or idle GPU memory exceeds the threshold
- **Comprehensive Logging**: Detailed logging of all operations and decisions
- **Systemd Integration**: Runs as a systemd timer service for reliable scheduling

## How It Works

1. **RDMA Script Dispatch**: Calls the standalone `/usr/local/bin/sgl-rdma-healthcheck.sh` script when RDMA checking is enabled, including while CI jobs are running
2. **RDMA Host Check**: Verifies expected `/sys/class/infiniband` devices are present and active
3. **RDMA Container Check**: Starts a short-lived container from the running CI image, copies standalone check scripts into it, and verifies `/dev/infiniband`, optional in-container ibverbs CLI output, Mooncake package availability, Mooncake `TransferEngine.initialize(..., "rdma", RDMA_EXPECTED_DEVICES)`, and a tiny CUDA tensor transfer through Mooncake
4. **Active CI Check**: Reads runner container logs and classifies runner state as `active`, `idle`, or `unknown`. If Docker state cannot be read or recent logs do not contain a clear runner state, the result is `unknown`.
5. **Idle GPU Memory Check**: If runner state is explicitly `idle`, captures current GPU memory usage with `nvidia-smi`
6. **Leak Decision**: If idle total GPU memory exceeds `GPU_LEAK_THRESHOLD`, treats it as leaked memory
7. **Recovery Action**: Reboots system if RDMA health fails or idle GPU memory exceeds the threshold. No GPU processes are killed first.

## Configuration

### Key Parameters

- `GPU_LEAK_THRESHOLD`: 51200 - VRAM usage threshold in MiB (50GB)
- `LOG_LINES`: 200 - Number of runner log lines used to detect active CI state
- `RDMA_HEALTHCHECK_ENABLED`: `1` - Enable RDMA/MLX healthcheck before GPU leak handling
- `RDMA_HEALTHCHECK_SCRIPT`: `/usr/local/bin/sgl-rdma-healthcheck.sh` - Standalone RDMA/Mooncake healthcheck script called by the main guard
- `RDMA_CI_CONTAINER_NAME`: `sgl-ci-v2` - Running CI container used to resolve the healthcheck image
- `RDMA_EXPECTED_DEVICES`: `mlx5_1,mlx5_2,mlx5_3,mlx5_4` - Devices expected to be active for H20 CI
- `RDMA_HEALTHCHECK_TIMEOUT`: `90` - Timeout in seconds for the healthcheck container
- `RDMA_MOONCAKE_IMPORT_CHECK`: `1` - Verify the Mooncake package and `transfer_engine_bench` exist in the CI image
- `RDMA_MOONCAKE_INIT_CHECK`: `1` - Initialize Mooncake's transfer engine in the healthcheck container with `RDMA_EXPECTED_DEVICES`
- `RDMA_MOONCAKE_TENSOR_TRANSFER_CHECK`: `1` - Transfer and verify a tiny CUDA tensor through Mooncake between two local processes in the healthcheck container
- `RDMA_TENSOR_CUDA_DEVICE`: `0` - CUDA device used for the tiny tensor transfer check
- `RDMA_TENSOR_NUM_BYTES`: `1024` - Size of the CUDA tensor transfer payload
- `GHOSTBUSTER_DRY_RUN`: `0` - Log reboot decisions without executing reboot when set to `1`
- `MAX_DAILY_REBOOTS`: `6` - Daily reboot safety limit

### Log Files

- `/var/log/sgl-ghostbuster/guard.log` - Main operation log
- `/var/log/sgl-ghostbuster/rdma_healthcheck_*.log` - RDMA container healthcheck output
- `/var/log/sgl-ghostbuster/nvidia_current.txt` - GPU state captured during idle GPU leak checks
- `/var/log/sgl-ghostbuster/reboot_count_YYYY-MM-DD.txt` - Daily reboot counter

## Installation

### Prerequisites

- Linux system with systemd
- Docker installed and running
- NVIDIA GPU with nvidia-smi available
- Root privileges for installation

### Quick Install

```bash
# Clone or download the project
cd sgl-ghostbuster

# Install and enable the service
make install enable
```

### Manual Installation

```bash
# Copy files to system locations
sudo cp sgl-ghostbuster.sh /usr/local/bin/
sudo cp sgl-rdma-healthcheck.sh /usr/local/bin/
sudo mkdir -p /usr/local/lib/sgl-ghostbuster
sudo cp sgl-rdma-container-check.sh /usr/local/lib/sgl-ghostbuster/
sudo cp sgl-rdma-mooncake-import-check.py /usr/local/lib/sgl-ghostbuster/
sudo cp sgl-rdma-mooncake-init-check.py /usr/local/lib/sgl-ghostbuster/
sudo cp sgl-rdma-mooncake-tensor-transfer-check.py /usr/local/lib/sgl-ghostbuster/
sudo cp sgl-ghostbuster.service /etc/systemd/system/
sudo cp sgl-ghostbuster.timer /etc/systemd/system/

# Set permissions
sudo chmod 755 /usr/local/bin/sgl-ghostbuster.sh
sudo chmod 755 /usr/local/bin/sgl-rdma-healthcheck.sh
sudo chmod 755 /usr/local/lib/sgl-ghostbuster/sgl-rdma-container-check.sh

# Reload systemd and enable
sudo systemctl daemon-reload
sudo systemctl enable --now sgl-ghostbuster.timer
```

## Usage

### Make Commands

```bash
# Install and enable service
make install enable

# Check status and logs
make status
make logs

# Manual execution
make run

# Disable service
make disable

# Uninstall completely
make uninstall

# Clean logs
make clean

# Restart service (debug)
make reload
```

### Manual Operations

```bash
# Check timer status
systemctl status sgl-ghostbuster.timer

# View recent logs
tail -f /var/log/sgl-ghostbuster/guard.log

# Manual execution
systemctl start sgl-ghostbuster.service

# Disable timer
systemctl disable --now sgl-ghostbuster.timer
```

## Monitoring

### Log Analysis

The system provides comprehensive logging:

- **RDMA Health**: Host and healthcheck-container RDMA/Mooncake status
- **Active CI State**: Whether runner logs show an active job
- **GPU Status**: Idle GPU memory usage from `nvidia-smi`
- **Decision Process**: Why reboots are or aren't triggered

### Key Log Messages

- `RDMA host device mlx5_1 state='4: ACTIVE' rate='400 Gb/sec (4X NDR)'`
- `Starting RDMA healthcheck container ...`
- `RDMA container check passed`
- `Mooncake tensor transfer check passed: bytes=1024 cuda_device=0 devices=...`
- `RDMA healthcheck failed`
- `Active CI job detected; GPU memory use is expected, skipping GPU leak check`
- `CI runner state is unknown; skipping GPU leak check to avoid rebooting an active job`
- `No active CI job detected; checking GPU memory usage for leaks`
- `Current total VRAM usage: XMiB`
- `GPU memory leak detected while no CI job is active; rebooting host`
- `No idle GPU memory leak detected`

## Troubleshooting

### Common Issues

1. **Service not running**
   ```bash
   systemctl status sgl-ghostbuster.timer
   systemctl enable --now sgl-ghostbuster.timer
   ```

2. **Permission denied**
   ```bash
   sudo chmod 755 /usr/local/bin/sgl-ghostbuster.sh
   ```

3. **nvidia-smi not found**
   - Ensure NVIDIA drivers are installed
   - Check PATH includes nvidia-smi location

4. **Docker containers not detected**
   - Verify Docker is running: `docker ps`
   - Check container log paths are accessible

5. **RDMA healthcheck fails**
   - Check host devices: `ibv_devices`, `ibv_devinfo`, `rdma link`
   - Check expected device list: `RDMA_EXPECTED_DEVICES`
   - Check container output: `tail -n 100 /var/log/sgl-ghostbuster/rdma_healthcheck_*.log`
   - Check that `/usr/local/bin/sgl-rdma-healthcheck.sh` exists and is executable
   - Check that the CI container named by `RDMA_CI_CONTAINER_NAME` exists so the healthcheck image can be resolved
   - Run the standalone check directly: `/usr/local/bin/sgl-rdma-healthcheck.sh`
   - Run the full guard in dry-run mode first: `GHOSTBUSTER_DRY_RUN=1 /usr/local/bin/sgl-ghostbuster.sh`

### Debug Mode

```bash
# Run manually with verbose output
sudo /usr/local/bin/sgl-ghostbuster.sh

# Run only RDMA/Mooncake healthcheck
sudo /usr/local/bin/sgl-rdma-healthcheck.sh

# Check systemd logs
journalctl -u sgl-ghostbuster.service -f
```

## Safety Features

- **Active CI Protection**: Skips GPU memory leak classification while a CI job is active or when runner state cannot be determined
- **Threshold Protection**: Reboots for GPU memory only when idle total VRAM usage exceeds 50GB
- **RDMA Device Scope**: Checks only `RDMA_EXPECTED_DEVICES`, so inactive management or unused devices do not trigger reboot
- **RDMA Fail-Closed**: Missing RDMA script, missing Docker, or unresolved CI image fails the healthcheck instead of silently passing
- **RDMA Fatal Recovery**: RDMA healthcheck still runs during active CI; RDMA failure triggers reboot immediately
- **Daily Reboot Limit**: Stops rebooting after `MAX_DAILY_REBOOTS`
- **No Process Killing**: Does not attempt `kill -9`; leak recovery is reboot-only
- **Logging**: Complete audit trail of all actions
- **Graceful Degradation**: Continues operation even if some commands fail

## File Structure

```
sgl-ghostbuster/
├── sgl-ghostbuster.sh          # Main script
├── sgl-rdma-healthcheck.sh     # Host-side standalone RDMA/Mooncake healthcheck
├── sgl-rdma-container-check.sh # Container-side RDMA check entrypoint
├── sgl-rdma-mooncake-import-check.py
├── sgl-rdma-mooncake-init-check.py
├── sgl-rdma-mooncake-tensor-transfer-check.py
├── sgl-ghostbuster.service     # Systemd service file
├── sgl-ghostbuster.timer       # Systemd timer file
├── Makefile                    # Build and management commands
└── README.md                   # This file
```

## License

This project is part of the sglang-ghostbuster system for automated GPU leak detection and recovery in CI environments.

## Support

For issues or questions:
1. Check the logs: `make logs`
2. Verify service status: `make status`
3. Review configuration parameters in the script
4. Check system prerequisites (Docker, NVIDIA drivers, systemd)
