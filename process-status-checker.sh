#!/usr/bin/env bash
# ==============================================================================
# process-status-checker.sh — Motor y escáner de estado de procesos y servicios
# Suite: Process Status · Cizen (v1.0.0)
#
# Escanea:
# 1. Unidades systemd fallidas (sistema + usuarios activos) con reinicios y timestamp
# 2. Conteo y resumen de unidades activas
# 3. Unidades no activas (habilitadas que no están en ejecución)
# 4. Unidades enmascaradas y not-found
# 5. Próximos disparos de timers
# 6. Procesos zombi (Z/defunct) con detalle de padre y tiempo
# 7. Procesos huérfanos reales (descartando servicios legítimos de systemd vía cgroup)
# 8. Procesos de usuario en segundo plano sin terminal de control (sin TTY)
# 9. Procesos bloqueados en D-state (posible I/O hang)
# 10. Procesos con binarios borrados en disco (post-actualización de paquetes)
# 11. Top 5 consumo de CPU y RAM
# 12. Fallos de sistema desde arranque (segfaults, OOM kills, coredumps)
# 13. Recursos globales (carga vs núcleos, RAM, Swap) y alertas agregadas
#
# Escribe en /var/cache/process-status/report y notifica si hay alertas o cambios.
# ==============================================================================
set -uo pipefail

# v1.0.0: Directorios de estado y configuración
STATE_DIR="${CIZEN_PS_STATE_DIR:-/var/cache/process-status}"
REPORT_FILE="${STATE_DIR}/report"
HASH_FILE="${STATE_DIR}/hash"
LOCK_FILE="${STATE_DIR}/checker.lock"
SCRIPT_VERSION="1.0.0"

# v1.0.0: Colores solo cuando salida es interactiva
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

# v1.0.0: Helpers de registro y diagnóstico
log()   { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
ok()    { printf ' %b✓%b %s\n' "$G" "$N" "$*"; }
warn()  { printf ' %b⚠%b %s\n' "$Y" "$N" "$*"; }
err()   { printf ' %b✗%b %s\n' "$R" "$N" "$*" >&2; }
info()  { printf ' %b•%b %s\n' "$C" "$N" "$*"; }
gear()  { printf ' %b⚙%b %s\n' "$W" "$N" "$*"; }

# v1.0.0: Whitelist de daemons de sistema legítimos que pueden correr bajo PPID=1
DAEMON_WHITELIST=(
  systemd
  systemd-journald
  systemd-udevd
  systemd-logind
  systemd-resolved
  systemd-timesyncd
  systemd-oomd
  systemd-bootstatus
  dbus-broker
  dbus-broker-launch
  dbus-daemon
  polkitd
  rtkit-daemon
  pipewire
  pipewire-pulse
  wireplumber
  i3
  sway
  kwin_wayland
  kwin_x11
  plasmashell
  gnome-shell
  Xorg
  Xwayland
  sddm
  lightdm
  gdm
  sshd
  crond
  cron
  atd
  auditd
  irqbalance
  acpid
  cupsd
  NetworkManager
  wpa_supplicant
  iwd
  bluetoothd
  thermald
  power-profiles-daemon
  haveged
  rngd
)

# v1.0.0: Comprueba si un comando está en la lista blanca de daemons
is_whitelisted_daemon() {
  local comm="$1" base
  base="$(basename "$comm")"
  for d in "${DAEMON_WHITELIST[@]}"; do
    if [[ "$base" == "$d" || "$base" == "$d.exe" ]]; then
      return 0
    fi
  done
  return 1
}

# v1.0.0: Comprueba si un cgroup pertenece a un servicio/slice de systemd legítimo
is_systemd_service_cgroup() {
  local cg="$1"
  if [[ "$cg" =~ \.service || "$cg" =~ system\.slice || "$cg" =~ init\.scope ]]; then
    return 0
  fi
  return 1
}

# v1.0.0: Clasificador de huérfanos (procesable en función pura para --selftest)
# Entrada: pid ppid user cgroup comm
classify_orphan() {
  local pid="$1" ppid="$2" user="$3" cgroup="$4" comm="$5"
  # Un proceso huérfano tiene PPID 1 (o re-parented) y NO es kernel thread
  if [[ "$ppid" -ne 1 && "$ppid" -ne 0 ]]; then
    return 1
  fi
  if [[ "$comm" =~ ^\[.*\]$ ]]; then
    return 1 # Kernel thread
  fi
  # Si pertenece a un servicio systemd legítimo, no es huérfano descolgado
  if is_systemd_service_cgroup "$cgroup"; then
    return 1
  fi
  # Si está en whitelist de daemons conocidos, no es un huérfano abandonado
  if is_whitelisted_daemon "$comm"; then
    return 1
  fi
  return 0
}

# v1.0.0: Clasificador de zombis (función pura para --selftest)
# Entrada: stat
is_zombie_stat() {
  local stat="$1"
  if [[ "$stat" =~ ^Z || "$stat" =~ defunct ]]; then
    return 0
  fi
  return 1
}

# v1.0.0: Clasificador de procesos bloqueados en D (uninterruptible sleep)
is_dstate_stat() {
  local stat="$1"
  if [[ "$stat" =~ ^D ]]; then
    return 0
  fi
  return 1
}

# v1.0.0: Notificación a usuarios de escritorio mediante process-status-notify-agent.sh
notify_users() {
  local hash="$1"
  command -v runuser >/dev/null 2>&1 || return 0
  local agent_bin="/usr/local/bin/process-status/process-status-notify-agent.sh"
  [[ -x "$agent_bin" ]] || agent_bin="$(dirname "$0")/process-status-notify-agent.sh"
  [[ -x "$agent_bin" ]] || return 0

  local uid user bus home sid leader line dpy wdisp desk
  while read -r uid user; do
    [[ "$uid" =~ ^[0-9]+$ && -n "$user" ]] || continue
    (( uid >= 1000 && uid < 65000 )) || continue
    bus="/run/user/${uid}/bus"
    [[ -S "$bus" ]] || continue
    home="$(getent passwd "$user" | cut -d: -f6)"
    [[ -n "$home" ]] || continue

    dpy=""; wdisp=""; desk=""
    sid="$(loginctl show-user "$user" --property=Display --value 2>/dev/null || true)"
    if [[ -n "$sid" ]]; then
      leader="$(loginctl show-session "$sid" --property=Leader --value 2>/dev/null || true)"
      if [[ -n "$leader" && -r "/proc/$leader/environ" ]]; then
        while IFS= read -r line; do
          case "$line" in
            DISPLAY=*) dpy="${line#DISPLAY=}" ;;
            WAYLAND_DISPLAY=*) wdisp="${line#WAYLAND_DISPLAY=}" ;;
            XDG_CURRENT_DESKTOP=*) desk="${line#XDG_CURRENT_DESKTOP=}" ;;
          esac
        done < <(tr '\0' '\n' < "/proc/$leader/environ" 2>/dev/null)
      fi
    fi

    local -a extra=()
    [[ -n "$dpy" ]] && extra+=(DISPLAY="$dpy")
    [[ -n "$wdisp" ]] && extra+=(WAYLAND_DISPLAY="$wdisp")
    [[ -n "$desk" ]] && extra+=(XDG_CURRENT_DESKTOP="$desk")

    runuser -u "$user" -- env \
      HOME="$home" \
      XDG_RUNTIME_DIR="/run/user/${uid}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
      "${extra[@]}" \
      setsid nohup "$agent_bin" >/dev/null 2>&1 &
  done < <(loginctl list-users --no-legend 2>/dev/null | awk '{print $1, $2}')
}

