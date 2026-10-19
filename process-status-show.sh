#!/usr/bin/env bash
# ==============================================================================
# process-status-show.sh — Visor del informe de estado de procesos y servicios
# Suite: Process Status · Cizen (v1.0.0)
# Espejo de: arch-show-pending.sh
# ==============================================================================
set -uo pipefail

STATE_DIR="${CIZEN_PS_STATE_DIR:-/var/cache/process-status}"
REPORT_FILE="${STATE_DIR}/report"

# v1.0.0: Localización de scripts auxiliares (soporta ejecución en repo o instalado)
BIN_DIR="/usr/local/bin/process-status"
if [[ ! -x "${BIN_DIR}/process-status-fix.sh" ]]; then
  BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

FIX_SCRIPT="${BIN_DIR}/process-status-fix.sh"
CHECKER_SCRIPT="${BIN_DIR}/process-status-checker.sh"

pause_final() {
  if [[ -n "${PS_AUTO_WINDOW:-${AUC_AUTO_WINDOW:-}}" ]]; then
    printf 'Pulsa Enter para cerrar… '
    read -r _
  else
    echo "✔ Visor finalizado. (Ejecución manual: tu terminal permanece abierta.)"
    printf 'Pulsa Enter para continuar… '
    read -r _
  fi
}

if [ -t 1 ]; then
  clear
fi

echo "───────────────────────────────────────────────────────"
echo " Process Status · Informe de Salud del Sistema"
echo "───────────────────────────────────────────────────────"
echo

if [[ -s "$REPORT_FILE" ]]; then
  cat "$REPORT_FILE"
  echo
  printf '¿Desea abrir el asistente de arreglo ahora? [S/n] '
  read -r r
  if [[ ! "$r" =~ ^[Nn] ]]; then
    if [[ -x "$FIX_SCRIPT" ]]; then
      exec env PS_ALREADY_SHOWN=1 PS_AUTO_WINDOW="${PS_AUTO_WINDOW:-${AUC_AUTO_WINDOW:-}}" "$FIX_SCRIPT"
    else
      echo "Error: Asistente de arreglo no encontrado en $FIX_SCRIPT" >&2
      pause_final
    fi
  fi
  pause_final
else
  echo "No se encontró ningún informe en ${REPORT_FILE} (o está vacío)."
  echo
  printf '¿Desea ejecutar el escáner de estado ahora? [S/n] '
  read -r r
  if [[ ! "$r" =~ ^[Nn] ]]; then
    if [[ -x "$CHECKER_SCRIPT" ]]; then
      if [[ ${EUID:-0} -ne 0 ]]; then
        sudo "$CHECKER_SCRIPT"
      else
        "$CHECKER_SCRIPT"
      fi
      if [[ -s "$REPORT_FILE" ]]; then
        echo
        cat "$REPORT_FILE"
        echo
        printf '¿Desea abrir el asistente de arreglo ahora? [S/n] '
        read -r rfix
        if [[ ! "$rfix" =~ ^[Nn] && -x "$FIX_SCRIPT" ]]; then
          exec env PS_ALREADY_SHOWN=1 PS_AUTO_WINDOW="${PS_AUTO_WINDOW:-${AUC_AUTO_WINDOW:-}}" "$FIX_SCRIPT"
        fi
      fi
    else
      echo "Error: Escáner no encontrado en $CHECKER_SCRIPT" >&2
    fi
  fi
  pause_final
fi
