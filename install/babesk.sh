#!/usr/bin/env bash
#
# babesk - Proxmox VE Community-Style Installer
# ==============================================
# Installiert babesk ("Bargeldloses Bestellsystem für Schulkantinen",
# https://github.com/LinuCC/babesk) als LXC-Container auf einem Proxmox VE Host.
#
# Einzeiler (als root auf dem Proxmox-Host ausführen, an Commit gepinnt gegen CDN-Cache):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Babesk-Proxmox-Mensa-Kantine-Abrechnung/714546d45e023eded8c7f811fb656eab54aa5cdd/install/babesk.sh)"
# ungepinnt (main, kann CDN-Cache liefern):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Babesk-Proxmox-Mensa-Kantine-Abrechnung/main/install/babesk.sh)"
#
# Optionen (Umgebungsvariablen, alle optional):
#   BABESK_CT_ID=120        feste Container-ID (Standard: nächste freie ID)
#   BABESK_PORT=8080        Web-UI-Port im Container (Standard: 8080)
#   BABESK_REPO=...         Git-Repo (Standard: https://github.com/LinuCC/babesk.git)
#   BABESK_CORES / BABESK_RAM_MB / BABESK_DISK_GB   Ressourcen (2 / 2048 / 8)
#   BABESK_TEMPLATE / BABESK_STORAGE / BABESK_BRIDGE / BABESK_NET
#   BABESK_DRY_RUN=1        Testlauf ohne Proxmox (simuliert pct-Aufrufe)
#   BABESK_DEBUG=1          bash -x Debug-Log
#
# Idempotent: erneutes Ausführen konfiguriert den bestehenden CT neu.
# Deinstallieren: pct destroy <CT-ID> --purge
#
set -euo pipefail

# ---------------- Konfiguration ----------------
APP_NAME="babesk"
APP_PORT="${BABESK_PORT:-8080}"
REPO_URL="${BABESK_REPO:-https://github.com/LinuCC/babesk.git}"
APP_DIR="/opt/babesk"
CT_HOSTNAME="${BABESK_HOSTNAME:-babesk}"
CT_ID="${BABESK_CT_ID:-}"
CT_CORES="${BABESK_CORES:-2}"
CT_RAM_MB="${BABESK_RAM_MB:-2048}"
CT_DISK_GB="${BABESK_DISK_GB:-8}"
CT_TEMPLATE="${BABESK_TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
CT_STORAGE="${BABESK_STORAGE:-local-lvm}"
CT_BRIDGE="${BABESK_BRIDGE:-vmbr0}"
CT_NET="${BABESK_NET:-dhcp}"
CT_UNPRIVILEGED="${BABESK_UNPRIVILEGED:-1}"
DB_NAME="babesk"
DB_USER="babesk"
DB_PASS="${BABESK_DB_PASS:-$(openssl rand -hex 16 2>/dev/null || od -An -N16 -tx1 /dev/urandom | tr -d ' \n')}"
DRY_RUN="${BABESK_DRY_RUN:-0}"
DEBUG="${BABESK_DEBUG:-0}"

[ "$DEBUG" = "1" ] && set -x