# ==============================================================================
# v1.0.0: Modo Selftest (comprobación interna sintética)
# ==============================================================================
run_selftest() {
  printf '%b● Selftest · Process Status Suite (v%s)%b\n' "$W" "$SCRIPT_VERSION" "$N"
  local errors=0

  # 1. Test clasificador zombis
  if is_zombie_stat "Z" && is_zombie_stat "Z+" && is_zombie_stat "defunct"; then
    ok "Detección de estados Z / defunct"
  else
    err "Fallo detectando estados zombi"
    ((errors++))
  fi

  if ! is_zombie_stat "S" && ! is_zombie_stat "R" && ! is_zombie_stat "D"; then
    ok "Descarte de estados no zombis (S, R, D)"
  else
    err "Falso positivo en detección de zombis"
    ((errors++))
  fi

  # 2. Test clasificador huérfanos vs servicios y whitelist
  # Caso A: Proceso con PPID=1 dentro de un .service -> NO huérfano descolgado
  if ! classify_orphan 1234 1 root "/system.slice/sshd.service" "sshd"; then
    ok "Huérfanos: servicio en system.slice correctamente filtrado"
  else
    err "Huérfanos: servicio legítimo detectado como falso huérfano"
    ((errors++))
  fi

  # Caso B: Proceso en whitelist (ej. dbus-broker) con PPID 1 -> NO huérfano
  if ! classify_orphan 567 1 messagebus "/user.slice/foo" "dbus-broker"; then
    ok "Huérfanos: daemon en whitelist filtrado correctamente"
  else
    err "Huérfanos: daemon en whitelist marcado erróneamente como huérfano"
    ((errors++))
  fi

  # Caso C: Kernel thread [kworker/0:0] -> NO huérfano
  if ! classify_orphan 89 0 root "/" "[kworker/0:0]"; then
    ok "Huérfanos: kernel thread filtrado correctamente"
  else
    err "Huérfanos: kernel thread detectado erróneamente"
    ((errors++))
  fi

  # Caso D: Proceso abandonado de usuario con PPID=1 fuera de .service (ej. sleep descolgado) -> SÍ es huérfano
  if classify_orphan 9999 1 cizen "/user.slice/user-1000.slice/session-2.scope" "sleep"; then
    ok "Huérfanos: proceso de usuario abandonado detectado correctamente"
  else
    err "Huérfanos: fallo detectando proceso huérfano real"
    ((errors++))
  fi

  # 3. Test clasificador D-state
  if is_dstate_stat "D" && is_dstate_stat "D+" && ! is_dstate_stat "S"; then
    ok "D-State: clasificación de uninterruptible sleep correcta"
  else
    err "D-State: fallo en clasificación de D-state"
    ((errors++))
  fi

  # 4. Verificación de comandos del sistema
  local -a req_cmds=(systemctl ps awk sed grep date cut tr wc)
  local missing=0
  for cmd in "${req_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Comando recomendado no encontrado: $cmd"
      ((missing++))
    fi
  done
  if (( missing == 0 )); then
    ok "Dependencias básicas del sistema presentes (${#req_cmds[@]}/${#req_cmds[@]})"
  fi

  if (( errors == 0 )); then
    printf '\n%b✔ Selftest completado con éxito: todos los tests pasaron.%b\n' "$G" "$N"
    return 0
  else
    printf '\n%b✗ Selftest finalizó con %d errores.%b\n' "$R" "$errors" "$N"
    return 1
  fi
}

