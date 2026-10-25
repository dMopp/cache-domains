#!/bin/sh
# -----------------------------------------------------------------------------
# OPNsense Unbound LanCache DNS Generator (All Platforms, Dual-Stack, Fail-safe)
# -----------------------------------------------------------------------------

set -eu
umask 077

LANCACHE_IP4="192.168.1.24" ### IPv4 of Container
LANCACHE_IP6="fd11:192:168:1::24" ### IPv6 of Container

OUTPUT_FILE="/usr/local/etc/unbound.opnsense.d/lancache_all_platforms.conf"
BACKUP_FILE="${OUTPUT_FILE}.bak"

BASE_URL="https://raw.githubusercontent.com/uklans/cache-domains/refs/heads/master"

# Erweiterbar: weitere Plattformen einfach hier ergänzen.
SERVICES="blizzard steam xboxlive nintendo"

MIN_DOMAINS=1

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lancache.XXXXXX")
NEW_FILE="$TMP_DIR/lancache.conf"
BACKUP_TMP="$TMP_DIR/previous.conf"
INSTALL_TMP="$(dirname "$OUTPUT_FILE")/.lancache.$$.tmp"

INSTALLED=0
HAD_OLD_FILE=0

cleanup() {
    rc=$?

    if [ "$rc" -ne 0 ] && [ "$INSTALLED" -eq 1 ]; then
        echo "FEHLER: Stelle vorherige Konfiguration wieder her..." >&2

        if [ "$HAD_OLD_FILE" -eq 1 ]; then
            cp "$BACKUP_TMP" "$INSTALL_TMP" &&
                mv -f "$INSTALL_TMP" "$OUTPUT_FILE" || {
                    echo "KRITISCH: Rollback fehlgeschlagen!" >&2
                    exit 1
                }

            if ! configctl unbound check; then
                echo "KRITISCH: Wiederhergestellte Konfiguration ist ungueltig!" >&2
                exit 1
            fi

            configctl unbound restart || {
                echo "KRITISCH: Unbound-Neustart nach Rollback fehlgeschlagen!" >&2
                exit 1
            }
        else
            rm -f "$OUTPUT_FILE"
        fi
    fi

    rm -f "$INSTALL_TMP"
    rm -rf "$TMP_DIR"
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

echo "Starte LanCache DNS Generator..."

# Voraussetzungen prüfen
if [ ! -d "$(dirname "$OUTPUT_FILE")" ]; then
    echo "FEHLER: Zielverzeichnis existiert nicht." >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || {
    echo "FEHLER: curl nicht gefunden." >&2
    exit 1
}

command -v configctl >/dev/null 2>&1 || {
    echo "FEHLER: configctl nicht gefunden." >&2
    exit 1
}

# Vorhandene Konfiguration sichern
if [ -f "$OUTPUT_FILE" ]; then
    cp -p "$OUTPUT_FILE" "$BACKUP_TMP"
    HAD_OLD_FILE=1
fi

# Neue Konfiguration vorbereiten
echo "server:" > "$NEW_FILE"
TOTAL_DOMAINS=0

for SERVICE in $SERVICES; do
    echo "Lade CDN-Liste fuer: $SERVICE..."

    TMP_FILE="$TMP_DIR/$SERVICE.txt"
    URL="$BASE_URL/$SERVICE.txt"

    # Download muss erfolgreich und nicht leer sein.
    if ! curl --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 120 \
        "$URL" -o "$TMP_FILE"; then
        echo "FEHLER: Download fuer $SERVICE fehlgeschlagen. Keine Aenderung." >&2
        exit 1
    fi

    if [ ! -s "$TMP_FILE" ]; then
        echo "FEHLER: Liste fuer $SERVICE ist leer. Keine Aenderung." >&2
        exit 1
    fi

    # Domainliste validieren und zählen.
    COUNT=$(awk '
        {
            sub(/\r$/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            sub(/^\*\./, "")
            sub(/^\./, "")

            if ($0 == "")
                next

            if ($0 !~ /^[A-Za-z0-9.-]+$/ ||
                $0 ~ /\.\./ ||
                $0 ~ /^[-.]/ ||
                $0 ~ /[-.]$/) {
                print "Ungueltige Domain: " $0 > "/dev/stderr"
                exit 2
            }

            count++
        }
        END {
            if (count > 0)
                print count
            else
                exit 1
        }
    ' "$TMP_FILE") || {
        echo "FEHLER: Liste fuer $SERVICE ist ungueltig. Keine Aenderung." >&2
        exit 1
    }

    echo "$SERVICE: $COUNT Eintraege."

    # Gültige Domains in die temporäre Konfiguration übernehmen.
    # Duplikate werden plattformübergreifend entfernt.
    awk -v ip4="$LANCACHE_IP4" -v ip6="$LANCACHE_IP6" '
        {
            sub(/\r$/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            sub(/^\*\./, "")
            sub(/^\./, "")

            if ($0 == "")
                next

            domain = tolower($0)

            if (seen[domain]++)
                next

            printf "    local-zone: \"%s.\" redirect\n", domain
            printf "    local-data: \"%s. A %s\"\n", domain, ip4
            printf "    local-data: \"%s. AAAA %s\"\n", domain, ip6
        }
    ' "$TMP_FILE" >> "$NEW_FILE"

    TOTAL_DOMAINS=$((TOTAL_DOMAINS + COUNT))
done

# Plausibilitätsprüfung der fertigen Datei
ZONE_COUNT=$(grep -c '^[[:space:]]*local-zone:' "$NEW_FILE" || true)
A_COUNT=$(grep -c '^[[:space:]]*local-data:.* A ' "$NEW_FILE" || true)
AAAA_COUNT=$(grep -c '^[[:space:]]*local-data:.* AAAA ' "$NEW_FILE" || true)

if [ "$ZONE_COUNT" -lt "$MIN_DOMAINS" ] ||
   [ "$ZONE_COUNT" -ne "$A_COUNT" ] ||
   [ "$ZONE_COUNT" -ne "$AAAA_COUNT" ]; then
    echo "FEHLER: Generierte Konfiguration ist unvollstaendig. Keine Aenderung." >&2
    exit 1
fi

echo "Insgesamt $ZONE_COUNT eindeutige Domains."

# Datei im selben Verzeichnis vorbereiten und atomar ersetzen.
cp "$NEW_FILE" "$INSTALL_TMP"
chmod 0644 "$INSTALL_TMP"
mv -f "$INSTALL_TMP" "$OUTPUT_FILE"
INSTALLED=1

# Gesamte Unbound-Konfiguration prüfen.
echo "Pruefe Unbound-Konfiguration..."

if ! configctl unbound check; then
    echo "FEHLER: Unbound-Konfiguration ungueltig." >&2
    exit 1
fi

# Unbound neu starten.
echo "Starte Unbound neu..."

if ! configctl unbound restart; then
    echo "FEHLER: Unbound-Neustart fehlgeschlagen." >&2
    exit 1
fi

# Backup nach erfolgreicher Aktivierung aktualisieren.
cp "$OUTPUT_FILE" "$BACKUP_FILE"

INSTALLED=0

echo "Erfolg: LanCache-Konfiguration aktualisiert."
echo "Plattformen: $SERVICES"
echo "Eindeutige Domains: $ZONE_COUNT"
echo "Backup: $BACKUP_FILE"
