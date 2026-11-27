#!/usr/bin/env bash
#
# babesk - Proxmox VE Community-Style Installer
# ==============================================
# Installiert babesk ("Bargeldloses Bestellsystem für Schulkantinen",
# https://github.com/LinuCC/babesk) als LXC-Container auf einem Proxmox VE Host.
#
# Einzeiler (als root auf dem Proxmox-Host ausführen, an Commit gepinnt gegen CDN-Cache):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Babesk-Proxmox-Mensa-Kantine-Abrechnung/febad1779c375706d6b5b92c0309242bdaeb516a/install/babesk.sh)"
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
# APP_NAME wird vom äußeren Script nicht als Env übergeben -> hier defaulten,
# sonst bricht 'set -u' bei der Unit-Erzeugung ab.
APP_NAME="${APP_NAME:-babesk}"

echo "[inner] apt update + PHP 7.4 (sury) + MariaDB, git, ufw installieren ..."
# babesk ist PHP-5.3-era Code. Auf PHP 8.2 hagelt es Altlasten (create_function,
# each, count(null) = Fatal). PHP 7.4 macht den Grossteil davon harmlos
# (nur deprecated/Warnung). Debian 12 liefert nur 8.2 -> sury-Repo fuer 7.4.
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg2 apt-transport-https
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/deb.sury.org-php.gpg
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
  > /etc/apt/sources.list.d/sury-php.list
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
  php7.4-cli php7.4-mysql php7.4-gd php7.4-mbstring php7.4-xml php7.4-curl php7.4-zip \
  mariadb-server git curl ca-certificates ufw
rm -f /usr/sbin/policy-rc.d
# 'php' soll auf 7.4 zeigen (nicht auf ein evtl. vorhandenes 8.2).
update-alternatives --set php /usr/bin/php7.4 2>/dev/null || true
update-alternatives --set phar /usr/bin/phar7.4 2>/dev/null || true
update-alternatives --set phar.phar /usr/bin/phar.phar7.4 2>/dev/null || true
php -v | head -n1

echo "[inner] MariaDB vorbereiten und starten ..."
# In LXC scheitert 'systemctl start mariadb' gern an fehlendem /run/mysqld.
mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
# In (unprivilegierten) LXC-Containern kann systemd keine Mount-Namespaces
# aufsetzen -> MariaDB startet mit status=226/NAMESPACE nicht. Ein bloßes
# Drop-in mit leeren Werten (ProtectSystem= o.ae.) resetet diese Direktiven in
# Debian 12 NICHT. Deshalb die Unit komplett durch eine sandbox-freie Version
# ersetzen (ExecStart wurde per mariadbd-Direktstart verifiziert).
cat > /etc/systemd/system/mariadb.service <<'UNIT'
[Unit]
Description=MariaDB database server (LXC, ohne Sandboxing)
After=network.target

[Service]
Type=simple
User=mysql
Group=mysql
RuntimeDirectory=mysqld
RuntimeDirectoryMode=755
ExecStart=/usr/sbin/mariadbd --user=mysql --datadir=/var/lib/mysql \
  --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
# Gegenprobe: welche Namespace-/Sandboxing-Direktiven sind noch aktiv?
echo "[inner] Aktive Sandboxing-Direktiven (sollten alle no/empty sein):"
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
# databaseValues.php.orig ist XML mit LEEREN Tags (<username></username> ...) -
# keine USERNAME/PASSWORD/DATABASE-Platzhalter. Die leeren Tags befuellen.
if [ ! -f "${APP_DIR}/code/include/sql_access/databaseValues.php" ] && [ -f "${APP_DIR}/code/include/sql_access/databaseValues.php.orig" ]; then
  cp "${APP_DIR}/code/include/sql_access/databaseValues.php.orig" "${APP_DIR}/code/include/sql_access/databaseValues.php"
  sed -i \
    -e "s#<host></host>#<host>localhost</host>#" \
    -e "s#<name></name>#<name>${DB_NAME}</name>#" \
    -e "s#<username></username>#<username>${DB_USER}</username>#" \
    -e "s#<password></password>#<password>${DB_PASS}</password>#" \
    "${APP_DIR}/code/include/sql_access/databaseValues.php" || true