# ==============================================================================
# v1.0.0: Recolección y formateo de datos del sistema
# ==============================================================================

# Parseo de opciones
OPT_STDOUT=0
OPT_FORCE=0
for arg in "$@"; do
  case "$arg" in
    --selftest)
      run_selftest
      exit $?
      ;;
    --stdout)
      OPT_STDOUT=1
      ;;
    --force)
      OPT_FORCE=1
      ;;
    --help|-h)
      echo "Uso: $0 [--selftest] [--stdout] [--force]"
      exit 0
      ;;
  esac
done

# Verificación de privilegios root para escaneo en disco
if [[ ${EUID:-0} -ne 0 && $OPT_STDOUT -eq 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  else
    log "Este script debe ejecutarse como root para auditar el sistema completo."
    exit 1
  fi
fi

# Creación de directorio de estado y flock para concurrencia
if [[ $OPT_STDOUT -eq 0 ]]; then
  mkdir -p "$STATE_DIR"
  chmod 755 "$STATE_DIR"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Otra comprobación de process-status está en curso; se omite esta ejecución."
    exit 0
  fi
fi

# Variables de conteo y acumulación de alertas
ALERT_LIST=()
COUNT_FAILED=0
COUNT_ZOMBIES=0
COUNT_ORPHANS=0
COUNT_DSTATE=0
COUNT_DELETED=0
COUNT_CRIT_RES=0

# ------------------------------------------------------------------------------
# 13. RECURSOS DEL SISTEMA (Se calculan primero para alimentar las alertas superiores)
# ------------------------------------------------------------------------------
SEC_RECURSOS=""
n_cpus="$(nproc 2>/dev/null || echo 1)"
load_1="0"; load_5="0"; load_15="0"
if [[ -r /proc/loadavg ]]; then
  read -r load_1 load_5 load_15 _ < /proc/loadavg
fi

# Memoria RAM
mem_total=0; mem_avail=0; mem_used=0; mem_pct=0
if [[ -r /proc/meminfo ]]; then
  mem_total="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  mem_avail="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
  if (( mem_total > 0 )); then
    mem_used=$(( mem_total - mem_avail ))
    mem_pct=$(( (mem_used * 100) / mem_total ))
  fi
fi

# Memoria Swap
swap_total=0; swap_free=0; swap_used=0; swap_pct=0
if [[ -r /proc/meminfo ]]; then
  swap_total="$(awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo)"
  swap_free="$(awk '/SwapFree:/ {print int($2/1024)}' /proc/meminfo)"
  if (( swap_total > 0 )); then
    swap_used=$(( swap_total - swap_free ))
    swap_pct=$(( (swap_used * 100) / swap_total ))
  fi
fi

# Evaluación de umbrales
load_1_int="${load_1%%.*}"
load_1_int="${load_1_int:-0}"
if (( load_1_int >= (n_cpus * 2) )); then
  ALERT_LIST+=("CRÍTICO: Carga de CPU muy alta (${load_1} vs ${n_cpus} núcleos)")
  ((COUNT_CRIT_RES++))
elif (( load_1_int >= n_cpus )); then
  ALERT_LIST+=("AVISO: Carga de CPU moderada/alta (${load_1} vs ${n_cpus} núcleos)")
fi

if (( mem_pct >= 95 )); then
  ALERT_LIST+=("CRÍTICO: Memoria RAM casi agotada (${mem_pct}%% - ${mem_used}M / ${mem_total}M)")
  ((COUNT_CRIT_RES++))
elif (( mem_pct >= 85 )); then
  ALERT_LIST+=("AVISO: Uso elevado de memoria RAM (${mem_pct}%% - ${mem_used}M / ${mem_total}M)")
fi

if (( swap_pct >= 80 )); then
  ALERT_LIST+=("CRÍTICO: Swap al ${swap_pct}%% (${swap_used}M / ${swap_total}M)")
  ((COUNT_CRIT_RES++))
elif (( swap_pct >= 50 )); then
  ALERT_LIST+=("AVISO: Uso considerable de Swap (${swap_pct}%% - ${swap_used}M / ${swap_total}M)")
fi

root_disk_info="$(df -h / 2>/dev/null | awk 'NR==2 {print "Uso: "$5" | Disponible: "$4" de "$2}')"

SEC_RECURSOS=$(cat <<EOF
Carga CPU (1m, 5m, 15m): ${load_1}, ${load_5}, ${load_15} (Núcleos detectados: ${n_cpus})
Memoria RAM: ${mem_used} MiB usados / ${mem_total} MiB totales (${mem_pct}%) [Disponible: ${mem_avail} MiB]
Memoria Swap: ${swap_used} MiB usados / ${swap_total} MiB totales (${swap_pct}%)
Almacenamiento raíz (/): ${root_disk_info}
EOF
)

# ------------------------------------------------------------------------------
# 1. UNIDADES SYSTEMD FALLIDAS (Sistema + Usuarios)
# ------------------------------------------------------------------------------
SEC_FAILED=""
failed_system="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1, $2, $3, $4}')"
if [[ -n "$failed_system" ]]; then
  while read -r u_unit u_load u_active u_sub; do
    [[ -n "$u_unit" ]] || continue
    ((COUNT_FAILED++))
    restarts="$(systemctl show "$u_unit" -p NRestarts --value 2>/dev/null || echo "0")"
    since="$(systemctl show "$u_unit" -p ActiveEnterTimestamp --value 2>/dev/null || echo "-")"
    SEC_FAILED+=$'  ✗ '"${u_unit} (${u_active}/${u_sub}) | Reinicios: ${restarts} | Desde: ${since}"$'\n'
    SEC_FAILED+="    ↳ Sugerencia: systemctl status ${u_unit}"$'\n'
  done <<< "$failed_system"
fi

# Unidades de usuario fallidas
while read -r u_uid u_user; do
  [[ "$u_uid" =~ ^[0-9]+$ ]] || continue
  (( u_uid >= 1000 && u_uid < 65000 )) || continue
  [[ -S "/run/user/${u_uid}/bus" ]] || continue
  u_failed="$(runuser -u "$u_user" -- systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1, $2, $3, $4}')"
  if [[ -n "$u_failed" ]]; then
    while read -r uu_unit uu_load uu_active uu_sub; do
      [[ -n "$uu_unit" ]] || continue
      ((COUNT_FAILED++))
      u_restarts="$(runuser -u "$u_user" -- systemctl --user show "$uu_unit" -p NRestarts --value 2>/dev/null || echo "0")"
      SEC_FAILED+=$'  ✗ [usuario: '"${u_user}] ${uu_unit} (${uu_active}/${uu_sub}) | Reinicios: ${u_restarts}"$'\n'
      SEC_FAILED+="    ↳ Sugerencia: systemctl --user status ${uu_unit}"$'\n'
    done <<< "$u_failed"
  fi
done < <(loginctl list-users --no-legend 2>/dev/null | awk '{print $1, $2}')

if (( COUNT_FAILED > 0 )); then
  ALERT_LIST+=("CRÍTICO: ${COUNT_FAILED} unidades systemd fallidas detectadas")
else
  SEC_FAILED="  ✓ Ninguna unidad systemd en estado fallido."
fi

# ------------------------------------------------------------------------------
# 2. UNIDADES SYSTEMD ACTIVAS
# ------------------------------------------------------------------------------
count_active="$(systemctl list-units --state=active --no-legend 2>/dev/null | wc -l)"
count_act_services="$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | wc -l)"
count_act_sockets="$(systemctl list-units --type=socket --state=active --no-legend 2>/dev/null | wc -l)"
count_act_timers="$(systemctl list-units --type=timer --state=active --no-legend 2>/dev/null | wc -l)"
count_act_targets="$(systemctl list-units --type=target --state=active --no-legend 2>/dev/null | wc -l)"

SEC_ACTIVAS=$(cat <<EOF
Total unidades activas: ${count_active}
Desglose: ${count_act_services} servicios, ${count_act_sockets} sockets, ${count_act_timers} temporizadores, ${count_act_targets} targets
EOF
)

# ------------------------------------------------------------------------------
# 3. UNIDADES NO ACTIVAS (Habilitadas pero inactivas / paradas)
# ------------------------------------------------------------------------------
SEC_NO_ACTIVAS=""
inactive_enabled=""
# Lista servicios habilitados y comprueba si están inactivos (excluyendo oneshot finalizados con éxito)
while read -r s_file _ s_state; do
  [[ "$s_file" =~ \.service$ ]] || continue
  # Comprobar tipo y estado
  s_active="$(systemctl is-active "$s_file" 2>/dev/null || echo "inactive")"
  if [[ "$s_active" == "inactive" || "$s_active" == "failed" ]]; then
    s_type="$(systemctl show "$s_file" -p Type --value 2>/dev/null || echo "simple")"
    if [[ "$s_type" != "oneshot" ]]; then
      inactive_enabled+=$'  • '"${s_file} (habilitado en arranque, pero actualmente inactivo)"$'\n'
    fi
  fi
done < <(systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null)

if [[ -n "$inactive_enabled" ]]; then
  SEC_NO_ACTIVAS="${inactive_enabled}"
else
  SEC_NO_ACTIVAS="  ✓ Todos los servicios habilitados de tipo persistente están activos."
fi

# ------------------------------------------------------------------------------
# 4. UNIDADES ENMASCARADAS Y NOT-FOUND
# ------------------------------------------------------------------------------
SEC_MASKED=""
masked_list="$(systemctl list-unit-files --state=masked --no-legend 2>/dev/null | awk '{print $1}')"
if [[ -n "$masked_list" ]]; then
  while read -r m_unit; do
    [[ -n "$m_unit" ]] || continue
    SEC_MASKED+=$'  · '"${m_unit} [enmascarada]"$'\n'
  done <<< "$masked_list"
else
  SEC_MASKED="  ✓ Ninguna unidad enmascarada."
fi

not_found_list="$(systemctl list-units --all --no-legend 2>/dev/null | awk '$2=="not-found" {print $1}')"
if [[ -n "$not_found_list" ]]; then
  SEC_MASKED+=$'\nUnidades referenciadas no encontradas (not-found):'$'\n'
  while read -r nf_unit; do
    [[ -n "$nf_unit" ]] || continue
    SEC_MASKED+=$'  ⚠ '"${nf_unit}"$'\n'
  done <<< "$not_found_list"
fi

# ------------------------------------------------------------------------------
# 5. TIMERS (Próximos disparos de timers de sistema y usuario)
# ------------------------------------------------------------------------------
SEC_TIMERS=""
timers_sys="$(systemctl list-timers --no-legend --no-pager 2>/dev/null | head -n 8 | awk '{
  if (NF >= 6) {
    unit = $(NF-1)
    printf "  · %-35s Próximo: %s %s (en %s)\n", unit, $1, $2, $3
  }
}')"
if [[ -n "$timers_sys" ]]; then
  SEC_TIMERS+=$'Próximos disparos de temporizadores (Sistema):'$'\n'"${timers_sys}"$'\n'
else
  SEC_TIMERS="  ✓ No hay temporizadores activos."
fi

# ------------------------------------------------------------------------------
# 6. PROCESOS ZOMBI (Z / defunct)
# ------------------------------------------------------------------------------
SEC_ZOMBIES=""
while read -r z_pid z_ppid z_user z_stat z_comm; do
  [[ -n "$z_pid" ]] || continue
  if is_zombie_stat "$z_stat"; then
    ((COUNT_ZOMBIES++))
    z_etime="$(ps -o etime= -p "$z_pid" 2>/dev/null | xargs || echo "-")"
    p_comm="$(ps -o comm= -p "$z_ppid" 2>/dev/null || cat "/proc/$z_ppid/comm" 2>/dev/null || echo "desconocido")"
    SEC_ZOMBIES+=$'  ⚠ ZOMBI PID: '"${z_pid} | Usuario: ${z_user} | Antigüedad: ${z_etime} | Comando: ${z_comm}"$'\n'
    SEC_ZOMBIES+="    ↳ Padre PID: ${z_ppid} (${p_comm}) — No ha invocado wait()"$'\n'
  fi
done < <(ps -eo pid,ppid,user,stat,comm --no-headers 2>/dev/null)

if (( COUNT_ZOMBIES > 0 )); then
  ALERT_LIST+=("AVISO: ${COUNT_ZOMBIES} procesos zombi (defunct) detectados")
else
  SEC_ZOMBIES="  ✓ Sin procesos zombis en el sistema."
fi

# ------------------------------------------------------------------------------
# 7. PROCESOS HUÉRFANOS (PPID=1 fuera de servicios systemd y whitelist)
# ------------------------------------------------------------------------------
SEC_ORPHANS=""
while read -r o_pid o_ppid o_user o_stat o_comm; do
  [[ -n "$o_pid" ]] || continue
  if [[ "$o_ppid" -eq 1 && ! "$o_stat" =~ ^Z ]]; then
    o_cgroup="$(cat "/proc/${o_pid}/cgroup" 2>/dev/null | tail -n 1 || echo "")"
    if classify_orphan "$o_pid" "$o_ppid" "$o_user" "$o_cgroup" "$o_comm"; then
      ((COUNT_ORPHANS++))
      o_args="$(ps -o args= -p "$o_pid" 2>/dev/null | cut -c 1-80 || echo "$o_comm")"
      SEC_ORPHANS+=$'  • PID: '"${o_pid} | Usuario: ${o_user} | Comando: ${o_args}"$'\n'
      SEC_ORPHANS+="    ↳ Cgroup: ${o_cgroup}"$'\n'
    fi
  fi
done < <(ps -eo pid,ppid,user,stat,comm --no-headers 2>/dev/null)

if (( COUNT_ORPHANS > 0 )); then
  ALERT_LIST+=("INFO: ${COUNT_ORPHANS} procesos huérfanos re-parented a PID 1 fuera de systemd")
else
  SEC_ORPHANS="  ✓ Ningún proceso huérfano fuera de los servicios y daemons legítimos."
fi

# ------------------------------------------------------------------------------
# 8. PROCESOS DE USUARIO EN SEGUNDO PLANO SIN TTY
# ------------------------------------------------------------------------------
SEC_BACKGROUND=""
bg_count=0
while read -r b_pid b_uid b_user b_stat b_tty b_comm; do
  [[ -n "$b_pid" && "$b_uid" =~ ^[0-9]+$ ]] || continue
  if (( b_uid >= 1000 && b_uid < 65000 )) && [[ "$b_tty" == "?" ]]; then
    # Filtrar procesos habituales de interfaz desktop de whitelist si se desea
    if ! is_whitelisted_daemon "$b_comm"; then
      b_cg="$(cat "/proc/${b_pid}/cgroup" 2>/dev/null | tail -n 1 || echo "-")"
      if (( bg_count < 10 )); then
        SEC_BACKGROUND+=$'  · PID: '"${b_pid} (${b_user}) [${b_stat}]: ${b_comm}"$'\n'
        SEC_BACKGROUND+="    ↳ Cgroup: ${b_cg}"$'\n'
      fi
      ((bg_count++))
    fi
  fi
done < <(ps -eo pid,uid,user,stat,tty,comm --no-headers 2>/dev/null)

if (( bg_count > 10 )); then
  SEC_BACKGROUND+="  ... y $((bg_count - 10)) procesos más de usuario en segundo plano."$'\n'
fi
[[ -z "$SEC_BACKGROUND" ]] && SEC_BACKGROUND="  ✓ No hay procesos de usuario desatendidos sin TTY fuera de servicios."


# ------------------------------------------------------------------------------
# 9. PROCESOS BLOQUEADOS EN D-STATE (Uninterruptible Sleep / IO Hang)
# ------------------------------------------------------------------------------
SEC_DSTATE=""
while read -r d_pid d_user d_stat d_comm; do
  [[ -n "$d_pid" ]] || continue
  if is_dstate_stat "$d_stat"; then
    ((COUNT_DSTATE++))
    d_wchan="$(cat "/proc/${d_pid}/wchan" 2>/dev/null || echo "-")"
    SEC_DSTATE+=$'  ⚠ PID: '"${d_pid} (${d_user}) | Comando: ${d_comm} | Wchan: ${d_wchan}"$'\n'
  fi
done < <(ps -eo pid,user,stat,comm --no-headers 2>/dev/null)

if (( COUNT_DSTATE > 0 )); then
  ALERT_LIST+=("AVISO: ${COUNT_DSTATE} procesos en D-State (bloqueo I/O / kernel wait)")
else
  SEC_DSTATE="  ✓ Ningún proceso bloqueado en estado D (I/O sleep)."
fi

# ------------------------------------------------------------------------------
# 10. PROCESOS CON BINARIO BORRADO (Deleted Executables)
# ------------------------------------------------------------------------------
SEC_DELETED=""
for p in /proc/[0-9]*/exe; do
  [[ -e "$p" ]] || continue
  target="$(readlink "$p" 2>/dev/null || true)"
  if [[ "$target" =~ \(deleted\)$ ]]; then
    pid="$(basename "$(dirname "$p")")"
    user="$(ps -o user= -p "$pid" 2>/dev/null | xargs || echo "-")"
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | xargs || echo "-")"
    ((COUNT_DELETED++))
    SEC_DELETED+=$'  · PID: '"${pid} (${user}) [${comm}] -> ${target}"$'\n'
  fi
