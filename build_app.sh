#!/usr/bin/env bash
set -euo pipefail

# Baut RustDeskServer.app mit Apple-Bordmitteln (Swift-Toolchain aus den Command
# Line Tools). Kein Homebrew, kein Xcode-GUI nötig.
#
# hbbs und hbbr müssen vorher gebaut sein:  ./Scripts/build-server-binaries.sh
# Sie wandern mit ins Bundle, damit die fertige App auf jedem Mac ohne
# Vorbereitung läuft.

APP_NAME="RustDeskServer"
DISPLAY_NAME="RustDesk Server"
BUNDLE_ID="app.rustdeskserver"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
VENDORED="Vendored"

# Signier-Identität. Default "-" = ad-hoc: baut ohne Zertifikat, vergibt aber keine
# Code-Identität — der CDHash wechselt bei jedem Rebuild, macOS erkennt die App nicht
# wieder und verwirft erteilte Berechtigungen (Mitteilungen, Gatekeeper). Mit stabiler
# selbstsignierter Identität bleiben sie erhalten:
#     CODESIGN_IDENTITY="nicx Selfsign" ./build_app.sh
# Verfügbare Identitäten: security find-identity -v -p codesigning
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# Läuft die App aus genau diesem dist/, würde der Build ihr das Bundle unter den Füßen
# weglöschen: der Prozess liefe mit ALTEM Code aus einem gelöschten Bundle weiter, macOS
# graut ihn aus, das Menü reagiert nicht mehr — beenden ginge nur noch per `kill`.
# Betrifft nur die Steuer-App; die Serverdienste laufen als LaunchDaemons unabhängig
# weiter. Aus /Applications gestartete Instanzen sind unkritisch.
RUNNING="$(pgrep -f "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" || true)"
if [[ -n "${RUNNING}" ]]; then
  echo "ABBRUCH: ${APP_NAME} läuft gerade aus $(pwd)/${DIST_DIR} (PID: ${RUNNING//$'\n'/ })." >&2
  echo "         Der Build würde das laufende Bundle löschen." >&2
  echo "         Erst die App beenden (Menüleiste -> Beenden), dann erneut bauen." >&2
  exit 1
fi

for bin in hbbs hbbr; do
  if [[ ! -x "${VENDORED}/${bin}" ]]; then
    echo "ABBRUCH: ${VENDORED}/${bin} fehlt." >&2
    echo "         Erst ./Scripts/build-server-binaries.sh ausführen." >&2
    exit 1
  fi
done

# Universal bauen, damit die App auch auf Intel-Macs läuft.
#
# Nicht über "swift build --arch arm64 --arch x86_64": das verlangt xcbuild aus
# dem vollen Xcode und scheitert mit den blossen Command Line Tools. Stattdessen
# jede Architektur einzeln über --triple bauen und danach mit lipo zusammenlegen —
# das kommt mit den CLT aus. Früher per "-Xswiftc -target <arch>"; seit den CLT 27
# (Swift 6.4) kompiliert SwiftPM dabei trotzdem für den Host und scheitert beim
# x86_64-Link an "_main" — --triple setzt die Zielarchitektur fürs ganze Build.
ARCHS=(arm64 x86_64)
BUILT_SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "==> Baue Release-Binary für ${arch}…"
  swift build -c release --scratch-path ".build/${arch}" \
    --triple "${arch}-apple-macosx13.0"
  BUILT_SLICES+=(".build/${arch}/release/${APP_NAME}")
done

BUILT=".build/${APP_NAME}-universal"
lipo -create -output "${BUILT}" "${BUILT_SLICES[@]}"

echo "==> Erzeuge ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILT}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
# hbbs/hbbr sind mitgelieferte Programme und gehören neben die App-Binärdatei.
# Nach Resources dürfen sie nicht: dort stolpert codesign über ausführbare Dateien.
cp "${VENDORED}/hbbs" "${APP_BUNDLE}/Contents/MacOS/hbbs"
cp "${VENDORED}/hbbr" "${APP_BUNDLE}/Contents/MacOS/hbbr"
chmod 755 "${APP_BUNDLE}/Contents/MacOS/"*

# Debug-Symbole raus: sie enthalten die Pfade des Baurechners und haben in einer
# weitergegebenen App nichts zu suchen.
strip -S "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [[ "${CODESIGN_IDENTITY}" != "-" ]] \
   && ! security find-identity -v -p codesigning | grep -qF "${CODESIGN_IDENTITY}"; then
  echo "HINWEIS: Identität \"${CODESIGN_IDENTITY}\" nicht im Schlüsselbund — signiere ad-hoc." >&2
  CODESIGN_IDENTITY="-"
fi

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "==> Signatur: ad-hoc (Hinweis: CODESIGN_IDENTITY setzen für stabile Identität)"
else
  echo "==> Signatur: ${CODESIGN_IDENTITY}"
fi
# Von innen nach außen signieren. Kein --deep: das ist von Apple abgekündigt und
# behandelt mitgelieferte Programme nicht zuverlässig.
codesign --force --options runtime --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}/Contents/MacOS/hbbs"
codesign --force --options runtime --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}/Contents/MacOS/hbbr"
codesign --force --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}"
codesign --verify --strict "${APP_BUNDLE}"

echo ""
echo "==> Portabilitätsprüfung"
for f in "${APP_BUNDLE}/Contents/MacOS/"*; do
  printf '    %-16s %s\n' "$(basename "$f")" "$(lipo -info "$f" | sed 's/.*: //')"
  # Bei Fat-Binaries schreibt otool je Architektur eine Kopfzeile — nur die
  # eingerückten Bibliothekszeilen zählen, sonst schlägt die Prüfung immer an.
  foreign="$(otool -L "$f" | grep -E '^[[:space:]]+/' \
             | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)' || true)"
  if [[ -n "${foreign}" ]]; then
    echo "    WARNUNG: $(basename "$f") hat Laufzeitabhängigkeiten außerhalb des Systems:" >&2
    printf '%s\n' "${foreign}" >&2
  fi
done
LEAKED="$(strings "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null | grep -c '/Users/' || true)"
if [[ "${LEAKED}" -gt 0 ]]; then
  echo "    WARNUNG: ${LEAKED} Verweise auf /Users/ im Binary (Pfade des Baurechners)." >&2
fi

echo ""
echo "==> Fertig: $(pwd)/${APP_BUNDLE}"
echo "    Start: open ${APP_BUNDLE}"
echo "    Erststart ggf. via Rechtsklick > Öffnen (Gatekeeper)."
