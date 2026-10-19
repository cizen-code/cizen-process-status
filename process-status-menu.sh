#!/usr/bin/env bash
# ==============================================================================
# process-status-menu.sh — Menú interactivo de la suite Process Status
# Suite: Process Status · Cizen (v1.0.0)
# Espejo de: kernel-update-menu.sh
# ==============================================================================
set -uo pipefail

STATE_DIR="${CIZEN_PS_STATE_DIR:-/var/cache/process-status}"
REPORT_FILE="${STATE_DIR}/report"
SCRIPT_VERSION="1.0.0"

# v1.0.0: Directorio de binarios de la suite (soporta ejecución en repo o instalado)
BIN_DIR="/usr/local/bin/process-status"
if [[ ! -x "${BIN_DIR}/process-status-checker.sh" ]]; then
  BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

CHECKER_SCRIPT="${BIN_DIR}/process-status-checker.sh"
SHOW_SCRIPT="${BIN_DIR}/process-status-show.sh"
FIX_SCRIPT="${BIN_DIR}/process-status-fix.sh"

# v1.0.0: Colores (solo en terminal interactiva)
if [ -t 1 ]; then
  C=$'\033[1;36m'   # números
  G=$'\033[0;32m'   # ok / verde
  Y=$'\033[1;33m'   # amarillo / aviso
  R=$'\033[0;31m'   # rojo / error
  H=$'\033[1m'      # negrita
  W=$'\033[1;37m'   # blanco + negrita
  N=$'\033[0m'
else
  C=""; G=""; Y=""; R=""; H=""; W=""; N=""
fi

# v1.0.0: Elevación segura
_priv() {
  if [[ ${EUID:-0} -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  elif [ -t 0 ]; then
    sudo "$@"
  else
    "$@"
  fi
}

# v1.0.0: Regla separadora de 55 guiones y formato hrow
RULE="$(printf '%*s' 55 '' | tr ' ' '-')"
rule() { printf '%s\n' "$RULE"; }
hrow() {
  local left_vis pad
  left_vis="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')"
  pad=$(( 24 - ${#left_vis} )); [ "$pad" -lt 0 ] && pad=0
  printf '    %s%b%*s%b   |   %s\n' "$1" "$N" "$pad" '' "$N" "$2"
}

opt() { # $1=número $2=nombre $3=descripción
  printf '%b%5s%b)  %-13s %s\n' "$C" "$1" "$N" "$2" "$3"
}

# v1.0.0: Obtiene el resumen del estado para el encabezado
get_status_summary() {
  local alerts="0" failed="0" zomb="0"
  if [[ -s "$REPORT_FILE" ]]; then
    alerts="$(grep -oE 'Alertas: [0-9]+' "$REPORT_FILE" 2>/dev/null | awk '{print $2}' || echo "0")"
    failed="$(grep -oE 'Fallidas: [0-9]+' "$REPORT_FILE" 2>/dev/null | awk '{print $2}' || echo "0")"
    zomb="$(grep -oE 'Zombis: [0-9]+' "$REPORT_FILE" 2>/dev/null | awk '{print $2}' || echo "0")"
  fi
  if [[ "$alerts" != "0" || "$failed" != "0" ]]; then
    printf '%b%s alertas (%s fallidas, %s zombis)%b' "$Y" "$alerts" "$failed" "$zomb" "$N"
  else
    printf '%bÓptimo / Saludable%b' "$G" "$N"
  fi
}

draw_menu() {
  if [ -t 1 ]; then
    clear
  fi
  rule
  hrow "${W}●  Process Status · Cizen${N}" "${G}Motor${N} v${SCRIPT_VERSION}"
  rule
  hrow "${W}Estado${N}  $(get_status_summary)" "${G}Host${N}   $(uname -n)"
  rule

  echo "  ${W}Diagnóstico y Acciones${N}"
  opt 1 "scan"       "ejecutar escáner root (actualizar informe)"
  opt 2 "report"     "ver informe completo de estado"
  opt 3 "fix"        "asistente interactivo de resolución"
  rule

  echo "  ${W}Vistas Específicas${N}"
  opt 4 "failed"     "inspeccionar unidades fallidas y registros"
  opt 5 "zombies"    "procesos zombis, huérfanos y en segundo plano"
  opt 6 "resources"  "monitor de recursos (CPU, RAM, Swap y carga)"
  opt 7 "timers"     "ver temporizadores (timers) del sistema"
  opt 8 "journal"    "errores críticos y segfaults en journal"
  rule

  echo "  ${W}Mantenimiento de la Suite${N}"
  opt 9 "service"    "estado de servicios y timer horario systemd"
  opt 10 "selftest"  "autoevaluación de la suite con datos sintéticos"
  opt 0 "salir"      "salir al intérprete de comandos"
  rule
}

draw_menu

while true; do
  read -r -p "${W}  [0-10] > ${N}" choice || break
  case "$choice" in
    1)
      echo
      echo "==> Ejecutando escáner de estado..."
      _priv "$CHECKER_SCRIPT" --force
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    2)
      if [[ -x "$SHOW_SCRIPT" ]]; then
        "$SHOW_SCRIPT"
      else
        "$CHECKER_SCRIPT" --stdout
        read -r -p "Pulsa Enter para volver al menú… " _
      fi
      draw_menu
      ;;
    3)
      if [[ -x "$FIX_SCRIPT" ]]; then
        "$FIX_SCRIPT"
      fi
      draw_menu
      ;;
    4)
      echo
      echo "==> Unidades systemd en estado fallido:"
      systemctl --failed --plain --no-legend 2>/dev/null || true
      systemctl --user --failed --plain --no-legend 2>/dev/null || true
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    5)
      echo
      echo "==> Procesos zombis (defunct):"
      ps -eo pid,ppid,user,stat,comm --no-headers | awk '$4 ~ /^Z/ {print $0}'
      echo
      echo "==> Procesos con binarios borrados (deleted):"
      for p in /proc/[0-9]*/exe; do
        [[ -e "$p" ]] || continue
        t="$(readlink "$p" 2>/dev/null || true)"
        [[ "$t" =~ \(deleted\)$ ]] && echo "  PID $(basename "$(dirname "$p")"): $t"
      done
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    6)
      echo
      echo "==> Carga del sistema y uso de recursos:"
      uptime
      echo
      free -h
      echo
      echo "==> Top 5 procesos por CPU:"
      ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 6
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    7)
      echo
      echo "==> Próximos temporizadores (timers) de systemd:"
      systemctl list-timers --no-pager
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    8)
      echo
      echo "==> Segfaults y OOM kills en este arranque:"
      journalctl -b -p 0..3 --no-pager -n 25 2>/dev/null || true
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    9)
      echo
      echo "==> Estado del servicio y timer systemd:"
      systemctl status process-status-checker.service process-status-checker.timer --no-pager 2>/dev/null || true
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    10)
      echo
      "$CHECKER_SCRIPT" --selftest
      echo
      read -r -p "Pulsa Enter para volver al menú… " _
      draw_menu
      ;;
    0)
      echo "  Saliendo."
      exit 0
      ;;
    *)
      printf '  %bOpción no válida: %s%b\n' "$R" "$choice" "$N"
      ;;
  esac
done