done

if (( COUNT_DELETED > 0 )); then
  ALERT_LIST+=("INFO: ${COUNT_DELETED} procesos corriendo binarios reemplazados/borrados en disco")
else
  SEC_DELETED="  ✓ Ningún proceso ejecutando binarios borrados."
fi

# ------------------------------------------------------------------------------
# 11. TOP CONSUMO (5 CPU + 5 RAM)
# ------------------------------------------------------------------------------
top_cpu="$(ps -eo pid,user,%cpu,%mem,etime,comm --sort=-%cpu 2>/dev/null | head -n 6 | awk 'NR==1 {printf "  %-7s %-10s %-6s %-6s %-10s %s\n", $1, $2, $3, $4, $5, $6} NR>1 {printf "  %-7s %-10s %-6s %-6s %-10s %s\n", $1, $2, $3"%", $4"%", $5, $6}')"
top_mem="$(ps -eo pid,user,%mem,%cpu,rss,comm --sort=-rss 2>/dev/null | head -n 6 | awk 'NR==1 {printf "  %-7s %-10s %-6s %-6s %-10s %s\n", $1, $2, $3, $4, "RSS(MiB)", $6} NR>1 {printf "  %-7s %-10s %-6s %-6s %-10.1f %s\n", $1, $2, $3"%", $4"%", $5/1024, $6}')"

