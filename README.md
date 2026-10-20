# Suite Process Status · Cizen (v1.0.0)

Suite integral y modular de auditoría, diagnóstico, monitoreo y resolución para procesos y unidades de `systemd` en Arch Linux. Diseñada en arquitectura paralela a las suites `arch-update` y `kernel-update`.

---

## 1. Arquitectura y Referencias de Diseño

Esta suite sintetiza las mejores técnicas de herramientas de diagnóstico y administración de procesos:
* **procclean (PyPI):** Clasificación precisa de huérfanos reales (`PPID=1`) descartando daemons y servicios legítimos mediante inspección de jerarquía `cgroup` (`system.slice`, `*.service`) y detección de procesos ejecutando binarios borrados en disco (`/proc/*/exe -> (deleted)`).
* **orphan-proc-cleaner (GitHub):** Lista blanca (whitelist) de daemons esenciales del sistema, protocolo de terminación limpia `SIGTERM` → `SIGKILL`, y tratamiento adecuado de procesos zombi (un proceso zombi no puede ser terminado directamente; requiere enviar `SIGCHLD` o terminar a su padre si no responde).
* **zombies.sh (djeada):** Análisis de procesos zombis (`Z`/`defunct`), identificando PID padre (`PPID`), nombre del proceso padre, tiempo de vida y usuario.
* **system-healthcheck (capwan):** Auditoría pura en Bash sin dependencias externas pesadas, con agregación de alertas globales prioritarias al inicio del informe.
* **MiniDash & systemctl nativo:** Resumen de un vistazo en terminal TTY con formato visual coherente, evaluación profunda de unidades fallidas, activas, inactivas, enmascaradas y temporizadores de sistema y usuario.

---

## 2. Componentes de la Suite

| Script / Fichero | Rol en la Suite | Espejo de… |
| :--- | :--- | :--- |
| `process-status-checker.sh` | Motor/escáner root con serialización `flock`. Genera `/var/cache/process-status/report` y notifica ante cambios de hash o alertas. | `arch-update-checker.sh` |
| `process-status-show.sh` | Visor formateado del informe. Solo si el informe tiene alertas (`Alertas: N > 0`) ofrece `¿Desea abrir el asistente de arreglo ahora? [S/n]`; con 0 alertas imprime `✔ El informe no contiene anomalías: no hay nada que arreglar.`. | `arch-show-pending.sh` |
| `process-status-fix.sh` | Asistente interactivo guiado para reiniciar servicios fallidos, enviar `SIGCHLD` a padres de zombis, purgar coredumps y recargar binarios obsoletos. | `arch-apply-updates.sh` |
| `process-status-menu.sh` | Menú interactivo en terminal con regla separadora de 55 guiones, funciones `hrow`/`opt` y selector `[0-N]`. | `kernel-update-menu.sh` |
| `process-status-notify-agent.sh` | Agente gráfico de `notify-send` con botones de acción ("🛠 Arreglar ahora" y "📋 Ver informe") mediante `arch-open-terminal.sh`. | `arch-update-notify-agent.sh` |
| `process-status-notify-user.sh` | Wrapper fino de ejecución para la unidad de usuario systemd. | `arch-update-notify-user.sh` |
| `systemd/system/process-status-checker.{service,timer}` | Timer horario (`OnCalendar=hourly`, `Persistent=true`, `Nice=19`, `IOSchedulingClass=idle`). | `arch-update-checker.{service,timer}` |
| `systemd/user/process-status-notify.service` | Notificación de escritorio al inicio de sesión gráfica si existen anomalías pendientes. | `arch-update-notify.service` |

---

## 3. Secciones del Escáner (13 Secciones)

### Unidades systemd (Sistema y Usuarios):
1. **Unidades Fallidas:** Detección de unidades con fallo (`systemctl --failed` y `systemctl --user --failed`), conteo de reinicios acumulados (`NRestarts`), marca de tiempo de entrada al estado de error y comando de diagnóstico recomendado (`systemctl status <unidad>`).
2. **Unidades Activas:** Recuento global y desglose por tipo (servicios, sockets, temporizadores y targets).
3. **Servicios Habilitados Inactivos:** Servicios configurados para el arranque (`enabled`) que no se encuentran en ejecución (descartando servicios de tipo `oneshot` finalizados con éxito).
4. **Unidades Enmascaradas y Not-Found:** Unidades marcadas como `masked` y referencias a unidades inexistentes (`not-found`).
5. **Temporizadores (Timers):** Lista cronológica de próximos disparos de temporizadores del sistema.

