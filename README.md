# Paperless-ngx — Dokumentenverwaltung / DMS

Gescannte Dokumente durchsuchbar archivieren (OCR, Volltextsuche, Tags, Korrespondenten).
Dritter Dienst auf **Andyserver** (Mac Mini), neben Immich und PrivatPortfolio.
Läuft komplett containerisiert auf der **bereits vorhandenen Colima-Docker-Runtime**
(dieselbe VM wie Immich) über Docker Compose — offizielles Paperless-ngx-Deployment.

> **Stand:** Dokumentenablage (`media/` + `data/` + `consume/` + `export/`) liegt seit
> 2026-08-31 auf der externen SSD `/Volumes/ServerData/paperless/` — siehe
> [Externe Platte](#externe-platte-für-die-dokumente). Postgres/Redis bleiben als
> Docker-Volumes intern. Autostart per launchd aktiv (`local.paperless`, 2026-08-28).

---

## Architektur

```
Colima (Docker-Runtime, launchd-Autostart — geteilt mit Immich)
  └─ Docker Compose  (Projekt "paperless")
       ├─ webserver   Paperless-ngx: Web-UI + API + Worker (Port 8000)
       ├─ db          PostgreSQL 18
       ├─ broker      Redis/Valkey (Task-Queue)
       ├─ gotenberg   Office-/E-Mail-Konvertierung nach PDF
       └─ tika        Text-/Metadaten-Extraktion aus Office-Dokumenten
```

## Zugriff

**http://andyserver.fritz.box:8000**

Nur im LAN, kein HTTPS, kein Internet-Zugriff (analog Immich).

| | |
|---|---|
| Admin-User | `andy` |
| Passwort | *(bei der Einrichtung generiert — siehe Passwortspeicher; mit `docker-compose exec webserver python3 manage.py changepassword andy` änderbar)* |

---

## Setup (Stand jetzt)

- Nutzt die vorhandene **Colima-VM** (`~/Servers/Immich/start-colima.sh`, jetzt **4 CPU / 8 GB / 100 GB** —
  von 6 auf 8 GB angehoben, damit Immich-ML und Paperless-OCR gleichzeitig laufen können; im
  Leerlauf belegen beide Stacks zusammen ~3 GB). Kein eigener Colima-Profil.
- Bedienung über **`docker-compose`** (mit Bindestrich) — `docker compose` als Subcommand ist auf
  diesem Rechner nicht verfügbar (wie bei Immich).
- `docker-compose.yml` abgeleitet vom offiziellen Template
  [`docker/compose/docker-compose.postgres-tika.yml`](https://github.com/paperless-ngx/paperless-ngx/tree/main/docker/compose).
  Angepasst gegenüber dem Default:
  - webserver-Image **auf `3.1.0` gepinnt** statt `:latest`
  - `data` / `media` / `consume` / `export` sind **Bind-Mounts auf den Host** (Pfade aus `.env`)
    statt Docker-Named-Volumes — damit die Ablage portabel ist; liegen seit 2026-08-31 auf der
    externen SSD (`/Volumes/ServerData/paperless/`, siehe [Externe Platte](#externe-platte-für-die-dokumente))
  - `db` (Postgres) und `broker` (Redis) bleiben **Named Volumes** → in der Colima-VM auf der
    internen SSD. Begründung wie bei Immich: eine Datenbank gehört **nicht** auf eine extern
    angesteckte Platte (Korruption bei Trennung / Sleep)
  - `USERMAP_UID=503` / `USERMAP_GID=1000` = User der Colima-VM (`colima ssh -- id`), damit die
    Dateien in den Bind-Mounts dem Host-User `andy` gehören
  - `PAPERLESS_CONSUMER_POLLING=30` — der Import-Ordner wird **gepollt** statt per inotify, weil
    virtiofs-Bind-Mounts keine zuverlässigen Datei-Events liefern
- Konfiguration in zwei Dateien (beide **nicht im Git**, Vorlagen `*.example` liegen bei):
  - `.env` — Compose-Ebene: Projektname, Port, Bind-Mount-Pfade, `PAPERLESS_DBPASS`
  - `docker-compose.env` — App-Konfig: `PAPERLESS_SECRET_KEY`, `PAPERLESS_TIME_ZONE=Europe/Berlin`,
    `PAPERLESS_OCR_LANGUAGE=deu+eng`, `PAPERLESS_URL`, Consumer-Optionen
- `SECRET_KEY` und `DBPASS` mit `python3 -c "import secrets; print(secrets.token_urlsafe(...))"` generiert.

---

## Bedienung

| Aktion | Befehl (in `~/Servers/Paperless`) |
|---|---|
| Starten | `docker-compose up -d` |
| Stoppen | `docker-compose down` |
| Status | `docker-compose ps` |
| Logs | `docker logs paperless-webserver-1 -f` |
| Update Paperless | Image-Tag in `docker-compose.yml` hochsetzen (aktuell `3.1.0`), dann `docker-compose pull && docker-compose up -d`. **Vorher** [Changelog](https://github.com/paperless-ngx/paperless-ngx/releases) lesen. |
| Admin-Passwort ändern | `docker-compose exec webserver python3 manage.py changepassword andy` |
| Weiteren Superuser | `docker-compose exec webserver python3 manage.py createsuperuser` |
| Backup (Export) | `docker-compose exec webserver document_exporter ../export` → Ergebnis liegt in `./export/` |
| Restore (Import) | Dateien nach `./export/` legen, dann `docker-compose exec webserver document_importer ../export` |
| Suchindex neu bauen | `docker-compose exec webserver python3 manage.py document_index reindex` |
| Colima hängt | `bash ~/Servers/Immich/start-colima.sh` (siehe Immich-README) |

**Dokumente importieren:** Dateien einfach nach `~/Servers/Paperless/consume/` kopieren — werden
innerhalb von ~30 s eingelesen, OCR-verarbeitet und danach aus `consume/` entfernt. Unterordner
werden als Tags übernommen (`PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS`).

---

## Autostart (launchd)

Installiert und aktiv seit 2026-08-28. Muster wie bei Immich: **LaunchDaemon** in der
`system`-Domain (nicht LaunchAgent), damit der Dienst unabhängig von einer eingeloggten
GUI-Session läuft. Das Skript ist ein Run-once-Job (`docker-compose up -d`, dann Ende) —
`launchctl print system/local.paperless` zeigt daher `state = not running` bei
`last exit code = 0`, das ist korrekt.

- `start-paperless.sh` — wartet bis zu 5 Min auf Docker (VM-Boot) und macht dann `docker-compose up -d`.
  Startet Colima **nicht** selbst — dafür ist `local.colima` zuständig (mit Fallback in
  `start-immich.sh`). Da alle Container `restart: unless-stopped` haben, kommen sie nach einem
  Reboot auch ohne dieses Skript hoch, sobald der Docker-Daemon läuft; das Skript ist die
  Absicherung für den Fall, dass Colima erst spät bereit ist.
- `local.paperless.plist` — der Daemon. Quelldatei liegt hier im Repo zur Referenz.

**Installieren** (einmalig, braucht `sudo` — bereits erledigt):

```bash
sudo cp ~/Servers/Paperless/local.paperless.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/local.paperless.plist
```

**Nach Änderung an der plist neu laden:**

```bash
sudo launchctl bootout system/local.paperless
sudo cp ~/Servers/Paperless/local.paperless.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/local.paperless.plist
```

Logs: `~/Library/Logs/paperless-launchd.log` (+ `-error.log`).

**Neustart von Andyserver:** sobald `local.colima` Docker hochgebracht hat, starten die Paperless-
Container von selbst (`restart: unless-stopped`) bzw. via `local.paperless`. Rechne mit 1–2 Min.

---

## Externe Platte für die Dokumente

**Umgezogen am 2026-08-31.** `media/`, `data/`, `consume/`, `export/` liegen jetzt unter
`/Volumes/ServerData/paperless/` (externe USB-SSD, APFS, dieselbe Platte wie Immichs Library).
**Postgres (`paperless_pgdata`) und Redis (`paperless_redisdata`) bleiben Docker-Volumes** in
der Colima-VM auf der internen SSD — DB gehört nicht auf eine extern angesteckte Platte.

Die Platte ist in `~/.colima/default/colima.yaml` als virtiofs-Mount eingetragen (zusammen mit
`/Users/andy` — **beide** müssen dort stehen, sonst mountet Colima `$HOME` nicht mehr; siehe
Immich-README). Kein Colima-Neustart für Paperless nötig, der Mount war schon da.

### Start-Absicherung

`start-paperless.sh` prüft vor `docker-compose up` die Sentinel-Datei
`/Volumes/ServerData/paperless/.disk-present`. Fehlt sie (Platte nicht gemountet), startet
Paperless **nicht** — sonst legt es leere Verzeichnisse an und „verliert" alle Dokumente. Ist
die Platte am Host, aber nicht in der VM sichtbar, macht das Skript einmal `colima restart`.

### Kür für den Umzug (falls nochmal nötig)

```bash
cd ~/Servers/Paperless && docker-compose down
mkdir -p /Volumes/ServerData/paperless
rsync -aH data media consume export /Volumes/ServerData/paperless/
date > /Volumes/ServerData/paperless/.disk-present
# .env: die 4 PAPERLESS_*_LOCATION auf /Volumes/ServerData/paperless/<name>
docker-compose up -d
# UI: Dokument öffnen (Original + Archiv-PDF laden), Suche testen, Doku-Anzahl prüfen
# dann altes data/ media/ consume/ export/ löschen
```

---

## Wichtige Pfade

| Pfad | Inhalt |
|---|---|
| `/Volumes/ServerData/paperless/media` | **Die Dokumente** (Originale + OCR-Archiv-PDFs + Thumbnails) — externe SSD |
| `/Volumes/ServerData/paperless/data` | Suchindex, Klassifikator-Modell, Logs (regenerierbar) |
| `/Volumes/ServerData/paperless/consume` | Import-Ordner (hier abgelegte Dateien werden eingelesen) |
| `/Volumes/ServerData/paperless/export` | Ziel für `document_exporter` (Backups) |
| Docker-Volume `paperless_pgdata` | PostgreSQL-Daten (in der Colima-VM) |
| Docker-Volume `paperless_redisdata` | Redis-Queue (in der Colima-VM) |

---

## Backup

Noch nicht eingerichtet. Zwei Wege:

1. **`document_exporter`** (s.o.) — schreibt Dokumente + Metadaten als portables Verzeichnis nach
   `./export/`. Unabhängig von Postgres-Version, für Migration/Archiv geeignet. Idealerweise per
   Cron + anschließendem Sync auf NAS / externe Platte.
2. **Dateiebene**: `media/` + `data/` sichern **und** `pg_dump` der DB
   (`docker-compose exec db pg_dump -U paperless paperless > dump.sql`).

Empfehlung sobald produktiv: nächtlicher `document_exporter` + Kopie außer Haus.

---

## Sicherheit / offene Punkte

- [x] **Autostart-Daemon installiert** (`local.paperless`, 2026-08-28)
- [x] **Dokumentenablage auf externe SSD** umgezogen (2026-08-31) — `/Volumes/ServerData/paperless/`
- [ ] **HTTPS** via nginx + mkcert (analog PrivatPortfolio) — aktuell nur HTTP im LAN
- [ ] **Backup** einrichten (nächtlicher `document_exporter`) — media/data liegen auf derselben
      externen Platte wie Immich; Dumps/Exports sollten woanders hin (interne SSD / NAS)
- [ ] Ersteinrichtung in der UI: Korrespondenten / Dokumenttypen / Tags anlegen, ggf.
      Mail-Konten für automatischen E-Mail-Import (`paperless_mail`)
- Kein Internet-Zugriff eingerichtet. Falls gewünscht: echtes Zertifikat (Let's Encrypt),
  Reverse-Proxy, starke Passwörter / 2FA, Fail2ban — wie in der Immich-README beschrieben.