fi
# dbv/config.php.sample nutzt define('DB_USERNAME', '') - die leeren Strings
# befuellen (NICHT den Konstantennamen per s/USERNAME/.../ zerstoeren).
if [ ! -f "${APP_DIR}/dbv/config.php" ] && [ -f "${APP_DIR}/dbv/config.php.sample" ]; then
  cp "${APP_DIR}/dbv/config.php.sample" "${APP_DIR}/dbv/config.php"
  sed -i \
    -e "s#define('DB_HOST', '')#define('DB_HOST', 'localhost')#" \
    -e "s#define('DB_USERNAME', '')#define('DB_USERNAME', '${DB_USER}')#" \
    -e "s#define('DB_PASSWORD', '')#define('DB_PASSWORD', '${DB_PASS}')#" \
    -e "s#define('DB_NAME', '')#define('DB_NAME', '${DB_NAME}')#" \
    "${APP_DIR}/dbv/config.php" || true
fi
# babesk setzt selbst error_reporting(E_ALL)+display_errors(1) und ueberschreibt
# damit das -d aus dem Dienst -> Deprecated/Notice/Warning-Spam (create_function,
# each, count(null)) landet im HTML und kann den Login-Redirect (Header) zerschiessen.
# error_reporting im Code robust (trifft auch Re-Runs) auf E_ALL ohne
# Deprecated/Notice/Strict/Warning umstellen - echte Fatals bleiben sichtbar.
find "${APP_DIR}/code" -name '*.php' -exec \
  sed -i -E 's/error_reporting\([^;]*\);/error_reporting(E_ALL \& ~E_DEPRECATED \& ~E_NOTICE \& ~E_STRICT \& ~E_WARNING);/g' {} + 2>/dev/null || true
# Konkrete count(null)-Stelle (Blatt-Module ohne Kinder) warning-frei machen.
sed -i 's/if(count(\$module->_childs))/if(!empty($module->_childs))/' \
  "${APP_DIR}/code/include/ModuleGeneratorManager.php" 2>/dev/null || true
chown -R www-data:www-data "$APP_DIR" || true

# ---------------- Datenbank automatisch einspielen ----------------
# babesk "installiert" sich ueber die dbv-Revisions (Migrationen 1..N): Sie
# bauen aus einer leeren DB den finalen Stand inkl. Default-Admin (administrator/root)
# auf und legen die Stored Procedures selbst an. Import als root (unix_socket),
# Fremdschluessel-Checks aus (Reihenfolge egal), Routinen per DELIMITER wrappen.
# Schlaegt etwas fehl, wird die DB geleert und auf dbv (Browser) zurueckgefallen.
echo "[inner] Datenbank automatisch einspielen (dbv-Revisions 1..N) ..."
# DEFINER root@localhost -> babesk@localhost (nur fuer den dbv-Fallback noetig,
# der als App-User laeuft; root-Import darf beide setzen).
find "${APP_DIR}/dbv/data" -name '*.sql' \
  -exec sed -i 's/DEFINER=`root`@`localhost`/DEFINER=`babesk`@`localhost`/g' {} + 2>/dev/null || true
# Revision 63 hardcodet den Entwickler-DB-Namen 'c1babesk' -> auf echten DB-Namen.
find "${APP_DIR}/dbv/data" -name '*.sql' \
  -exec sed -i "s/c1babesk/${DB_NAME}/g" {} + 2>/dev/null || true
# rev21 benennt GroupModuleRights -> SystemGroupModuleRights um. Spaetere
# Revisionen (22/23) nutzen aber noch den ALTEN Namen -> statt Rename eine KOPIE
# anlegen, damit beide Tabellen existieren (rev25+ braucht den neuen Namen).
find "${APP_DIR}/dbv/data" -name '*.sql' -exec \
  sed -i 's#RENAME TABLE `GroupModuleRights` TO `SystemGroupModuleRights`;#CREATE TABLE IF NOT EXISTS `SystemGroupModuleRights` LIKE `GroupModuleRights`; INSERT INTO `SystemGroupModuleRights` SELECT * FROM `GroupModuleRights`;#' {} + 2>/dev/null || true