SEC_TOP=$(cat <<EOF
Top 5 por uso de CPU:
${top_cpu}

Top 5 por uso de Memoria RAM:
${top_mem}
EOF
)

# ------------------------------------------------------------------------------
# 12. FALLOS DE SISTEMA DESDE ARRANQUE (Segfaults, OOM Kills, Coredumps)
# ------------------------------------------------------------------------------
SEC_JOURNAL_FAILS=""
segfaults="$(journalctl -b --no-pager 2>/dev/null | grep -E "segfault at|SIGSEGV" | tail -n 5 || true)"
oom_kills="$(journalctl -b --no-pager 2>/dev/null | grep -E "Out of memory: Killed process|invoked oom-killer" | tail -n 5 || true)"
coredumps=""
if command -v coredumpctl >/dev/null 2>&1; then
  coredumps="$(coredumpctl list --no-legend 2>/dev/null | tail -n 5 || true)"
fi

if [[ -n "$segfaults" ]]; then
  SEC_JOURNAL_FAILS+=$'Fallos de segmentación (segfaults recientes):'$'\n'
  while read -r sf_line; do
    [[ -n "$sf_line" ]] || continue
    SEC_JOURNAL_FAILS+=$'  ⚠ '"${sf_line}"$'\n'
  done <<< "$segfaults"
  ALERT_LIST+=("AVISO: Segfaults registrados en el journal desde el arranque")
