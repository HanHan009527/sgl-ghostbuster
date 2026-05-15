# ============================================================
#  sglang-ghostbuster - GPU leak guard auto-fix system
# ============================================================

SERVICE_NAME=sgl-ghostbuster
BIN_PATH=/usr/local/bin/$(SERVICE_NAME).sh
RDMA_HEALTHCHECK_NAME=sgl-rdma-healthcheck
RDMA_HEALTHCHECK_BIN=/usr/local/bin/$(RDMA_HEALTHCHECK_NAME).sh
SUPPORT_DIR=/usr/local/lib/$(SERVICE_NAME)
SERVICE_FILE=/etc/systemd/system/$(SERVICE_NAME).service
TIMER_FILE=/etc/systemd/system/$(SERVICE_NAME).timer
LOG_DIR=/var/log/$(SERVICE_NAME)

# Default target
all: install enable status

# ------------------------------------------------------------
# Install script and systemd configuration
# ------------------------------------------------------------
install:
	@echo ">>> Installing $(SERVICE_NAME) ..."
	mkdir -p $(LOG_DIR)
	cp $(SERVICE_NAME).sh $(BIN_PATH)
	chmod 755 $(BIN_PATH)
	cp $(RDMA_HEALTHCHECK_NAME).sh $(RDMA_HEALTHCHECK_BIN)
	chmod 755 $(RDMA_HEALTHCHECK_BIN)
	mkdir -p $(SUPPORT_DIR)
	cp sgl-rdma-container-check.sh $(SUPPORT_DIR)/
	cp sgl-rdma-mooncake-import-check.py $(SUPPORT_DIR)/
	cp sgl-rdma-mooncake-init-check.py $(SUPPORT_DIR)/
	cp sgl-rdma-mooncake-tensor-transfer-check.py $(SUPPORT_DIR)/
	chmod 755 $(SUPPORT_DIR)/sgl-rdma-container-check.sh
	chmod 644 $(SUPPORT_DIR)/sgl-rdma-mooncake-import-check.py $(SUPPORT_DIR)/sgl-rdma-mooncake-init-check.py $(SUPPORT_DIR)/sgl-rdma-mooncake-tensor-transfer-check.py
	cp $(SERVICE_NAME).service $(SERVICE_FILE)
	cp $(SERVICE_NAME).timer $(TIMER_FILE)
	systemctl daemon-reload
	@echo ">>> Installation completed ✅"

# ------------------------------------------------------------
# Enable timer
# ------------------------------------------------------------
enable:
	@echo ">>> Enabling $(SERVICE_NAME).timer ..."
	systemctl enable --now $(SERVICE_NAME).timer
	systemctl daemon-reexec
	systemctl daemon-reload
	@echo ">>> $(SERVICE_NAME).timer started ✅"

# ------------------------------------------------------------
# Disable and uninstall
# ------------------------------------------------------------
disable:
	@echo ">>> Stopping and disabling $(SERVICE_NAME) ..."
	systemctl disable --now $(SERVICE_NAME).timer || true
	systemctl disable --now $(SERVICE_NAME).service || true
	systemctl daemon-reload
	@echo ">>> Disabled ✅"

uninstall: disable
	@echo ">>> Uninstalling $(SERVICE_NAME) ..."
	rm -f $(SERVICE_FILE) $(TIMER_FILE) $(BIN_PATH) $(RDMA_HEALTHCHECK_BIN)
	rm -rf $(SUPPORT_DIR)
	rm -rf $(LOG_DIR)
	systemctl daemon-reload
	@echo ">>> Uninstalled ✅"

# ------------------------------------------------------------
# Manual execution
# ------------------------------------------------------------
run:
	@echo ">>> Manually executing $(SERVICE_NAME) check ..."
	systemctl start $(SERVICE_NAME).service

# ------------------------------------------------------------
# View status and logs
# ------------------------------------------------------------
status:
	@echo ">>> Timer status:"
	systemctl status $(SERVICE_NAME).timer --no-pager || true
	@echo ""
	@echo ">>> Recent execution logs:"
	tail -n 30 $(LOG_DIR)/systemd_guard.log 2>/dev/null || echo "(no logs yet)"

logs:
	@echo ">>> Detailed logs (tail -n 50):"
	tail -n 50 $(LOG_DIR)/guard.log 2>/dev/null || echo "(no logs yet)"

# ------------------------------------------------------------
# Restart system daemon (for debugging)
# ------------------------------------------------------------
reload:
	systemctl daemon-reload
	systemctl restart $(SERVICE_NAME).timer
	systemctl restart $(SERVICE_NAME).service

# ------------------------------------------------------------
# Clean logs and status
# ------------------------------------------------------------
clean:
	@echo ">>> Cleaning logs and status ..."
	rm -rf $(LOG_DIR)/*.log $(LOG_DIR)/nvidia_*.txt $(LOG_DIR)/reboot_count_*.txt
	@echo ">>> Cleaned ✅"

.PHONY: all install enable disable uninstall run status logs reload clean
