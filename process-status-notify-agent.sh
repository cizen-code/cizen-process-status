#!/usr/bin/env bash
# ==============================================================================
# process-status-notify-agent.sh — Agente de notificación de escritorio
# Suite: Process Status · Cizen (v1.0.0)
# Espejo de: arch-update-notify-agent.sh
# ==============================================================================
set -u

STATE_DIR="${CIZEN_PS_STATE_DIR:-/var/cache/process-status}"
REPORT_FILE="${STATE_DIR}/report"
HASH_FILE="${STATE_DIR}/hash"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/process-status"
MARKER="${CACHE_DIR}/last-notified-hash"
LOG="${CACHE_DIR}/agent.log"

# v1.0.0: Terminal launcher centralizado
OPEN_TERM_BIN="/usr/local/bin/arch-open-terminal.sh"
if [[ ! -x "$OPEN_TERM_BIN" ]]; then
  OPEN_TERM_BIN="/usr/local/bin/arch-update/arch-open-terminal.sh"
fi

BIN_DIR="/usr/local/bin/process-status"
if [[ ! -x "${BIN_DIR}/process-status-fix.sh" ]]; then
  BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
FIX_SCRIPT="${BIN_DIR}/process-status-fix.sh"
SHOW_SCRIPT="${BIN_DIR}/process-status-show.sh"

mkdir -p "$CACHE_DIR" 2>/dev/null || true
if [[ -f "$LOG" ]] && (( $(stat -c%s "$LOG" 2>/dev/null || echo 0) > 524288 )); then
  mv "$LOG" "${LOG}.1" 2>/dev/null || true
fi
alog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

[[ -s "$REPORT_FILE" ]] || exit 0
command -v notify-send >/dev/null 2>&1 || exit 0

# v1.0.0: Extracción de variables de entorno del entorno gráfico
pull_env_from_pid() {
  local pid="$1" line
  [[ -r "/proc/$pid/environ" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      DISPLAY=*) [[ -n "${DISPLAY:-}" ]] || export DISPLAY="${line#DISPLAY=}" ;;
      WAYLAND_DISPLAY=*) [[ -n "${WAYLAND_DISPLAY:-}" ]] || export WAYLAND_DISPLAY="${line#WAYLAND_DISPLAY=}" ;;
      XDG_CURRENT_DESKTOP=*) [[ -n "${XDG_CURRENT_DESKTOP:-}" ]] || export XDG_CURRENT_DESKTOP="${line#XDG_CURRENT_DESKTOP=}" ;;
      XDG_DATA_DIRS=*) [[ -n "${XDG_DATA_DIRS:-}" ]] || export XDG_DATA_DIRS="${line#XDG_DATA_DIRS=}" ;;
    esac
  done < <(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null)
}

me="${USER:-$(id -un)}"
if [[ -z "${XDG_CURRENT_DESKTOP:-}" || -z "${XDG_DATA_DIRS:-}" || ( -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ) ]]; then
  sid="$(loginctl show-user "$me" --property=Display --value 2>/dev/null || true)"
  stype=""
  if [[ -n "$sid" ]]; then
    stype="$(loginctl show-session "$sid" --property=Type --value 2>/dev/null || true)"
    leader="$(loginctl show-session "$sid" --property=Leader --value 2>/dev/null || true)"
    [[ -n "$leader" ]] && pull_env_from_pid "$leader"
  fi
  if [[ -z "${XDG_CURRENT_DESKTOP:-}" || -z "${XDG_DATA_DIRS:-}" ]]; then
    for name in plasmashell kwin_wayland kwin_x11 gnome-shell xfce4-session cinnamon sway; do
      pid="$(pgrep -u "$me" -x "$name" 2>/dev/null | head -n 1 || true)"
      [[ -n "$pid" ]] && pull_env_from_pid "$pid"
      [[ -n "${XDG_CURRENT_DESKTOP:-}" && -n "${XDG_DATA_DIRS:-}" ]] && break
    done
  fi
  if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    if [[ "$stype" == "wayland" ]]; then
      export WAYLAND_DISPLAY="wayland-0"
    else
      export DISPLAY=":0"
    fi
  fi
  [[ -n "${XDG_DATA_DIRS:-}" ]] || export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
  alog "Entorno: tipo=${stype:-?} DESKTOP=${XDG_CURRENT_DESKTOP:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} DISPLAY=${DISPLAY:-}"
fi

current_hash=""
[[ -f "$HASH_FILE" ]] && current_hash="$(cat "$HASH_FILE" 2>/dev/null || true)"

# Comprobar si ya fue notificado con este hash
if [[ -n "$current_hash" && -f "$MARKER" && "$(cat "$MARKER" 2>/dev/null || true)" == "$current_hash" ]]; then
  alog "Ya notificado para este hash (${current_hash:0:8}); se omite."
  exit 0
fi

# Extraer alertas y resumen del reporte
alerts_count="$(grep -oE 'Alertas: [0-9]+' "$REPORT_FILE" 2>/dev/null | awk '{print $2}' || echo "0")"
summary="$(grep -E '^Alertas: ' "$REPORT_FILE" 2>/dev/null | head -n 1 || echo "Estado de procesos revisado")"

# Si no hay alertas en el reporte, no molestamos al usuario
if [[ "$alerts_count" == "0" ]]; then
  alog "Reporte limpio (0 alertas); no se requiere notificación."
  if [[ -n "$current_hash" ]]; then
    printf '%s\n' "$current_hash" >"$MARKER" 2>/dev/null || true
  fi
  exit 0
fi

TITLE="⚠ Process Status · ${alerts_count} anomalías detectadas"
BODY="${summary}"$'\n'"Pulsa para ver el informe o abrir el asistente de resolución."

actions=()
if notify-send --help 2>&1 | grep -q -- '--action'; then
  actions+=(--action=fix="🛠 Arreglar ahora" --action=details="📋 Ver informe")
fi

# Guardar marcador antes de ejecutar notify-send interactivo
if [[ -n "$current_hash" ]]; then
  printf '%s\n' "$current_hash" >"$MARKER" 2>/dev/null || true
fi

resp=""
if (( ${#actions[@]} > 0 )); then
  resp="$(notify-send -a 'Process Status' -u critical -t 0 -i dialog-warning \
    "${actions[@]}" "$TITLE" "$BODY" 2>/dev/null || true)"
else
  notify-send -a 'Process Status' -u critical -t 0 -i dialog-warning \
    "$TITLE" "$BODY" >/dev/null 2>&1 || true
fi
alog "Respuesta de la notificación: '${resp:-（ninguna）}'"

case "$resp" in
  fix)
    alog "Acción elegida: Arreglar ahora"
    if [[ -x "$OPEN_TERM_BIN" ]]; then
      "$OPEN_TERM_BIN" "$FIX_SCRIPT"
    else
      setsid konsole -e "$FIX_SCRIPT" >/dev/null 2>&1 &
    fi
    ;;
  details|default)
    alog "Acción elegida: Ver informe"
    if [[ -x "$OPEN_TERM_BIN" ]]; then
      "$OPEN_TERM_BIN" "$SHOW_SCRIPT"
    else
      setsid konsole -e "$SHOW_SCRIPT" >/dev/null 2>&1 &
    fi
    ;;
esac

exit 0
