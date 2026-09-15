# CLAUDE.md – Hinweise für Claude Code

## Projekt
Native macOS-Menüleisten-App (Swift/AppKit), die die beiden selbstgehosteten
RustDesk-Serverdienste betreibt: **hbbs** (ID-Server) und **hbbr** (Relay).
**Ohne Homebrew, ohne Docker**, keine Laufzeitabhängigkeiten. Rust wird nur zum
Bauen der Serverprogramme gebraucht.

**Wichtige Abgrenzung:** hbbs und hbbr vermitteln nur. Fernsteuerbar wird eine
Maschine erst durch die offizielle **RustDesk-App** auf der gesteuerten Seite.
Diese App hier ersetzt sie nicht — wer danach fragt, meint fast immer das eine
und braucht beides.

## Zwei harte Vorgaben
Beide gelten für jede künftige Änderung, nicht nur für den ersten Wurf.

1. **Portabel und abhängigkeitsfrei.** Die fertige `.app` muss auf einem
   beliebigen Mac laufen. Alles Ausführbare liegt im Bundle, universal gebaut
   (arm64 + x86_64). Nichts darf gegen `/opt/homebrew` oder `/usr/local/lib`
   linken. `build_app.sh` prüft das am Ende selbst.
2. **Keine personenbezogenen Spuren.** Keine Namen, Adressen, Domains, IPs aus
   privaten Netzen oder Benutzerpfade in Code, IDs, Dateinamen, Doku oder
   Commits. Alles Standortabhängige ist Laufzeitkonfiguration in `UserDefaults`.
   **Vor jedem Commit `./Scripts/check-privacy.sh`** — das Skript prüft es.

## Architektur
- `Sources/RustDeskServer/main.swift` – Einstieg. Zwei Modi aus einem Binary:
  Supervisor (Env `RDS_HEADLESS=1`, so laufen die Daemons) oder
  `.accessory`-Steuer-App (kein Dock-Icon).
- `Config.swift` – `Role` (hbbs/hbbr) mit allen rollenabhängigen Pfaden, zentrale
  Namen, Env-Schlüssel und die Plist-Erzeugung zur Laufzeit.
- `Supervisor.swift` – startet das jeweilige Serverprogramm als Kindprozess,
  setzt/räumt den Absturzmarker, reicht SIGTERM/SIGINT durch, meldet unerwartete
  Neustarts per Mail.
- `DaemonControl.swift` – installiert und entfernt **beide** LaunchDaemons in
  **einem** Admin-Prompt (`osascript … with administrator privileges`).
- `AppDelegate.swift` – Menü: aktivieren/deaktivieren, Basisport, öffentlicher
  Schlüssel, Status je Rolle, Absturz-Mail, Login-Item, Log.
- `ServerKey.swift` – liest **nur** `id_ed25519.pub`. Der private Schlüssel darf
  nie in Menü, Log oder Mail auftauchen.
- `LogWindowController.swift` – Logfenster mit Umschalter hbbs/hbbr.
- `MailNotifier.swift`, `CrashMarker.swift` – aus dem Schwesterprojekt
  `ntp-server` übernommen, siehe dort für die Hintergründe.
- `Scripts/build-server-binaries.sh` – klont den Upstream (Tag `1.1.16`) und baut
  `hbbs`/`hbbr` universal nach `Vendored/`.
- `Scripts/check-privacy.sh` – die Datenschutzprüfung aus Vorgabe 2.
- `build_app.sh` – kompiliert universal und bündelt die `.app`.

Zur Laufzeit angelegt: `/usr/local/libexec/rustdeskserver-supervisor`,
`/usr/local/libexec/rustdesk-{hbbs,hbbr}`,
`/Library/LaunchDaemons/app.rustdeskserver.{hbbs,hbbr}.plist`,
`/usr/local/var/rustdeskserver/` (Schlüsselpaar, SQLite, Marker),
`/usr/local/var/log/rustdeskserver/{hbbs,hbbr}.log`.

## Build & Test
```bash
xcode-select --install      # nur falls Toolchain fehlt
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

./Scripts/build-server-binaries.sh
./build_app.sh
./Scripts/check-privacy.sh

# Serverprogramme ohne Daemon-Installation gegentesten (freie Testports):
mkdir -p /tmp/rdtest && cd /tmp/rdtest
TEST_HBBS=no RUST_LOG=info <repo>/Vendored/hbbs -p 31116 &
RUST_LOG=info <repo>/Vendored/hbbr -p 31117 -k _ &
ls -l    # id_ed25519, id_ed25519.pub und db_v2.sqlite3 müssen entstehen

# Supervisor headless testen, ohne root und ohne echte Mail:
RDS_HEADLESS=1 RDS_ROLE=hbbs RDS_PORT=31116 RDS_WORKDIR=/tmp/rdtest \
  RDS_BINARY=<repo>/Vendored/hbbs ./.build/release/RustDeskServer
```

