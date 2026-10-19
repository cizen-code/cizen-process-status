#!/usr/bin/env bash
# ==============================================================================
# process-status-fix.sh — Asistente interactivo de resolución y mantenimiento
# Suite: Process Status · Cizen (v1.0.0)
# Espejo de: arch-apply-updates.sh
# ==============================================================================
set -uo pipefail

STATE_DIR="${CIZEN_PS_STATE_DIR:-/var/cache/process-status}"
REPORT_FILE="${STATE_DIR}/report"

# v1.0.0: Localización de scripts auxiliares
BIN_DIR="/usr/local/bin/process-status"
if [[ ! -x "${BIN_DIR}/process-status-checker.sh" ]]; then
  BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
CHECKER_SCRIPT="${BIN_DIR}/process-status-checker.sh"

# v1.0.0: Colores solo cuando la salida es interactiva
if [ -t 1 ]; then
  C=$'\033[1;36m'   # cian
  G=$'\033[0;32m'   # verde
  Y=$'\033[1;33m'   # amarillo
  R=$'\033[0;31m'   # rojo
  W=$'\033[1;37m'   # blanco negrita
  N=$'\033[0m'
else
  C=""; G=""; Y=""; R=""; W=""; N=""
fi

# v1.0.0: Helpers de visualización
log()   { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
ok()    { printf ' %b✓%b %s\n' "$G" "$N" "$*"; }
warn()  { printf ' %b⚠%b %s\n' "$Y" "$N" "$*"; }
err()   { printf ' %b✗%b %s\n' "$R" "$N" "$*" >&2; }
info()  { printf ' %b•%b %s\n' "$C" "$N" "$*"; }
gear()  { printf ' %b⚙%b %s\n' "$W" "$N" "$*"; }

# v1.0.0: Función de elevación segura de privilegios (fiel a arch-apply-updates.sh)
_priv() {
  if [[ ${EUID:-0} -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  elif [ -t 0 ]; then
    sudo "$@"
  else
    err "Sin privilegios root ni terminal para solicitar sudo: $*"
    return 1
  fi
}

pause_final() {
  if [[ -n "${PS_AUTO_WINDOW:-${AUC_AUTO_WINDOW:-}}" ]]; then
    read -r -p "Pulsa Enter para cerrar… " _
  else
    echo "✔ Asistente finalizado. (Ejecución manual: tu terminal permanece abierta.)"
    read -r -p "Pulsa Enter para continuar… " _
  fi
}

# v1.0.0: Protección: sin TTY jamás bloquea
if ! [ -t 0 ]; then
  err "Este asistente es interactivo y requiere una terminal interactiva (TTY)."
  exit 1
fi

if [ -t 1 ]; then
  clear
fi

echo "───────────────────────────────────────────────────────"
echo " Process Status · Asistente Interactivo de Resolución"
echo "───────────────────────────────────────────────────────"
echo

# ------------------------------------------------------------------------------
# 1. RESOLUCIÓN DE UNIDADES SYSTEMD FALLIDAS
# ------------------------------------------------------------------------------
echo "==> [1/5] Comprobando unidades systemd fallidas..."
failed_sys=()
while read -r u_unit _; do
  [[ -n "$u_unit" ]] && failed_sys+=("$u_unit")
done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')

if (( ${#failed_sys[@]} > 0 )); then
  warn "Se detectaron ${#failed_sys[@]} unidades fallidas del sistema:"
  for unit in "${failed_sys[@]}"; do
    echo "-------------------------------------------------------"
    printf '%b✗ Unidad: %s%b\n' "$R" "$unit" "$N"
    echo "Últimas líneas del registro (journalctl):"
    journalctl -u "$unit" -n 10 --no-pager 2>/dev/null || true
    echo
    read -r -p "¿Reiniciar unidad '${unit}'? [S/n] " ans
    if [[ ! "$ans" =~ ^[Nn] ]]; then
      gear "Reiniciando ${unit}..."
      if _priv systemctl restart "$unit"; then
        ok "Unidad ${unit} reiniciada."
      else
        err "Fallo al reiniciar ${unit}."
      fi
    fi
    read -r -p "¿Resetear estado de fallo (systemctl reset-failed '${unit}')? [S/n] " ans_reset
    if [[ ! "$ans_reset" =~ ^[Nn] ]]; then
      gear "Reseteando estado de fallo..."
      _priv systemctl reset-failed "$unit" && ok "Estado de fallo reseteado."
    fi
  done
else
  ok "No hay unidades de sistema fallidas."
fi

# Unidades fallidas de usuario
failed_usr=()
while read -r u_unit _; do
  [[ -n "$u_unit" ]] && failed_usr+=("$u_unit")
done < <(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}')

if (( ${#failed_usr[@]} > 0 )); then
  warn "Se detectaron ${#failed_usr[@]} unidades fallidas de usuario:"
  for unit in "${failed_usr[@]}"; do
    echo "-------------------------------------------------------"
    printf '%b✗ Unidad de usuario: %s%b\n' "$R" "$unit" "$N"
    journalctl --user-unit "$unit" -n 10 --no-pager 2>/dev/null || true
    echo
    read -r -p "¿Reiniciar unidad de usuario '${unit}'? [S/n] " ans
    if [[ ! "$ans" =~ ^[Nn] ]]; then
      systemctl --user restart "$unit" && ok "Unidad ${unit} reiniciada."
    fi
    read -r -p "¿Resetear estado de fallo de usuario? [S/n] " ans_reset
    if [[ ! "$ans_reset" =~ ^[Nn] ]]; then
      systemctl --user reset-failed "$unit" && ok "Estado reseteado."
    fi
  done
fi

# ------------------------------------------------------------------------------
# 2. RESOLUCIÓN DE PROCESOS ZOMBI (DEFUNCT)
# ------------------------------------------------------------------------------
echo
echo "==> [2/5] Comprobando procesos zombis (defunct)..."
zombie_pids=()
while read -r z_pid z_ppid z_stat z_comm; do
  [[ -n "$z_pid" ]] || continue
  if [[ "$z_stat" =~ ^Z || "$z_comm" =~ defunct ]]; then
    zombie_pids+=("${z_pid}:${z_ppid}:${z_comm}")
  fi
done < <(ps -eo pid,ppid,stat,comm --no-headers 2>/dev/null)

if (( ${#zombie_pids[@]} > 0 )); then
  warn "Se detectaron ${#zombie_pids[@]} procesos zombi:"
  for item in "${zombie_pids[@]}"; do
    IFS=":" read -r z_pid z_ppid z_comm <<< "$item"
    p_comm="$(ps -o comm= -p "$z_ppid" 2>/dev/null || echo "desconocido")"
    echo "-------------------------------------------------------"
    printf '  %b⚠ ZOMBI PID %s (%s)%b — Proceso padre: PID %s (%s)\n' "$Y" "$z_pid" "$z_comm" "$N" "$z_ppid" "$p_comm"
    info "Nota: Un proceso zombi ya murió; se mantiene en la tabla hasta que el padre llame a wait()."
    read -r -p "¿Enviar señal SIGCHLD al padre (PID ${z_ppid}) para forzar recogida? [S/n] " ans_chld
    if [[ ! "$ans_chld" =~ ^[Nn] ]]; then
      gear "Enviando SIGCHLD a PID ${z_ppid}..."
      if kill -CHLD "$z_ppid" 2>/dev/null || _priv kill -CHLD "$z_ppid"; then
        ok "Señal enviada al padre."
      else
        err "No se pudo enviar la señal al padre."
      fi
      sleep 1
      if ! ps -p "$z_pid" >/dev/null 2>&1; then
        ok "¡Proceso zombi limpiado con éxito!"
        continue
      fi
    fi

    # Si sigue vivo y el padre no es init (PID 1)
    if [[ "$z_ppid" -gt 1 ]]; then
      warn "El zombi sigue presente y el proceso padre (${z_ppid}: ${p_comm}) no responde."
      read -r -p "¿Desea terminar al proceso padre (${z_ppid}: ${p_comm}) con SIGTERM? [s/N] " ans_term
      if [[ "$ans_term" =~ ^[SsYy] ]]; then
        gear "Enviando SIGTERM a ${z_ppid}..."
        kill -TERM "$z_ppid" 2>/dev/null || _priv kill -TERM "$z_ppid"
      fi
    fi
  done
else
  ok "No se detectaron procesos zombis."
fi

# ------------------------------------------------------------------------------
# 3. PROCESOS CON BINARIOS BORRADOS EN DISCO
# ------------------------------------------------------------------------------
echo
echo "==> [3/5] Comprobando procesos ejecutando binarios borrados (post-actualización)..."
deleted_pids=()
for p in /proc/[0-9]*/exe; do
  [[ -e "$p" ]] || continue
  target="$(readlink "$p" 2>/dev/null || true)"
  if [[ "$target" =~ \(deleted\)$ ]]; then
    pid="$(basename "$(dirname "$p")")"
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | xargs || echo "-")"
    user="$(ps -o user= -p "$pid" 2>/dev/null | xargs || echo "-")"
    deleted_pids+=("${pid}:${user}:${comm}:${target}")
  fi
done

if (( ${#deleted_pids[@]} > 0 )); then
  warn "Se detectaron ${#deleted_pids[@]} procesos con binarios reemplazados en disco:"
  for item in "${deleted_pids[@]}"; do
    IFS=":" read -r d_pid d_user d_comm d_target <<< "$item"
    printf '  · PID %s (%s) [%s] -> %s\n' "$d_pid" "$d_user" "$d_comm" "$d_target"
    read -r -p "¿Enviar señal SIGTERM a PID ${d_pid} (${d_comm}) para recargarlo? [s/N] " ans_del
    if [[ "$ans_del" =~ ^[SsYy] ]]; then
      gear "Enviando SIGTERM a PID ${d_pid}..."
      if kill -TERM "$d_pid" 2>/dev/null || _priv kill -TERM "$d_pid"; then
        ok "Señal SIGTERM enviada a ${d_pid}."
      else
        err "No se pudo terminar el proceso ${d_pid}."
      fi
    fi
  done
else
  ok "Ningún proceso ejecutando binarios obsoletos en disco."
fi

# ------------------------------------------------------------------------------
# 4. LIMPIEZA DE COREDUMPS DEL SISTEMA
# ------------------------------------------------------------------------------
echo
echo "==> [4/5] Comprobando volcados de memoria (coredumpctl)..."
if command -v coredumpctl >/dev/null 2>&1; then
  cd_count="$(coredumpctl list --no-legend 2>/dev/null | wc -l)"
  if (( cd_count > 0 )); then
    info "Hay ${cd_count} volcados de memoria (coredumps) registrados."
    read -r -p "¿Ejecutar 'coredumpctl vacuum' para purgar coredumps antiguos? [s/N] " ans_cd
    if [[ "$ans_cd" =~ ^[SsYy] ]]; then
      gear "Purgando coredumps..."
      _priv coredumpctl vacuum && ok "Coredumps purgados."
    fi
  else
    ok "Sin volcados de memoria acumulados."
  fi
fi

# ------------------------------------------------------------------------------
# 5. ACTUALIZACIÓN DEL INFORME
# ------------------------------------------------------------------------------
echo
echo "==> [5/5] Re-escaneo del sistema..."
read -r -p "¿Desea ejecutar el escáner de estado ahora para refrescar el informe? [S/n] " ans_scan
if [[ ! "$ans_scan" =~ ^[Nn] ]]; then
  if [[ -x "$CHECKER_SCRIPT" ]]; then
    gear "Ejecutando escáner de estado..."
    _priv "$CHECKER_SCRIPT" --force
    ok "Informe de estado actualizado en ${REPORT_FILE}."
  fi
fi

echo
pause_final
