#!/bin/bash
# Wartet auf den von Colima verwalteten Docker-Daemon und startet dann die
# Paperless-Container. Laeuft (via LaunchDaemon local.paperless) parallel zu
# local.colima / local.immich.
#
# Colima wird hier NICHT selbst gestartet — dafuer ist local.colima zustaendig
# (mit Fallback in ~/Servers/Immich/start-immich.sh). Dieses Skript wartet nur
# lange genug, dass Docker nach einem Boot sicher da ist.
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

DOCKER=/opt/homebrew/bin/docker
COMPOSE=/opt/homebrew/bin/docker-compose

wait_for_docker() {
    # $1 = Anzahl Versuche a 5 s
    local i
    for i in $(seq 1 "$1"); do
        "$DOCKER" info >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

# media/ + data/ liegen auf der externen SSD "ServerData". Fehlt die Sentinel-Datei,
# ist die Platte nicht gemountet -> Paperless NICHT starten, sonst legt es leere
# Verzeichnisse an und "verliert" scheinbar alle Dokumente.
DISK_SENTINEL="/Volumes/ServerData/paperless/.disk-present"
for i in $(seq 1 18); do
    [ -f "$DISK_SENTINEL" ] && break
    sleep 5
done
if [ ! -f "$DISK_SENTINEL" ]; then
    echo "$(date '+%F %T') Externe Platte fehlt ($DISK_SENTINEL) - Paperless wird NICHT gestartet" >&2
    exit 1
fi

# bis zu 5 Min auf Docker warten (VM-Boot nach unsauberem Shutdown kann dauern,
# inkl. Colima-Fallback aus start-immich.sh)
if ! wait_for_docker 60; then
    echo "$(date '+%F %T') Docker nicht erreichbar - Abbruch" >&2
    exit 1
fi

# Sieht die VM die Platte? Wenn nicht (Colima startete vor dem Platten-Mount),
# einmal neu starten, damit der virtiofs-Mount greift.
if ! /opt/homebrew/bin/colima ssh -- test -f "$DISK_SENTINEL" 2>/dev/null; then
    echo "$(date '+%F %T') Platte am Host, aber nicht in der VM - colima restart"
    /opt/homebrew/bin/colima restart
    wait_for_docker 24 || { echo "$(date '+%F %T') Docker nach colima restart weg - Abbruch" >&2; exit 1; }
fi

exec "$COMPOSE" up -d