## Fallen (teuer erkauft – nicht erneut hineinlaufen)
- **`libs/hbb_common` ist ein Git-Submodul.** Ein Klon ohne
  `--recurse-submodules` lässt cargo schon beim Laden des Manifests scheitern
  („failed to load manifest for workspace member"). Das Bauskript macht es
  richtig; bei einem Handklon daran denken.
- **Schlüsselpaar-Wettlauf zwischen hbbs und hbbr.** Beide teilen sich ein
  Arbeitsverzeichnis und würden bei gleichzeitigem Erststart je ein eigenes Paar
  erzeugen — danach akzeptiert das Relay die Clients des ID-Servers nicht.
  Deshalb erzeugt nur hbbs, und der hbbr-Supervisor **wartet** auf die Datei.
- **Rechte am privaten Schlüssel.** hbbs legt ihn mit der Standard-umask an, also
  für alle lesbar. Der hbbs-Supervisor engt ihn nachträglich auf 600 ein; das
  Arbeitsverzeichnis bleibt 755, damit die Menü-App den öffentlichen Teil lesen
  kann.
- **`codesign --deep` nicht benutzen.** Von Apple abgekündigt und bei
  mitgelieferten Programmen unzuverlässig. Von innen nach außen signieren: erst
  `hbbs`, dann `hbbr`, dann das Bundle.
- **Ausführbare Beilagen gehören nach `Contents/MacOS/`**, nicht nach
  `Contents/Resources/` — dort stolpert codesign darüber.
- **Menüleisten-Icon: 14 pt.** Nicht an die 22 pt der Python-Apps angleichen –
  dort skaliert rumps das Bild danach auf 20×20 herunter, nativ in AppKit landet
  die Punktgröße ungebremst in der Menüleiste.
- **Keine Top-Level-`var` in `main.swift`.** Dortige globale Variablen werden in
  Quelltext-Reihenfolge als Anweisungen initialisiert (nicht lazy wie in anderen
  Dateien); der Headless-Zweig läuft ganz oben. Zustand, der den Start überlebt,
  gehört in eine `static` Property.
- **Programme nie per `cp` überschreiben.** `cp` auf eine vorhandene Datei
  schreibt in dieselbe Inode; der Kernel hält deren alte Code-Signatur im
  Cache und tötet jeden weiteren Start mit `OS_REASON_CODESIGNING` (launchd:
  „spawn scheduled", Log leer). Deshalb stoppt `install()` erst beide Daemons
  und ersetzt die Programme per `rm -f` + `cp`. Nachgestellt: laufende
  Binärdatei in-place überschreiben → nächster Start exit 137.
- **Logs nie nach `/var/log`.** macOS-Updates löschen dort fremde Dateien.
  Weil die Daemons als `daemon` laufen, kann launchd die StandardOutPath-Datei
  in der root-eigenen `/var/log` nicht neu anlegen → Exit 78 (EX_CONFIG),
  Endlosschleife, alle Ports zu. Deshalb `/usr/local/var/log/rustdeskserver/`,
  das dem Dienstbenutzer gehört. `offerDaemonUpdate()` zieht Alt-
  Installationen beim App-Start nach.
- **`HOME` in der Plist setzen.** hbbs speichert beim Start eine Client-Config
  unter `$HOME/Library/Preferences/com.carriez.RustDesk/`. Das Home von
  `daemon` ist `/var/root` → „Failed to store config: Failed to create
  directory" bei jedem Start. `HOME` zeigt deshalb aufs Arbeitsverzeichnis.
  Neue Plist-Merkmale immer auch in `hasOutdatedPlist` aufnehmen, sonst
  bekommen bestehende Installationen sie nie.
- **Die App läuft produktiv aus `dist/`.** `build_app.sh` bricht ab, solange sie
  läuft — sonst löscht der Build das Bundle unter dem laufenden Prozess weg.
  Erst über das Menü beenden lassen.

## Bekannte Grenzen / sinnvolle Ausbaustufen
- **Notarisierung.** Die App ist selbstsigniert; auf fremden Macs braucht der
  Erststart Rechtsklick → Öffnen. Offen, genau wie im Schwesterprojekt.
- **Zugriffs-ACL.** Die Dienste lauschen auf allen Schnittstellen. Solange kein
  Port ins Internet freigegeben ist, unkritisch; eine Bindung an eine
  Schnittstelle bräuchte Upstream 1.1.17+ (Option `-b`/`BIND`).
- **Upstream-Version.** Fest auf Tag `1.1.16`. Beim Anheben prüfen, ob `-b` nun
  verfügbar ist und ob sich die Portlogik von `hbbr` geändert hat (`-p` setzt den
  Port exakt, die Env-Variable `PORT` dagegen auf `PORT+1`).

## Stil & Konventionen
- Deutsch in UI und Kommentaren. Direkt, knapp, keine unnötigen Abhängigkeiten.
- **Neutrale Bezeichner – keine Personennamen** in Code, IDs, Dateinamen oder
  Doku. Schema: `app.rustdeskserver` (Daemon-Labels `app.rustdeskserver.hbbs`
  bzw. `.hbbr`, Programme `/usr/local/libexec/rustdesk-hbbs`). Bei neuen
  Identifiern fortführen.
- Fertige Änderungen sofort committen **und** pushen, direkt auf `main`.
