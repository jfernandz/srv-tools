SCRIPT_NAME := proton-amule-port-sync.sh
SERVICE_NAME := proton-amule-port-sync.service
ENV_NAME := proton-amule-port-sync.env

DESTDIR ?=
BINDIR ?= /usr/local/bin
SYSTEMD_UNIT_DIR ?= /etc/systemd/system
ENV_DIR ?= /etc/default

SRC_DIR := ../src

SCRIPT_SRC := $(SRC_DIR)/$(SCRIPT_NAME)
SERVICE_SRC := $(SRC_DIR)/$(SERVICE_NAME)
ENV_SRC := $(SRC_DIR)/proton-amule-port-sync.env.example

SCRIPT_DEST := $(DESTDIR)$(BINDIR)/$(SCRIPT_NAME)
SERVICE_DEST := $(DESTDIR)$(SYSTEMD_UNIT_DIR)/$(SERVICE_NAME)
ENV_DEST := $(DESTDIR)$(ENV_DIR)/$(ENV_NAME)

.PHONY: install uninstall reload enable disable start stop restart

install:
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(SYSTEMD_UNIT_DIR)" "$(DESTDIR)$(ENV_DIR)"
	install -m 0755 "$(SCRIPT_SRC)" "$(SCRIPT_DEST)"
	install -m 0644 "$(SERVICE_SRC)" "$(SERVICE_DEST)"
	install -m 0644 "$(ENV_SRC)" "$(ENV_DEST)"

uninstall:
	rm -f "$(SCRIPT_DEST)"
	rm -f "$(SERVICE_DEST)"
	rm -f "$(ENV_DEST)"

reload:
	systemctl daemon-reload

enable: reload
	systemctl enable --now "$(SERVICE_NAME)"

disable:
	systemctl disable --now "$(SERVICE_NAME)"

start:
	systemctl start "$(SERVICE_NAME)"

stop:
	systemctl stop "$(SERVICE_NAME)"

restart:
	systemctl restart "$(SERVICE_NAME)"