# ---------------- Fehler-Handling: immer die komplette Kette ----------------
on_error() {
  local code=$? line=$1 cmd=$2
  {
    echo "==============================================================="
    echo " INSTALLATIONSFEHLER in $APP_NAME"
    echo "   Exit-Code : $code"
    echo "   Zeile     : $line"
    echo "   Befehl    : $cmd"
    echo "   Host      : $(hostname 2>/dev/null || echo '?')"
    echo "   Datum     : $(date -Is)"
    echo "==============================================================="
    echo " Vollständiges Debug-Log neu erzeugen mit:"
    echo "   BABESK_DEBUG=1 bash -x $0 2>&1 | tee babesk-install-debug.log"
    echo " Relevante Logs im Container (falls erstellt):"
    echo "   pct exec ${CT_ID:-<CT-ID>} -- journalctl -u ${APP_NAME} -n 100 --no-pager"
  } >&2
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

log()  { printf '\033[1;32m[babesk]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[babesk WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[babesk FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------- Dry-Run-Stubs (Test ohne Proxmox) ----------------
if [ "$DRY_RUN" = "1" ]; then
  pct() { echo "[dry-run] pct $*"; }
  qm() { echo "[dry-run] qm $*"; }
  pveam() { echo "[dry-run] pveam $*"; }
fi

# ---------------- Prüfungen ----------------
check_host() {
  if [ "$DRY_RUN" = "1" ]; then log "Dry-Run: überspringe Root-/PVE-Checks"; return 0; fi
  [ "$(id -u)" = "0" ] || die "Bitte als root auf dem Proxmox-Host ausführen (pct erforderlich)."
  command -v pct >/dev/null 2>&1 || die "pct nicht gefunden. Läuft dieses Script auf dem Proxmox VE Host?"
  pveversion >/dev/null 2>&1 || die "pveversion nicht gefunden. Läuft dieses Script auf dem Proxmox VE Host?"
}

check_template() {
  if [ "$DRY_RUN" = "1" ]; then log "Dry-Run: Template $CT_TEMPLATE wird als vorhanden angenommen"; return 0; fi
  if ! pveam list local 2>/dev/null | grep -qF "$(basename "$CT_TEMPLATE")"; then
    warn "Template $CT_TEMPLATE nicht im local-Storage gefunden, lade es herunter ..."
    pveam update || true
    pveam download local "$(basename "$CT_TEMPLATE")" || die "Template-Download fehlgeschlagen. Bitte BABESK_TEMPLATE auf ein vorhandenes Template setzen (pveam available)."
  fi
}

check_storage() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$CT_STORAGE" || die "Storage '$CT_STORAGE' nicht gefunden. Verfügbar: $(pvesm status | awk 'NR>1{print $1}' | tr '\n' ' ')"
}

# ---------------- Nächste freie CT-ID ----------------
# Eine ID gilt als belegt, wenn sie als CT (pct list) ODER als VM (qm list)
# existiert. 'pct status <id>' allein reicht nicht, denn für eine VM-ID
# liefert es einen Fehler und täuscht "frei" vor.
id_in_use() {
  local id="$1"
  if [ "$DRY_RUN" = "1" ]; then return 1; fi
  pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$id" && return 0
  qm list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$id" && return 0
  return 1
}

next_free_ctid() {
  local id
  if [ "$DRY_RUN" = "1" ]; then echo 100; return 0; fi
  for id in $(seq 100 999); do
    if ! id_in_use "$id"; then echo "$id"; return 0; fi
  done
  return 1
}

ct_exists() {
  [ "$DRY_RUN" = "1" ] && return 1
  pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"
}

# ---------------- Container anlegen / starten ----------------
create_ct() {
  local netconf
  if [ "$CT_NET" = "dhcp" ]; then netconf="name=eth0,bridge=$CT_BRIDGE,ip=dhcp"; else netconf="name=eth0,bridge=$CT_BRIDGE,ip=$CT_NET"; fi
  log "Erstelle LXC $CT_ID (Hostname: $CT_HOSTNAME, ${CT_CORES} vCPU, ${CT_RAM_MB} MB RAM, ${CT_DISK_GB} GB Disk, unprivileged=$CT_UNPRIVILEGED, onboot=1)"
  pct create "$CT_ID" "$CT_TEMPLATE" \
    -hostname "$CT_HOSTNAME" \
    -storage "$CT_STORAGE" \
    -rootfs "${CT_STORAGE}:${CT_DISK_GB}" \
    -cores "$CT_CORES" \
    -memory "$CT_RAM_MB" \
    -net0 "$netconf" \
    -unprivileged "$CT_UNPRIVILEGED" \
    -onboot 1 \
    -features nesting=0,keyctl=1
  pct start "$CT_ID"
  log "Warte auf Boot des Containers ..."
  local i
  for i in $(seq 1 60); do
    if [ "$DRY_RUN" = "1" ] || pct exec "$CT_ID" -- true 2>/dev/null; then break; fi
    sleep 2
  done
  [ "$DRY_RUN" = "1" ] || pct exec "$CT_ID" -- true || die "Container $CT_ID bootet nicht innerhalb von 120 s. Logs: pct enter $CT_ID"
}

ensure_ct_running() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  pct status "$CT_ID" | grep -q "status: running" || pct start "$CT_ID"
}