fi

if [[ -n "$oom_kills" ]]; then
  SEC_JOURNAL_FAILS+=$'\nEventos Out-Of-Memory (OOM-Killer recientes):'$'\n'
  while read -r oom_line; do
    [[ -n "$oom_line" ]] || continue
    SEC_JOURNAL_FAILS+=$'  ✗ '"${oom_line}"$'\n'
  done <<< "$oom_kills"
  ALERT_LIST+=("CRÍTICO: Eventos de OOM-Killer registrados en este arranque")
fi

if [[ -n "$coredumps" ]]; then
  SEC_JOURNAL_FAILS+=$'\nÚltimos coredumps registrados (coredumpctl):'$'\n'
  while read -r cd_line; do
    [[ -n "$cd_line" ]] || continue
    SEC_JOURNAL_FAILS+=$'  · '"${cd_line}"$'\n'
  done <<< "$coredumps"
fi

if [[ -z "$SEC_JOURNAL_FAILS" ]]; then
  SEC_JOURNAL_FAILS="  ✓ Ningún fallo crítico de procesos (segfaults ni OOM-kills) en el arranque actual."
fi

# ==============================================================================
# CONSTRUCCIÓN DEL INFORME FINAL
# ==============================================================================
total_alerts=${#ALERT_LIST[@]}
alertas_header=""
if (( total_alerts > 0 )); then
  alertas_header="ESTADO GLOBAL: ${total_alerts} alertas detectadas"$'\n'
  for al in "${ALERT_LIST[@]}"; do
    alertas_header+="  [!] ${al}"$'\n'
  done
else
  alertas_header="ESTADO GLOBAL: ✓ Sistema en estado óptimo. Sin anomalías críticas."$'\n'
fi

title_line="Suite Process Status · Informe de Estado y Salud del Sistema (v${SCRIPT_VERSION})"
summary_line="Alertas: ${total_alerts} | Fallidas: ${COUNT_FAILED} | Zombis: ${COUNT_ZOMBIES} | Huérfanos: ${COUNT_ORPHANS} | D-State: ${COUNT_DSTATE} | Binarios borrados: ${COUNT_DELETED}"
date_line="Generado: $(date '+%Y-%m-%d %H:%M:%S %Z')"
host_line="Host: $(uname -n) | Kernel: $(uname -r) | Uptime: $(uptime -p 2>/dev/null || echo "-")"

REPORT_CONTENT=$(cat <<EOF
==============================================================================
 ${title_line}
==============================================================================
${date_line}
${host_line}
${summary_line}
------------------------------------------------------------------------------
${alertas_header}------------------------------------------------------------------------------
[1] UNIDADES SYSTEMD FALLIDAS
------------------------------------------------------------------------------
${SEC_FAILED}

------------------------------------------------------------------------------
[2] UNIDADES SYSTEMD ACTIVAS
------------------------------------------------------------------------------
${SEC_ACTIVAS}

------------------------------------------------------------------------------
[3] SERVICIOS HABILITADOS INACTIVOS
------------------------------------------------------------------------------
${SEC_NO_ACTIVAS}

------------------------------------------------------------------------------
[4] UNIDADES ENMASCARADAS Y NOT-FOUND
------------------------------------------------------------------------------
${SEC_MASKED}

------------------------------------------------------------------------------
[5] TEMPORIZADORES (TIMERS SYSTEMD)
------------------------------------------------------------------------------
${SEC_TIMERS}

------------------------------------------------------------------------------
[6] PROCESOS ZOMBI (DEFUNCT)
------------------------------------------------------------------------------
${SEC_ZOMBIES}

------------------------------------------------------------------------------
[7] PROCESOS HUÉRFANOS FUERA DE SYSTEMD
------------------------------------------------------------------------------
${SEC_ORPHANS}

------------------------------------------------------------------------------
[8] PROCESOS DE USUARIO EN SEGUNDO PLANO (SIN TTY)
------------------------------------------------------------------------------
${SEC_BACKGROUND}

------------------------------------------------------------------------------
[9] PROCESOS BLOQUEADOS EN D-STATE (I/O WAIT)
------------------------------------------------------------------------------
${SEC_DSTATE}

------------------------------------------------------------------------------
[10] PROCESOS CON BINARIOS BORRADOS EN DISCO
------------------------------------------------------------------------------
${SEC_DELETED}

------------------------------------------------------------------------------
[11] TOP CONSUMO DE RECURSOS
------------------------------------------------------------------------------
${SEC_TOP}

------------------------------------------------------------------------------
[12] FALLOS DEL SISTEMA Y CORE DUMPS (JOURNAL)
------------------------------------------------------------------------------
${SEC_JOURNAL_FAILS}

------------------------------------------------------------------------------
[13] RECURSOS GLOBALES DEL SISTEMA
------------------------------------------------------------------------------
${SEC_RECURSOS}
==============================================================================
EOF
)

# Salida estándar si fue solicitada
if [[ $OPT_STDOUT -eq 1 ]]; then
  printf '%s\n' "$REPORT_CONTENT"
  exit 0
fi

# Guardar en archivo y verificar hash para notificaciones
new_hash="$(printf '%s' "$REPORT_CONTENT" | sha256sum | cut -d' ' -f1)"
old_hash=""
[[ -f "$HASH_FILE" ]] && old_hash="$(cat "$HASH_FILE" 2>/dev/null || true)"

tmp_file="$(mktemp)"
printf '%s\n' "$REPORT_CONTENT" > "$tmp_file"
install -m 644 "$tmp_file" "$REPORT_FILE"
rm -f "$tmp_file"

printf '%s\n' "$new_hash" > "$HASH_FILE"
chmod 644 "$HASH_FILE"

log "Escaneo completado. Alertas: ${total_alerts}, Fallidas: ${COUNT_FAILED}, Zombis: ${COUNT_ZOMBIES}, Huérfanos: ${COUNT_ORPHANS}, D-State: ${COUNT_DSTATE}, Deleted: ${COUNT_DELETED}."

if [[ "$new_hash" != "$old_hash" || $OPT_FORCE -eq 1 ]]; then
  if (( total_alerts > 0 )); then
    log "Cambio de estado con ${total_alerts} alertas; notificando a usuarios..."
    notify_users "$new_hash"
  else
    log "Estado limpio o sin alertas críticas."
  fi
else
  log "Sin cambios en el estado del sistema; no se repite notificación."
fi

exit 0