### Procesos:
6. **Procesos Zombi (Z / defunct):** Identificación de PIDs zombis, usuario, tiempo transcurrido (`etime`), comando y localización del proceso padre (`PPID`).
7. **Procesos Huérfanos Fuera de Systemd:** Detección de procesos adoptados por PID 1 que no forman parte de servicios legítimos de systemd ni de la lista blanca de daemons.
8. **Procesos en Segundo Plano (sin TTY):** Procesos de usuario (`UID >= 1000`) sin terminal de control (`TTY = ?`), con reporte de `cgroup`.
9. **Procesos en D-State:** Procesos bloqueados en suspensión ininterrumpible (`uninterruptible sleep`), indicando función de espera en kernel (`wchan`) ante posibles bloqueos de E/S.
10. **Binarios Borrados en Disco:** Procesos en ejecución cuyo archivo binario original fue eliminado o reemplazado durante una actualización (`/proc/*/exe -> (deleted)`).
11. **Top Consumo de Recursos:** Los 5 procesos con mayor consumo de CPU y los 5 procesos con mayor uso de memoria RAM (RSS formateado en MiB).

### Journal y Recursos:
12. **Fallos del Sistema (Journal):** Detección de fallos de segmentación (`segfaults`), eventos del asesino por falta de memoria (`OOM-Killer`) y últimos volcados registrados con `coredumpctl`.
13. **Recursos Globales del Sistema:** Carga promedio (1m, 5m, 15m) comparada contra núcleos de CPU, uso y porcentaje de memoria RAM, espacio de intercambio (Swap) y estado de almacenamiento raíz (`/`). Incluye generación de alertas de salud agregadas al inicio del reporte.

---

## 4. Instalación y Despliegue

La suite se instala en `/usr/local/bin/process-status/` y sus unidades en `/etc/systemd/system/`:

```bash
# 1. Copiar binarios y scripts ejecutables
sudo install -d /usr/local/bin/process-status
sudo install -m 755 process-status-checker.sh /usr/local/bin/process-status/
sudo install -m 755 process-status-show.sh    /usr/local/bin/process-status/
sudo install -m 755 process-status-fix.sh     /usr/local/bin/process-status/
sudo install -m 755 process-status-menu.sh    /usr/local/bin/process-status/
sudo install -m 755 process-status-notify-agent.sh /usr/local/bin/process-status/
sudo install -m 755 process-status-notify-user.sh  /usr/local/bin/process-status/

# 2. Instalar unidades systemd del sistema
sudo install -m 644 systemd/system/process-status-checker.service /etc/systemd/system/
sudo install -m 644 systemd/system/process-status-checker.timer   /etc/systemd/system/
sudo systemctl daemon-reload

# 3. Instalar unidad de usuario para notificaciones
mkdir -p ~/.config/systemd/user/
install -m 644 systemd/user/process-status-notify.service ~/.config/systemd/user/
systemctl --user daemon-reload

# 4. Habilitar temporizador horario del sistema
sudo systemctl enable --now process-status-checker.timer
```

---

## 5. Aliases Rápidos en `~/.bashrc`

Para un acceso fluido desde la terminal, se definen los siguientes alias:
```bash
alias ps-status='/usr/local/bin/process-status/process-status-menu.sh'
alias ps-report='/usr/local/bin/process-status/process-status-show.sh'
alias ps-check='sudo /usr/local/bin/process-status/process-status-checker.sh'
alias ps-fix='/usr/local/bin/process-status/process-status-fix.sh'
```

---

## 6. Validación Interna (`--selftest`)

El motor incluye un arnés de pruebas con datos sintéticos para validar la lógica de detección sin alterar el sistema:
```bash
process-status-checker.sh --selftest
```
Verifica:
* Detección y discriminación de estados Z / defunct.
* Clasificación de huérfanos vs servicios en `system.slice` y daemons en whitelist.
* Identificación de estados D (uninterruptible sleep).
* Presencia de utilidades del sistema necesarias.