# ---------------- Inneres Install-Skript (läuft IM Container) ----------------
write_inner_script() {
  cat > /tmp/babesk-inner.sh <<'INNER'
#!/usr/bin/env bash
# Wird per 'pct push' in den Container kopiert und dort ausgeführt.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

echo "[inner] apt update + Installation der Abhängigkeiten (PHP, MariaDB, git, ufw) ..."
apt-get update
# In LXC scheitert das Starten von Diensten im apt-Postinst (kein systemd als
# PID 1 beim Paket-Setup) -> 'Job for mariadb.service failed' bricht unter
# 'set -e' das ganze Script ab. policy-rc.d (exit 101) verbietet das Auto-Starten
# während der Installation; wir starten MariaDB danach selbst (siehe unten).
cat > /usr/sbin/policy-rc.d <<'POL'
#!/bin/sh
exit 101
POL
chmod +x /usr/sbin/policy-rc.d
apt-get install -y --no-install-recommends \
  php-cli php-gd php-mysql php-mbstring php-xml php-curl php-zip \
  mariadb-server git curl ca-certificates ufw
rm -f /usr/sbin/policy-rc.d

echo "[inner] MariaDB vorbereiten und starten ..."
# In LXC scheitert 'systemctl start mariadb' gern an fehlendem /run/mysqld.
mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
# In (unprivilegierten) LXC-Containern kann systemd keine Mount-Namespaces
# aufsetzen -> MariaDB startet mit status=226/NAMESPACE nicht. Das komplette
# Sandboxing/Hardening der Unit per Drop-in abschalten. WICHTIG: auch
# ProtectProc/ProcSubset leeren, sonst wird /proc neu gemountet
# (Fehler: "unit-root/proc: Permission denied").
mkdir -p /etc/systemd/system/mariadb.service.d
cat > /etc/systemd/system/mariadb.service.d/override.conf <<'OVR'
[Service]
ProtectSystem=
ProtectHome=
ProtectProc=
ProcSubset=
PrivateDevices=false
PrivateTmp=false
PrivateIPC=false
ProtectKernelTunables=false
ProtectKernelLogs=false
ProtectControlGroups=false
ProtectClock=false
ProtectHostname=false
ReadWritePaths=
ReadOnlyPaths=
InaccessiblePaths=
ExecPaths=
NoExecPaths=
BindPaths=
BindReadOnlyPaths=
TemporaryFileSystem=
RestrictAddressFamilies=
MemoryDenyWriteExecute=false
LockPersonality=false
SystemCallFilter=
SystemCallArchitectures=
CapabilityBoundingSet=
OVR
systemctl daemon-reload
# Gegenprobe: welche Namespace-/Sandboxing-Direktiven sind noch aktiv?
echo "[inner] Aktive Sandboxing-Direktiven (sollten leer/false sein):"
systemctl show mariadb -p ProtectSystem -p ProtectHome -p ProtectProc -p ProcSubset \
  -p PrivateTmp -p PrivateDevices -p ProtectKernelTunables -p ProtectControlGroups \
  --no-pager 2>/dev/null || true
systemctl enable mariadb 2>/dev/null || true
if ! systemctl start mariadb 2>/dev/null; then
  echo "[inner] systemctl start mariadb fehlgeschlagen, Fallback: service mariadb start ..."
  service mariadb start || true
fi
# Auf Socket warten (bis 30 s)
ok=""
for i in $(seq 1 15); do
  if mysqladmin ping >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
# Letzter Fallback: systemd startet MariaDB im LXC partout nicht -> mariadbd
# direkt als mysql hochziehen, damit die Installation fertig wird.
if [ -z "$ok" ]; then
  echo "[inner] MariaDB per systemd nicht erreichbar, starte mariadbd direkt ..."
  mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
  nohup mariadbd --user=mysql --datadir=/var/lib/mysql \
    --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid \
    >/var/log/mariadb-direct.log 2>&1 &
  for i in $(seq 1 15); do
    if mysqladmin ping >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
  done
fi
if [ -z "$ok" ]; then
  echo "[inner] FEHLER: MariaDB-Socket nicht erreichbar. Journal-Auszug:"
  journalctl -u mariadb -n 50 --no-pager || true
  service mariadb status || true
  tail -n 30 /var/log/mariadb-direct.log 2>/dev/null || true
  exit 1
fi
echo "[inner] MariaDB läuft."

echo "[inner] Datenbank '${DB_NAME}' anlegen ..."
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "[inner] babesk klonen nach ${APP_DIR} ..."
if [ -d "${APP_DIR}/.git" ]; then
  git -C "$APP_DIR" pull --ff-only || echo "[inner] git pull fehlgeschlagen (offline oder Divergence) - behalte lokale Version"
else
  git clone --depth 1 "${REPO_URL}" "$APP_DIR"
fi

echo "[inner] Konfigurationsdateien aus Vorlagen erzeugen ..."
if [ ! -f "${APP_DIR}/code/include/sql_access/databaseValues.php" ] && [ -f "${APP_DIR}/code/include/sql_access/databaseValues.php.orig" ]; then
  cp "${APP_DIR}/code/include/sql_access/databaseValues.php.orig" "${APP_DIR}/code/include/sql_access/databaseValues.php"
  sed -i -e "s/localhost/localhost/" \
         -e "s/USERNAME/${DB_USER}/" -e "s/PASSWORD/${DB_PASS}/" -e "s/DATABASE/${DB_NAME}/" \
         "${APP_DIR}/code/include/sql_access/databaseValues.php" || true
fi
if [ ! -f "${APP_DIR}/dbv/config.php" ] && [ -f "${APP_DIR}/dbv/config.php.sample" ]; then
  cp "${APP_DIR}/dbv/config.php.sample" "${APP_DIR}/dbv/config.php"
  sed -i -e "s/USERNAME/${DB_USER}/" -e "s/PASSWORD/${DB_PASS}/" -e "s/DATABASE/${DB_NAME}/" \
         "${APP_DIR}/dbv/config.php" || true
fi
chown -R www-data:www-data "$APP_DIR" || true

echo "[inner] systemd-Unit ${APP_NAME}.service einrichten ..."
cat > "/etc/systemd/system/${APP_NAME}.service" <<UNIT
[Unit]
Description=babesk - Bargeldloses Bestellsystem für Schulkantinen
After=network-online.target mariadb.service
Wants=network-online.target mariadb.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}/code
ExecStart=/usr/bin/php -S 0.0.0.0:${APP_PORT} -t ${APP_DIR}/code
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now "${APP_NAME}"

