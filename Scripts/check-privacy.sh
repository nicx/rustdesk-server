#!/usr/bin/env bash
set -uo pipefail

# Prüft, dass nichts Personen- oder Standortbezogenes im Repo landet.
#
# Warum als Skript und nicht als Vorsatz: die Konvention muss auch bei späteren
# Änderungen noch greifen, auch wenn niemand mehr daran denkt. Vor jedem Commit
# ausführen.
#
# Die Muster sind bewusst grob. Ein Treffer ist nicht zwingend ein Fehler, aber
# immer eine Stelle, die jemand anschauen muss.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Nur versionierte Dateien prüfen: vendor/, dist/ und .build/ sind fremd bzw.
# Baumüll und stehen ohnehin in .gitignore.
FILES="$(git ls-files 2>/dev/null || true)"
if [[ -z "${FILES}" ]]; then
  echo "Keine versionierten Dateien — nichts zu prüfen."
  exit 0
fi

fail=0

# report <Beschriftung> <Muster> [Ausnahmemuster]
# Das optionale dritte Argument filtert erlaubte Treffer heraus. BSD-grep kennt
# kein Lookahead, deshalb zwei Durchgänge statt eines cleveren Musters.
report() {
  local label="$1" pattern="$2" allow="${3:-}"
  local hits
  hits="$(printf '%s\n' ${FILES} | xargs grep -nIE --color=never "${pattern}" 2>/dev/null \
          | grep -v '^Scripts/check-privacy.sh:' || true)"
  if [[ -n "${allow}" && -n "${hits}" ]]; then
    hits="$(printf '%s\n' "${hits}" | grep -vE "${allow}" || true)"
  fi
  if [[ -n "${hits}" ]]; then
    echo "✗ ${label}"
    printf '%s\n' "${hits}" | sed 's/^/    /'
    fail=1
  else
    echo "✓ ${label}"
  fi
}

# Adressen aus privaten Netzen verraten die Topologie des Heimnetzes und haben
# im Repo nichts zu suchen. Loopback (127.0.0.0/8) und die für Dokumentation
# reservierten Bereiche nach RFC 5737 sind allgemeingültig und erlaubt.
report "keine Adressen aus privaten Netzen" \
  '(^|[^0-9.])(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))(\.[0-9]{1,3}){2,3}([^0-9.]|$)' \
  '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.'

# Echte Mailadressen. example.invalid und die übrigen reservierten Domains sind
# die vorgesehenen Platzhalter und ausdrücklich erlaubt, ebenso die
# noreply-Adresse der Git-Identität.
report "keine echten Mailadressen" \
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  '@example\.(invalid|com|org|net)|@rustdesk\.com|users\.noreply\.github\.com'

# Pfade des Baurechners.
report "keine Benutzerpfade" '/Users/[A-Za-z0-9._-]+'

# Eigene Domains und Hostnamen dürfen nicht auftauchen; die Doku beschreibt
# generisch "die LAN-Adresse des Servers".
report "keine eigenen Hostnamen/Domains" '\b(netbag|macmini|mac-mini)\b'

echo ""
if [[ ${fail} -ne 0 ]]; then
  echo "Datenschutzprüfung fehlgeschlagen — Treffer oben prüfen und entfernen." >&2
  exit 1
fi
echo "Datenschutzprüfung bestanden."