import_ok=1
import_err="$(mktemp)"
fail_list=""
# Pro Datei importieren: ein Fehler stoppt nicht alles, sondern wird protokolliert
# (welche Datei + mysql-Meldung). FK-Checks pro Verbindung aus.
for d in $(ls "${APP_DIR}/dbv/data/revisions" 2>/dev/null | sort -n); do
  for f in "${APP_DIR}"/dbv/data/revisions/"$d"/*.sql; do
    [ -f "$f" ] || continue
    if grep -qiE '(^|[^A-Za-z_])BEGIN([^A-Za-z_]|$)' "$f"; then
      { echo "SET FOREIGN_KEY_CHECKS=0;"; printf 'DELIMITER ;;\n'; cat "$f"; printf '\n;;\nDELIMITER ;\n'; } \
        | mysql -u root --force "$DB_NAME" 2>>"$import_err" \
        || { import_ok=0; fail_list="$fail_list $d/$(basename "$f")"; }
    else
      { echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$f"; printf ';\n'; } \
        | mysql -u root --force "$DB_NAME" 2>>"$import_err" \
        || { import_ok=0; fail_list="$fail_list $d/$(basename "$f")"; }
    fi
  done
done

if [ "$import_ok" = "1" ] && mysql -u root -N -e "SELECT COUNT(*) FROM SystemUsers;" "$DB_NAME" >/dev/null 2>&1; then
  echo "[inner] Datenbank fertig. Default-Login: administrator / root"
else
  echo "[inner] Auto-Import unvollständig. Fehlgeschlagene Dateien:${fail_list:- (keine, aber SystemUsers leer)}"
  echo "[inner] Letzte mysql-Fehler:"
  tail -n 20 "$import_err" 2>/dev/null || true
  echo "[inner] Fallback: dbv im Browser (URL /dbv/, Login dbv/dbv) - dort Revisions anwenden."
  # Nur leeren, wenn GAR NICHTS importiert wurde (partiellen Stand nicht zerstoeren).
  tbls=$(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo 0)
  if [ "${tbls:-0}" = "0" ]; then
    mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
  fi
fi
rm -f "$import_err" 2>/dev/null || true

# dbv im Web-Root erreichbar machen (Fallback-Installer) + freundliche Startseite.
ln -sfn "${APP_DIR}/dbv" "${APP_DIR}/code/dbv" 2>/dev/null || true
cat > "${APP_DIR}/code/index.php" <<'INDEX'
<?php
// Freundliche babesk-Startseite (wird vom Installer ueberschrieben).
$dbv = is_dir(__DIR__ . '/dbv');
$installed = is_dir(__DIR__ . '/installation');
header('Content-Type: text/html; charset=utf-8');
?>
<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>babesk</title>
<style>
 body{font-family:system-ui,Segoe UI,Roboto,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center}
 .card{background:#1e293b;padding:2rem 2.5rem;border-radius:16px;max-width:460px;box-shadow:0 10px 40px rgba(0,0,0,.4)}
 h1{margin:0 0 .25rem;font-size:1.6rem} .sub{color:#94a3b8;margin:0 0 1.5rem}
 a.btn{display:block;text-decoration:none;color:#0f172a;background:#a3e635;padding:.8rem 1rem;border-radius:10px;margin:.5rem 0;font-weight:600}
 a.btn.alt{background:#334155;color:#e2e8f0} .hint{font-size:.85rem;color:#94a3b8;margin-top:1rem}
 code{background:#0f172a;padding:.1rem .35rem;border-radius:5px}
</style></head><body><div class="card">
 <h1>babesk</h1><p class="sub">Bargeldloses Bestellsystem für Schulkantinen</p>
 <a class="btn" href="web/index.php">Web-Frontend öffnen</a>
 <a class="btn alt" href="administrator/index.php">Administrator-Frontend</a>
 <a class="btn alt" href="dbv/">Datenbank-Setup (nur falls oben kein Login klappt)</a>
 <p class="hint">Administrator-Login nach dem Setup: <code>administrator</code> / <code>root</code>.
 <?php if (!$installed): ?>Die Datenbank ist noch nicht eingerichtet — bitte oben „Datenbank-Setup" ausführen und die Revisions anwenden.<?php endif; ?></p>
</div></body></html>
INDEX
chown www-data:www-data "${APP_DIR}/code/index.php" 2>/dev/null || true

echo "[inner] PHP-8-Polyfill für legacy-Code (create_function/each) schreiben ..."
cat > "${APP_DIR}/php8-polyfill.php" <<'PHP'
<?php
// babesk (2015) und die gebündelte alte Smarty nutzen Funktionen, die in PHP 8
// entfernt wurden. Dieses Polyfill stellt sie wieder bereit, damit der
// legacy-Code auf dem mitgelieferten PHP 8.2 läuft (kein EOL-PHP-Downgrade).
if (!function_exists('create_function')) {
    function create_function($args, $code) {
        return eval('return function(' . $args . ') {' . $code . '};');
    }
}
if (!function_exists('each')) {
    function each(&$array) {
        $key = key($array);
        if ($key === null) {
            return false;
        }
        $value = current($array);
        next($array);
        return array(1 => $value, 'value' => $value, 0 => $key, 'key' => $key);
    }
}
// mcrypt wurde in PHP 7.2 entfernt; babesks PasswordHash braucht mcrypt_create_iv
// fuer das Salt (beim md5->pbkdf2-Upgrade des Passworts).
if (!defined('MCRYPT_DEV_URANDOM')) define('MCRYPT_DEV_URANDOM', 0);
if (!defined('MCRYPT_DEV_RANDOM')) define('MCRYPT_DEV_RANDOM', 1);
if (!defined('MCRYPT_RAND')) define('MCRYPT_RAND', 2);
if (!function_exists('mcrypt_create_iv')) {
    function mcrypt_create_iv($size, $source = 0) {
        return random_bytes($size);
    }
}
PHP
chown www-data:www-data "${APP_DIR}/php8-polyfill.php" || true

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
ExecStart=/usr/bin/php7.4 -d auto_prepend_file=${APP_DIR}/php8-polyfill.php -d error_reporting=22519 -S 0.0.0.0:${APP_PORT} -t ${APP_DIR}/code
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
# Gegenprobe: legacy-Code darf keinen PHP-Fatal auf der Admin-Seite werfen.
if curl -fsS "http://localhost:${APP_PORT}/administrator/" 2>/dev/null | grep -qiE 'Fatal error|Uncaught'; then
  echo "[inner] WARNUNG: PHP-Fehler auf /administrator/ erkannt (legacy-Code evtl. nicht PHP-8-kompatibel)."
else
  echo "[inner] Admin-Seite ohne PHP-Fatal erreichbar."
fi
INNER
}

run_inner_script() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] pct push $CT_ID /tmp/babesk-inner.sh /tmp/babesk-inner.sh"
    echo "[dry-run] pct exec $CT_ID -- env DB_NAME=$DB_NAME DB_USER=$DB_USER DB_PASS=*** APP_DIR=$APP_DIR APP_PORT=$APP_PORT REPO_URL=$REPO_URL bash /tmp/babesk-inner.sh"
    return 0
  fi
  # pct push kann direkt nach dem Start an einem noch nicht ganz bereiten
  # rootfs scheitern -> mit Retry + Existenz-Check absichern.
  local tries
  for tries in 1 2 3 4 5; do
    if pct push "$CT_ID" /tmp/babesk-inner.sh /tmp/babesk-inner.sh 2>/dev/null \
       && pct exec "$CT_ID" -- test -f /tmp/babesk-inner.sh 2>/dev/null; then
      break
    fi
    warn "pct push nach CT $CT_ID fehlgeschlagen (Versuch $tries), retry in 3 s ..."
    sleep 3
  done
  pct exec "$CT_ID" -- test -f /tmp/babesk-inner.sh 2>/dev/null \
    || die "Inneres Script konnte nicht in CT $CT_ID abgelegt werden (pct push). Logs: pct enter $CT_ID"
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
  echo "   Admin-Login  : http://${ip}:${APP_PORT}/administrator/  (Default: administrator / root)"
  echo "   DB-Setup     : bei Auto-Import-FEHLER -> http://${ip}:${APP_PORT}/dbv/ (Login dbv/dbv)"
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
