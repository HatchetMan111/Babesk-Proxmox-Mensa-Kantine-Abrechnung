# babesk auf Proxmox VE (Community-Scripts-Stil)

Installiert [babesk](https://github.com/LinuCC/babesk) (Bargeldloses Bestellsystem für Schulkantinen) als LXC-Container auf einem Proxmox VE Host. Idempotent, reboot-sicher (systemd-Service, `onboot: 1`), mit eigener Verifikation.

> Hinweis: Das Upstream-Repo ist legacy (letzte Commits 2015, Anforderungen PHP 5.3+/MySQL, UI in PHP/Smarty). Vor Produktivbetrieb bitte einen gepflegten Fork verwenden (`BABESK_REPO` setzen) oder modernisieren. Das mitgelieferte `frontend/` ist ein React/Vite-Startpunkt für eine moderne UI, die gegen das PHP-Backend spricht.

## Einzeiler (als root auf dem Proxmox-Host)

An Commit gepinnt (empfohlen, raw.githubusercontent.com cached `main` teils minutenlang):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Babesk-Proxmox-Mensa-Kantine-Abrechnung/ae058bc2bec30e560ea431de864c3e998f147d9e/install/babesk.sh)"
```

Ungepinnt über `main` (Cache-Buster anhängen, falls eine alte Version geladen wird):

```bash
bash -c "$(wget -qLO - "https://raw.githubusercontent.com/HatchetMan111/Babesk-Proxmox-Mensa-Kantine-Abrechnung/main/install/babesk.sh?ts=$(date +%s)")"
```

## Optionen (Umgebungsvariablen)

| Variable | Standard | Bedeutung |
|---|---|---|
| `BABESK_CT_ID` | nächste freie ID (100-999) | Container-ID |
| `BABESK_PORT` | `8080` | Web-UI-Port im Container |
| `BABESK_REPO` | `https://github.com/LinuCC/babesk.git` | App-Repo |
| `BABESK_CORES` / `BABESK_RAM_MB` / `BABESK_DISK_GB` | `2` / `2048` / `8` | Ressourcen |
| `BABESK_TEMPLATE` / `BABESK_STORAGE` / `BABESK_BRIDGE` / `BABESK_NET` | Debian 12 / `local-lvm` / `vmbr0` / `dhcp` | Container-Netz/Storage |
| `BABESK_DRY_RUN=1` | aus | Testlauf ohne Proxmox (simuliert `pct`) |
| `BABESK_DEBUG=1` | aus | `bash -x` Debug-Log |

Beispiel mit fester ID und statischer IP:

```bash
BABESK_CT_ID=120 BABESK_NET="10.0.0.50/24,gw=10.0.0.1" \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/babesk.sh)"
```

## Was das Script tut

1. Prüft Host (root, `pct`, Template, Storage).
2. Vergibt die nächste freie CT-ID (oder nimmt `BABESK_CT_ID`).
3. Erstellt den LXC (unprivileged, `onboot: 1`, Hostname `babesk`) und startet ihn.
4. Installiert im Container: **PHP 7.4** (sury-Repo, da babesk PHP-5.3-era ist und auf PHP 8.2 an Altlasten scheitert) + Extensions, MariaDB, git, ufw; legt DB `babesk` + User an; klont das Repo nach `/opt/babesk`; erzeugt `databaseValues.php` / `config.php` aus den Vorlagen; schreibt ein Polyfill (`mcrypt_create_iv` u. a.) per `auto_prepend_file`, das die letzten PHP-7.2-Entfernungen abdeckt.
5. Spielt die Datenbank automatisch ein (dbv-Revisions 1..N als root, inkl. Default-Admin `administrator`/`root`). Schlägt das fehl, bleibt dbv als Browser-Fallback unter `/dbv/` erreichbar. Eine freundliche Startseite listet die drei Frontends.
6. Richtet `babesk.service` ein (PHP-Server auf `0.0.0.0:8080`, `Restart=always`, `After=network-online.target`), aktiviert ihn, öffnet Port 8080 in der Container-Firewall.
7. Verifiziert: `systemctl is-active babesk`, HTTP-Check auf `localhost:8080` und Admin-Seite ohne PHP-Fatal; gibt die finale URL `http://<CT-IP>:8080/` aus.

## Idempotenz / Update / Deinstall

- Erneutes Ausführen konfiguriert den bestehenden Container neu (apt idempotent, `git pull --ff-only`, DB mit `IF NOT EXISTS`).
- Update der App: `pct exec <CT-ID> -- git -C /opt/babesk pull --ff-only` puis `pct exec <CT-ID> -- systemctl restart babesk`
- Deinstallieren: `pct destroy <CT-ID> --purge`

## Debugging

Bei Fehlern gibt das Script die komplette Kette aus (Exit-Code, Zeile, Befehl, Host, Datum) plus Hinweis auf das Debug-Log:

```bash
BABESK_DEBUG=1 bash -x install/babesk.sh 2>&1 | tee babesk-install-debug.log
```

Logs im Container: `pct exec <CT-ID> -- journalctl -u babesk -n 100 --no-pager`

## Dateien

- `install/babesk.sh` - Proxmox-Install-Script (Einzeiler)
- `json/babesk.json` - Metadaten im Community-Scripts-Format
- `systemd/babesk.service` - systemd-Unit (wird vom Installer nach `/etc/systemd/system/` kopiert)
- `frontend/` - React/Vite-UI (Skeleton, Proxy auf das PHP-Backend in `vite.config.js`)