echo "[inner] Firewall: Port ${APP_PORT}/tcp öffnen ..."
ufw allow "${APP_PORT}/tcp" || true
ufw --force enable || true

echo "[inner] Verifikation im Container ..."
systemctl is-active "${APP_NAME}"
curl -fsS -o /dev/null -w "[inner] lokale Web-UI: HTTP %{http_code}\n" "http://localhost:${APP_PORT}/"
INNER
}

run_inner_script() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] pct push $CT_ID /tmp/babesk-inner.sh /tmp/babesk-inner.sh"
    echo "[dry-run] pct exec $CT_ID -- env DB_NAME=$DB_NAME DB_USER=$DB_USER DB_PASS=*** APP_DIR=$APP_DIR APP_PORT=$APP_PORT REPO_URL=$REPO_URL bash /tmp/babesk-inner.sh"
    return 0
  fi
  pct push "$CT_ID" /tmp/babesk-inner.sh /tmp/babesk-inner.sh
  pct exec "$CT_ID" -- env "DB_NAME=$DB_NAME" "DB_USER=$DB_USER" "DB_PASS=$DB_PASS" \
    "APP_DIR=$APP_DIR" "APP_PORT=$APP_PORT" "REPO_URL=$REPO_URL" bash /tmp/babesk-inner.sh
  pct exec "$CT_ID" -- rm -f /tmp/babesk-inner.sh
}

# ---------------- Verifikation von außen ----------------
verify() {
  log "Verifikation: Service-Status und HTTP-Check ..."
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] pct exec $CT_ID -- systemctl is-active $APP_NAME   -> active (simuliert)"
    echo "[dry-run] pct exec $CT_ID -- curl -fsS http://localhost:$APP_PORT/   -> HTTP 200 (simuliert)"
  else
    pct exec "$CT_ID" -- systemctl is-active "$APP_NAME"
    pct exec "$CT_ID" -- curl -fsS -o /dev/null -w "HTTP %{http_code}\n" "http://localhost:${APP_PORT}/"
  fi
  local ip=""
  if [ "$DRY_RUN" = "1" ]; then ip="10.0.0.100 (simuliert)"; else ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}'); fi
  echo
  echo "==============================================================="
  echo " babesk wurde installiert."
  echo "   Container-ID : $CT_ID  (Hostname: $CT_HOSTNAME, onboot=1)"
  echo "   Web-UI       : http://${ip}:${APP_PORT}/"
  echo "   Admin-Login  : im babesk-Adminbereich anlegen (siehe README im Repo)"
  echo "   DB           : ${DB_NAME} / Benutzer: ${DB_USER} (Passwort wird nur bei Erzeugung generiert)"
  echo "   Service      : systemctl status ${APP_NAME} (im CT: pct exec ${CT_ID} -- systemctl status ${APP_NAME})"
  echo "   Debug-Log    : BABESK_DEBUG=1 bash -x $0 2>&1 | tee babesk-install-debug.log"
  echo "==============================================================="
}

# ---------------- Hauptablauf ----------------
main() {
  check_host
  check_template
  check_storage

  if [ -z "$CT_ID" ]; then
    CT_ID=$(next_free_ctid) || die "Keine freie CT-ID zwischen 100 und 999 gefunden."
    log "Nächste freie CT-ID: $CT_ID"
  fi

  if ct_exists "$CT_ID"; then
    log "Container $CT_ID existiert bereits (idempotenter Re-Run) ..."
    ensure_ct_running
  else
    create_ct
  fi

  write_inner_script
  run_inner_script
  verify
  log "Fertig."
}

main "$@"
