# RustDesk Server (macOS-Menüleisten-App)

Betreibt die beiden selbstgehosteten RustDesk-Serverdienste auf einem Mac und
verwaltet sie über die Menüleiste — ohne Terminal, ohne Docker, ohne Homebrew.

> **Nicht zu verwechseln mit `rustdesk/rustdesk-server`.** Dieses Projekt ist
> kein Fork und kein Ersatz. Es baut die dortigen Serverprogramme unverändert
> für macOS und packt sie in eine App, die sie als LaunchDaemons einrichtet und
> überwacht. Der Serverquellcode kommt vollständig vom Upstream.

## Was die Dienste tun — und was nicht

| Dienst | Aufgabe |
| --- | --- |
| `hbbs` | ID-Server: löst eine RustDesk-ID auf eine erreichbare Adresse auf |
| `hbbr` | Relay: reicht Pakete durch, wenn kein Direktweg zustande kommt |

Beide **vermitteln nur**. Sie sehen keinen Bildschirm und bedienen keine
Eingabegeräte — sie ersetzen lediglich die öffentlichen Server von RustDesk.
Fernsteuerbar wird eine Maschine erst durch die **RustDesk-App** selbst, die auf
der gesteuerten Seite laufen muss. Diese App hier ersetzt sie nicht.

## Warum es das Projekt gibt

Die offiziellen `rustdesk-server`-Releases liefern nur Linux- und
Windows-Binaries. Für macOS gibt es keines, auch nicht über Homebrew oder in den
bekannten Forks. Die Quellen haben aber einen eigenen macOS-Zweig und bauen
nativ — es fehlte nur die Verpackung.

## Belegte Ports

Bei Basisport `P` (Standard 21116):

| Port | Protokoll | Dienst |
| --- | --- | --- |
| `P-1` | TCP | hbbs, NAT-Typ-Test |
| `P` | TCP + UDP | hbbs, Hauptport |
| `P+1` | TCP | hbbr, Relay |
| `P+2` | TCP | hbbs, WebSocket |
| `P+3` | TCP | hbbr, WebSocket |

Alle liegen über 1024. Die Dienste laufen deshalb unprivilegiert; Administrator-
rechte werden nur einmalig beim Einrichten der LaunchDaemons abgefragt.

## Bauen

```bash
# einmalig: Rust-Toolchain (installiert nach ~/.cargo, unabhängig von Homebrew)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

./Scripts/build-server-binaries.sh   # holt die Upstream-Quellen, baut hbbs + hbbr
./build_app.sh                       # bündelt alles zu dist/RustDeskServer.app
open dist/RustDeskServer.app
```

Rust wird **nur zum Bauen** gebraucht. Die fertige App bringt `hbbs` und `hbbr`
als Universal-Binaries (arm64 + x86_64) im Bundle mit und läuft auf jedem Mac
ohne weitere Vorbereitung. `build_app.sh` prüft das am Ende selbst: Architektur,
Fremdbibliotheken und Pfade des Baurechners.

Für eine stabile Code-Identität mit eigenem Zertifikat:

```bash
CODESIGN_IDENTITY="nicx Selfsign" ./build_app.sh
```

Ohne diese Identität wird ad-hoc signiert. Die App ist nicht notarisiert; auf
einem fremden Mac braucht der Erststart deshalb Rechtsklick → Öffnen.

## Einrichten

1. App starten, im Menü **Server aktivieren**. Ein Administrator-Prompt richtet
   beide LaunchDaemons ein; sie starten danach bei jedem Boot, auch ohne Login.
2. Im Menü **Öffentlichen Schlüssel kopieren**. `hbbs` erzeugt das Schlüsselpaar
   beim ersten Start; nur der öffentliche Teil wird je angezeigt oder kopiert.
3. In **jedem** RustDesk-Client unter Einstellungen → Netzwerk →
   ID-/Relay-Server eintragen:
   - **ID-Server:** die LAN-Adresse dieses Macs
   - **Key:** der kopierte öffentliche Schlüssel
   - **Relay:** leer lassen — der Client leitet es aus dem ID-Server ab, solange
     `hbbr` auf derselben Adresse und dem Folgeport läuft
4. Auf der gesteuerten Maschine zusätzlich die offizielle RustDesk-App
   einrichten (Bildschirmaufnahme und Bedienungshilfen freigeben, festes
   Passwort setzen).

## Erreichbarkeit von außen

Die Dienste sprechen rohes TCP und UDP, kein HTTP — ein HTTP-Reverse-Proxy
bringt hier nichts. Wer von unterwegs zugreifen will, nimmt am besten ein VPN
ins eigene Netz; dann bleibt alles lokal und es muss kein Port ins Internet
geöffnet werden.

## Aufbau

- `Sources/RustDeskServer/main.swift` — Einstieg, zwei Betriebsarten aus einem
  Binary: Menüleisten-App oder Supervisor (Env `RDS_HEADLESS`).
- `Supervisor.swift` — startet `hbbs` bzw. `hbbr` als Kindprozess, setzt den
  Absturzmarker, reicht Signale durch und meldet unerwartete Neustarts.
- `DaemonControl.swift` — richtet beide LaunchDaemons in einem einzigen
  Administrator-Prompt ein und entfernt sie wieder.
- `Config.swift` — alle Namen, Pfade und die Plist-Erzeugung.
- `AppDelegate.swift` — Menü, Status, Portwechsel, Schlüsselanzeige.
- `ServerKey.swift`, `LogWindowController.swift`, `MailNotifier.swift`,
  `CrashMarker.swift` — Schlüssel, Logfenster, Absturz-Mail.
- `Scripts/build-server-binaries.sh` — baut `hbbs`/`hbbr` aus dem Upstream.
- `Scripts/check-privacy.sh` — prüft vor jedem Commit, dass nichts Personen-
  oder Standortbezogenes im Repo landet.

## Zur Laufzeit angelegte Dateien

| Pfad | Inhalt |
| --- | --- |
| `/usr/local/libexec/rustdeskserver-supervisor` | Supervisor (Kopie der App-Binärdatei) |
| `/usr/local/libexec/rustdesk-hbbs`, `-hbbr` | die Serverprogramme |
| `/Library/LaunchDaemons/app.rustdeskserver.*.plist` | die beiden Daemons |
| `/usr/local/var/rustdeskserver/` | Schlüsselpaar, SQLite-Datei, Absturzmarker |
| `/usr/local/var/log/rustdeskserver/hbbs.log`, `hbbr.log` | Logs der Dienste (bewusst nicht in `/var/log`, siehe unten) |

„Server deaktivieren" entfernt Daemons und Programme, lässt das
Arbeitsverzeichnis aber stehen: ein neues Schlüsselpaar würde jeden bereits
eingerichteten Client aussperren.

Die Logs liegen nicht in `/var/log`, weil macOS-Updates dort fremde Dateien
löschen. launchd öffnet die Logdatei als Dienstbenutzer und darf sie in der
root-eigenen `/var/log` nicht neu anlegen — der Dienst startete dann gar nicht
mehr. Ältere Installationen erkennt die App beim Start und bietet an, sie zu
aktualisieren.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Die Serverprogramme `hbbs` und `hbbr` stammen aus
[rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server) und
stehen unter deren eigener Lizenz (AGPL-3.0). Sie werden hier unverändert
gebaut und mitgeliefert.
