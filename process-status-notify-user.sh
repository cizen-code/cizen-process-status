#!/usr/bin/env bash
# ==============================================================================
# process-status-notify-user.sh — Wrapper fino para la unidad de usuario systemd
# Suite: Process Status · Cizen (v1.0.0)
# Espejo de: arch-update-notify-user.sh
# ==============================================================================
BIN_DIR="/usr/local/bin/process-status"
if [[ ! -x "${BIN_DIR}/process-status-notify-agent.sh" ]]; then
  BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

exec "${BIN_DIR}/process-status-notify-agent.sh" "$@"
