# sglang-ghostbuster

A GPU leak detection and auto-fix system for CI environments using Docker containers.

## Overview

sglang-ghostbuster is an automated monitoring system that detects GPU memory leaks in CI environments and automatically cleans them up. It monitors Docker container logs for consecutive failures, identifies GPU memory leaks, and performs cleanup operations including process termination and system reboot when necessary.

## Features

- **Automatic GPU Leak Detection**: Monitors CI container logs for consecutive failures
- **Smart Failure Analysis**: Distinguishes between consecutive failures and healthy systems
- **GPU Process Cleanup**: Automatically terminates GPU-related processes
- **Memory Monitoring**: Uses nvidia-smi to monitor VRAM usage with CSV output
- **Automatic Recovery**: Performs system reboot when manual cleanup is insufficient
- **Comprehensive Logging**: Detailed logging of all operations and decisions
- **Systemd Integration**: Runs as a systemd timer service for reliable scheduling

## How It Works

1. **Container Monitoring**: Scans running Docker containers for log files
2. **Failure Detection**: Analyzes recent logs for consecutive failure patterns
3. **Health Check**: Stops monitoring containers that show recent success or healthy startup
4. **GPU Status Recording**: Captures GPU memory state before cleanup
5. **Process Cleanup**: Terminates GPU-related user-space processes
6. **Memory Verification**: Checks VRAM usage after cleanup
7. **Recovery Action**: Reboots system if memory leak persists

## Configuration

### Key Parameters

- `FAIL_KEYWORD`: "completed with result: Failed" - Failure keyword in CI logs
- `SUCCESS_KEYWORD`: "completed with result: Succeeded" - Success keyword in CI logs
- `HEALTHY_KEYWORD`: "Listening for Jobs" - Healthy keyword indicating CI startup
- `MAX_FAIL`: 5 - Consecutive failure threshold
- `GPU_LEAK_THRESHOLD`: 51200 - VRAM usage threshold in MiB (50GB)
- `LOG_LINES`: 200 - Number of log lines to analyze

### Log Files

- `/var/log/sg-ghostbuster/guard.log` - Main operation log
- `/var/log/sg-ghostbuster/nvidia_before.txt` - GPU state before cleanup
- `/var/log/sg-ghostbuster/nvidia_after.txt` - GPU state after cleanup
- `/var/log/sg-ghostbuster/reboot_count_YYYY-MM-DD.txt` - Daily reboot counter

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
sudo cp sgl-ghostbuster.service /etc/systemd/system/
sudo cp sgl-ghostbuster.timer /etc/systemd/system/

# Set permissions
sudo chmod 755 /usr/local/bin/sgl-ghostbuster.sh

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
tail -f /var/log/sg-ghostbuster/guard.log

# Manual execution
systemctl start sgl-ghostbuster.service

# Disable timer
systemctl disable --now sgl-ghostbuster.timer
```

## Monitoring

### Log Analysis

The system provides comprehensive logging:

- **Container Analysis**: Which containers are being monitored
- **Failure Detection**: Consecutive failure counts and patterns
- **GPU Status**: Before and after cleanup VRAM usage
- **Cleanup Actions**: Process termination and system operations
- **Decision Process**: Why reboots are or aren't triggered

### Key Log Messages

- `Container X found success record, system healthy, skip check`
- `Container X found healthy startup record, system healthy, skip check`
- `Container X consecutive failures: N`
- `Current total VRAM usage: XMiB`
- `VRAM still occupied XMiB, preparing to reboot host`
- `VRAM cleanup successful, no reboot needed`

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

### Debug Mode

```bash
# Run manually with verbose output
sudo /usr/local/bin/sgl-ghostbuster.sh

# Check systemd logs
journalctl -u sgl-ghostbuster.service -f
```

## Safety Features

- **Health Detection**: Stops monitoring containers showing recent success
- **Threshold Protection**: Only reboots when VRAM usage exceeds 50GB
- **Process Safety**: Only terminates GPU-related processes
- **Logging**: Complete audit trail of all actions
- **Graceful Degradation**: Continues operation even if some commands fail

## File Structure

```
sgl-ghostbuster/
├── sgl-ghostbuster.sh          # Main script
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
