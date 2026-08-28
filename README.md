# Paperless-ngx — Dokumentenverwaltung / DMS

Gescannte Dokumente durchsuchbar archivieren (OCR, Volltextsuche, Tags, Korrespondenten).
Dritter Dienst auf **Andyserver** (Mac Mini), neben Immich und PrivatPortfolio.
Läuft komplett containerisiert auf der **bereits vorhandenen Colima-Docker-Runtime**
(dieselbe VM wie Immich) über Docker Compose — offizielles Paperless-ngx-Deployment.

> **Stand: Proof of Concept.** Alle Daten liegen aktuell lokal unter `~/Servers/Paperless/`.
> Die Dokumentenablage (`media/`) zieht später auf die externe SSD um — siehe
> [Externe Platte](#externe-platte-für-die-dokumente-geplant). Autostart per launchd ist
> vorbereitet, aber noch **nicht installiert** (siehe [Autostart](#autostart-launchd)).

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
    statt Docker-Named-Volumes — damit die Ablage portabel ist und `media` später auf die externe
    SSD umziehen kann
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

Vorbereitet, aber **noch nicht aktiv**. Muster wie bei Immich: **LaunchDaemon** in der
`system`-Domain (nicht LaunchAgent), damit der Dienst unabhängig von einer eingeloggten
GUI-Session läuft.

- `start-paperless.sh` — wartet bis zu 5 Min auf Docker (VM-Boot) und macht dann `docker-compose up -d`.
  Startet Colima **nicht** selbst — dafür ist `local.colima` zuständig (mit Fallback in
  `start-immich.sh`). Da alle Container `restart: unless-stopped` haben, kommen sie nach einem
  Reboot auch ohne dieses Skript hoch, sobald der Docker-Daemon läuft; das Skript ist die
  Absicherung für den Fall, dass Colima erst spät bereit ist.
- `local.paperless.plist` — der Daemon. Quelldatei liegt hier im Repo zur Referenz.

**Installieren** (einmalig, braucht `sudo`):

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

## Externe Platte für die Dokumente (geplant)

Sobald die externe SSD am Server hängt, zieht **nur `media/`** (Originale + Archiv-PDFs) auf die
Platte um. `data/` (Suchindex, Klassifikator — aus den Dokumenten neu aufbaubar) und die
**Postgres-DB bleiben auf der internen SSD** (Begründung siehe Immich-README: DB nicht auf
extern angesteckte Platte).

Die externe SSD kommt bei Colima (`vz`, kein USB-Passthrough) per virtiofs über `/Volumes/<Name>`
in die VM — derselbe Weg wie die Bind-Mounts jetzt.

### Schritte für den Umzug

```bash
cd ~/Servers/Paperless
docker-compose down
mkdir -p /Volumes/<PLATTE>/paperless
rsync -aH --info=progress2 media/ /Volumes/<PLATTE>/paperless/media/
```

Dann in `.env` setzen:

```
PAPERLESS_MEDIA_LOCATION=/Volumes/<PLATTE>/paperless/media
```

`docker-compose up -d`, in der UI ein Dokument öffnen (lädt Original + Archiv-PDF → beide Pfade
ok), dann altes `media/` löschen. `PAPERLESS_CONSUMER_POLLING` bleibt gesetzt (virtiofs).

> Prüfen, ob die Platte in den macOS-Energieeinstellungen **nicht in den Ruhezustand** geht,
> solange der Server läuft.

---

## Wichtige Pfade

| Pfad | Inhalt |
|---|---|
| `~/Servers/Paperless/media` | **Die Dokumente** (Originale + OCR-Archiv-PDFs) — zieht später auf die externe SSD |
| `~/Servers/Paperless/data` | Suchindex, Klassifikator-Modell, Logs — bleibt lokal |
| `~/Servers/Paperless/consume` | Import-Ordner (hier abgelegte Dateien werden eingelesen) |
| `~/Servers/Paperless/export` | Ziel für `document_exporter` (Backups) |
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

- [ ] **Autostart-Daemon installieren** (`sudo`, s.o.) — aktuell startet Paperless nach einem
      Reboot nur mit, weil die Container `restart: unless-stopped` haben; der Daemon ist die
      saubere Absicherung.
- [ ] **HTTPS** via nginx + mkcert (analog PrivatPortfolio) — aktuell nur HTTP im LAN
- [ ] **`media/` auf externe SSD** umziehen, sobald vorhanden
- [ ] **Backup** einrichten (nächtlicher `document_exporter`)
- [ ] Ersteinrichtung in der UI: Korrespondenten / Dokumenttypen / Tags anlegen, ggf.
      Mail-Konten für automatischen E-Mail-Import (`paperless_mail`)
- Kein Internet-Zugriff eingerichtet. Falls gewünscht: echtes Zertifikat (Let's Encrypt),
  Reverse-Proxy, starke Passwörter / 2FA, Fail2ban — wie in der Immich-README beschrieben.
