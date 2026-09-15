import AppKit
import ServiceManagement
import UserNotifications

// Reine Steuer-App (Menüleiste) für die beiden RustDesk-Serverprozesse. Sie
// installiert und entfernt die LaunchDaemons, ändert den Basisport, zeigt den
// öffentlichen Schlüssel und Status/Log. Die Server selbst laufen unabhängig
// von dieser App weiter, auch wenn sie beendet wird.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var iconStopped: NSImage?   // Outline – Dienste gestoppt
    private var iconRunning: NSImage?   // gefüllt – Dienste laufen

    private var basePort: UInt16 = Config.defaultBasePort
    private let basePortKey = "basePort"

    // Mail-Konfiguration liegt in UserDefaults und reist von dort über die Plist
    // zum Supervisor. Adressen sind Laufzeitdaten und gehören nicht in den Code.
    private var mail = MailConfig(host: MailConfig.defaultHost, port: MailConfig.defaultPort,
                                  sender: "", recipient: "")
    private enum MailKey {
        static let host = "mailHost", port = "mailPort", from = "mailFrom", to = "mailTo"
    }

    private var statusTimer: Timer?            // pollt den Daemon-Zustand fürs Icon
    private var lastKnownRunning = false       // für die "läuft→gestoppt"-Erkennung
    private var suppressNextStopNotification = false   // bei gewollter Deaktivierung/Neustart

    private var logController: LogWindowController?
    private var appLog: [String] = []          // Steuer-Ereignisse (Ring, gekappt)
    private let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private enum Tag {
        static let toggle = 1, port = 2, key = 3, mail = 10, mailTest = 11
        static let login = 21, log = 30, statusHbbs = 90, statusHbbr = 91
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let saved = UserDefaults.standard.object(forKey: basePortKey) as? Int,
           let p = UInt16(exactly: saved) {
            basePort = p
        }
        loadMailConfig()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupStatusIcon()
        buildMenu()
        requestNotificationAuthorization()
        lastKnownRunning = DaemonControl.isInstalled && DaemonControl.isRunning   // Startzustand ist kein "Wechsel"
        updateUI()
        startStatusPolling()
        log("Steuer-App gestartet")
        DispatchQueue.main.async { [weak self] in self?.offerDaemonUpdate() }
    }

    // Ältere Versionen installierten die Daemons mit einer Plist, der spätere
    // Korrekturen fehlen (Log-Ort, HOME, siehe DaemonControl.hasOutdatedPlist).
    // Einmal neu installieren zieht sie nach und räumt alte Logdateien weg.
    private func offerDaemonUpdate() {
        guard DaemonControl.isInstalled, DaemonControl.hasOutdatedPlist else { return }
        let alert = NSAlert()
        alert.messageText = "Dienste aktualisieren"
        alert.informativeText = """
        Die installierten Dienste stammen von einer älteren Version dieser App. \
        Eine Neuinstallation übernimmt die aktuellen Einstellungen, unter anderem \
        Logs in \(Config.logDir), die macOS-Updates überstehen.

        Schlüssel und Clients bleiben unverändert; die Dienste starten dabei kurz neu.
        """
        alert.addButton(withTitle: "Jetzt aktualisieren")
        alert.addButton(withTitle: "Später")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            log("Aktualisierung der Dienste aufgeschoben")
            return
        }
        suppressNextStopNotification = true
        if DaemonControl.install(basePort: basePort, mail: mail, onError: { [weak self] in self?.showError($0) }) {
            log("Daemons mit aktueller Plist neu installiert")
        }
        updateUI()
        refreshSoon()
    }

    // Ohne Erlaubnis liefert UNUserNotificationCenter später still gar nichts aus.
    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async { self?.log("Notification-Erlaubnis nicht erteilt: \(error.localizedDescription)") }
            }
        }
    }

    // Die Daemons können sich ohne Zutun der App ändern (Boot, Absturz, launchctl
    // von Hand). Ohne Polling bliebe das Menüleisten-Icon auf dem Stand vom
    // App-Start stehen.
    private func startStatusPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    // Monochrome Menüleisten-Icons (SF-Symbole, passen sich hell/dunkel an):
    // Outline = gestoppt, gefüllt = läuft. 14 pt ist bewusst kleiner als die
    // 22 pt der Python-Apps: dort skaliert rumps das Bild danach noch auf 20×20
    // herunter, hier geht die Punktgröße ungebremst in die Menüleiste.
    private func setupStatusIcon() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconStopped = symbolImage("display", cfg)              // Outline
        iconRunning = symbolImage("display.and.arrow.down", cfg)
        statusItem.button?.imagePosition = .imageOnly
        if iconStopped == nil { statusItem.button?.title = Config.displayName }  // Fallback
    }

    private func symbolImage(_ name: String, _ cfg: NSImage.SymbolConfiguration) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: Config.displayName)?
            .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true   // monochrom, invertiert korrekt bei Menü-Auswahl
        return img
    }

    // MARK: - Menü

    private func buildMenu() {
        let menu = NSMenu()

        addItem(menu, "Server aktivieren", #selector(toggleServer), tag: Tag.toggle, key: "s")
        addItem(menu, "Basisport ändern…", #selector(changePort), tag: Tag.port, key: "p")
        addItem(menu, "Öffentlichen Schlüssel kopieren", #selector(copyPublicKey), tag: Tag.key, key: "k")
        menu.addItem(.separator())

        disabledItem(menu, "ID-Server: aus", tag: Tag.statusHbbs)
        disabledItem(menu, "Relay: aus", tag: Tag.statusHbbr)
        menu.addItem(.separator())

        addItem(menu, "Absturz-Mail…", #selector(changeMail), tag: Tag.mail, key: "m")
        addItem(menu, "Test-Mail senden", #selector(sendTestMail), tag: Tag.mailTest)
        addItem(menu, "Beim Anmelden öffnen", #selector(toggleLoginItem), tag: Tag.login)
        addItem(menu, "Log anzeigen…", #selector(showLog), tag: Tag.log, key: "l")
        menu.addItem(.separator())

        addItem(menu, "Beenden", #selector(quit), key: "q")
        menu.delegate = self   // Zustand beim Aufklappen frisch prüfen
        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, tag: Int = 0, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        menu.addItem(item)
        return item
    }

    private func disabledItem(_ menu: NSMenu, _ title: String, tag: Int) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.tag = tag
        menu.addItem(item)
    }

    private func updateUI() {
        let installed = DaemonControl.isInstalled
        let running = installed && DaemonControl.isRunning

        // "läuft→gestoppt", nur passiv über den Timer/das Menü erkannt (nicht
        // beim eigenen Klick auf "Server deaktivieren" oder bei einer
        // Neuinstallation, die die Dienste kurz durchstartet – siehe
        // suppressNextStopNotification an den jeweiligen Aufrufstellen).
        if Self.shouldNotifyStop(wasRunning: lastKnownRunning, isRunning: running, suppressed: suppressNextStopNotification) {
            notifyUnexpectedStop()
        }
        suppressNextStopNotification = false
        lastKnownRunning = running

        if let icon = (running ? iconRunning : iconStopped) ?? iconStopped {
            statusItem.button?.image = icon
        }
        statusItem.button?.toolTip = running ? "\(Config.displayName) läuft" : "\(Config.displayName) gestoppt"
        guard let menu = statusItem.menu else { return }

        let anyInstalled = DaemonControl.isInstalled || DaemonControl.isPartiallyInstalled
        menu.item(withTag: Tag.toggle)?.title = anyInstalled ? "Server deaktivieren" : "Server aktivieren"
        menu.item(withTag: Tag.port)?.title = "Basisport ändern… (aktuell: \(basePort))"
        menu.item(withTag: Tag.mail)?.title = mail.isConfigured
            ? "Absturz-Mail… (an: \(mail.recipient))"
            : "Absturz-Mail… (aus)"
        menu.item(withTag: Tag.mailTest)?.isEnabled = mail.isConfigured
        menu.item(withTag: Tag.login)?.state = loginItemEnabled() ? .on : .off

        if let keyItem = menu.item(withTag: Tag.key) {
            if let key = ServerKey.publicKey {
                keyItem.title = "Öffentlichen Schlüssel kopieren (\(ServerKey.shortened(key)))"
                keyItem.isEnabled = true
            } else {
                keyItem.title = "Öffentlicher Schlüssel – noch keiner (Server aktivieren)"
                keyItem.isEnabled = false
            }
        }

        let effectiveBase = DaemonControl.installedBasePort ?? basePort
        updateStatusItem(menu, tag: Tag.statusHbbs, role: .hbbs, basePort: effectiveBase)
        updateStatusItem(menu, tag: Tag.statusHbbr, role: .hbbr, basePort: effectiveBase)
    }

    private func updateStatusItem(_ menu: NSMenu, tag: Int, role: Role, basePort: UInt16) {
        guard let item = menu.item(withTag: tag) else { return }
        let name = role == .hbbs ? "ID-Server" : "Relay"
        guard DaemonControl.isInstalled(role) else {
            item.title = "\(name): aus"
            return
        }
        let port = role.port(basePort: basePort)
        var title = DaemonControl.isRunning(role)
            ? "\(name): aktiv (Port \(port), Benutzer \(Config.runAsUser))"
            : "\(name): installiert, läuft nicht (Port \(port))"
        if let installedBase = DaemonControl.installedBasePort, installedBase != self.basePort {
            title += " – konfiguriert: \(self.basePort), Neuinstallation übernimmt"
        }
        item.title = title
    }

    // Reine Entscheidungslogik, losgelöst von AppKit – so ohne laufende App und
    // ohne Daemon-Zugriff gegen alle vier Zustandsübergänge testbar.
    static func shouldNotifyStop(wasRunning: Bool, isRunning: Bool, suppressed: Bool) -> Bool {
        wasRunning && !isRunning && !suppressed
    }

    // Nur der Hinweis am Mac; die Mail (siehe CrashMarker/MailNotifier) wirkt
    // unabhängig davon auch bei geschlossener App.
    private func notifyUnexpectedStop() {
        log("Unerwarteter Stopp erkannt")
        let content = UNMutableNotificationContent()
        content.title = Config.displayName
        content.body = "Ein RustDesk-Serverprozess ist unerwartet gestoppt."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                DispatchQueue.main.async { self?.log("Notification konnte nicht angezeigt werden: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Server aktivieren/deaktivieren

    @objc private func toggleServer() {
        if DaemonControl.isInstalled || DaemonControl.isPartiallyInstalled {
            suppressNextStopNotification = true   // gewollte Deaktivierung, kein "unerwartet"
            if DaemonControl.uninstall(onError: { [weak self] in self?.showError($0) }) {
                log("Server deaktiviert (beide Daemons entfernt)")
            }
        } else {
            if DaemonControl.install(basePort: basePort, mail: mail, onError: { [weak self] in self?.showError($0) }) {
                let p = Config.ports(basePort: basePort)
                log("Server aktiviert (TCP \(p.tcp.map(String.init).joined(separator: ", ")), UDP \(p.udp.map(String.init).joined(separator: ", ")))")
            }
        }
        updateUI()
        refreshSoon()
    }

    // `launchctl bootstrap` kehrt zurück, bevor die Prozesse laufen – ein
    // sofortiges pgrep liefe ins Leere. Kurz danach noch einmal nachsehen, damit
    // das Icon nicht bis zum nächsten Timer-Tick falsch steht. hbbr startet erst,
    // wenn hbbs das Schlüsselpaar erzeugt hat, deshalb auch ein später Nachschlag.
    private func refreshSoon() {
        for delay in [0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateUI() }
        }
    }

    // MARK: - Basisport konfigurieren

    @objc private func changePort() {
        let current = Config.ports(basePort: basePort)
        let alert = NSAlert()
        alert.messageText = "Basisport konfigurieren"
        alert.informativeText = """
        Der ID-Server belegt den Basisport, das Relay den darauf folgenden. \
        Beide binden zusätzlich Nachbarports. Standard ist \(Config.defaultBasePort); \
        Clients erwarten diesen Wert, ein anderer muss überall mit eingetragen werden.

        Aktuell: TCP \(current.tcp.map(String.init).joined(separator: ", ")) und \
        UDP \(current.udp.map(String.init).joined(separator: ", ")).
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(basePort)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Untergrenze 1025: die Dienste laufen unprivilegiert und dürfen keine
        // Ports unter 1024 binden. Obergrenze so, dass Basisport+2 noch passt.
        guard let p = UInt16(input), p > 1024, p <= 65530 else {
            showError("Ungültiger Basisport: \(input) — erlaubt sind 1025–65530.")
            return
        }
        setBasePort(p)
    }

    private func setBasePort(_ p: UInt16) {
        guard p != basePort else { return }
        basePort = p
        UserDefaults.standard.set(Int(p), forKey: basePortKey)
        log("Basisport auf \(p) gesetzt")

        // Bei aktiven Daemons sofort mit neuem Port neu installieren (ein Prompt).
        // Reinstallation durchstartet die Dienste kurz – kein "unerwarteter Stopp".
        if DaemonControl.isInstalled || DaemonControl.isPartiallyInstalled {
            suppressNextStopNotification = true
            if DaemonControl.install(basePort: basePort, mail: mail, onError: { [weak self] in self?.showError($0) }) {
                log("Daemons mit Basisport \(p) neu installiert")
            }
            refreshSoon()
        }
        updateUI()
    }

    // MARK: - Öffentlicher Schlüssel

    @objc private func copyPublicKey() {
        guard let key = ServerKey.publicKey else {
            showError("Noch kein Schlüssel vorhanden. Er entsteht beim ersten Start des ID-Servers.")
            return
        }
        ServerKey.copyToPasteboard(key)
        log("Öffentlicher Schlüssel in die Zwischenablage kopiert")
        let alert = NSAlert()
        alert.messageText = "Öffentlicher Schlüssel kopiert"
        alert.informativeText = """
        Dieser Wert gehört in jedem RustDesk-Client in das Feld „Key“ der \
        ID-/Relay-Server-Einstellungen, zusammen mit der LAN-Adresse dieses Macs \
        als ID-Server. Das Relay-Feld bleibt leer — der Client leitet es ab.

        \(key)
        """
        alert.runModal()
    }

    // MARK: - Absturz-Mail

    private func loadMailConfig() {
        let d = UserDefaults.standard
        mail.host = d.string(forKey: MailKey.host).flatMap { $0.isEmpty ? nil : $0 } ?? MailConfig.defaultHost
        mail.port = (d.object(forKey: MailKey.port) as? Int).flatMap(UInt16.init(exactly:)) ?? MailConfig.defaultPort
        mail.sender = d.string(forKey: MailKey.from) ?? ""
        mail.recipient = d.string(forKey: MailKey.to) ?? ""
    }

    private func saveMailConfig() {
        let d = UserDefaults.standard
        d.set(mail.host, forKey: MailKey.host)
        d.set(Int(mail.port), forKey: MailKey.port)
        d.set(mail.sender, forKey: MailKey.from)
        d.set(mail.recipient, forKey: MailKey.to)
    }

    @objc private func changeMail() {
        let alert = NSAlert()
        alert.messageText = "Absturz-Mail"
        alert.informativeText = "Meldet einen unerwarteten Neustart eines Serverprozesses per E-Mail. "
            + "Ein manueller Stopp löst bewusst keine Mail aus.\n\n"
            + "Versand über ein lokales Relay ohne Auth/TLS. Leerer Empfänger schaltet ab."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")

        let fields = [("Empfänger:", mail.recipient), ("Absender:", mail.sender),
                      ("Relay-Host:", mail.host), ("Relay-Port:", String(mail.port))]
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        var inputs: [NSTextField] = []
        for (label, value) in fields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let caption = NSTextField(labelWithString: label)
            caption.alignment = .right
            caption.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let input = NSTextField(string: value)
            input.widthAnchor.constraint(equalToConstant: 220).isActive = true
            row.addArrangedSubview(caption)
            row.addArrangedSubview(input)
            grid.addArrangedSubview(row)
            inputs.append(input)
        }
        grid.frame = NSRect(x: 0, y: 0, width: 310, height: 4 * 28)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = inputs.first

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let recipient = inputs[0].stringValue.trimmingCharacters(in: .whitespaces)
        let sender = inputs[1].stringValue.trimmingCharacters(in: .whitespaces)
        let host = inputs[2].stringValue.trimmingCharacters(in: .whitespaces)
        let portText = inputs[3].stringValue.trimmingCharacters(in: .whitespaces)
        guard let relayPort = UInt16(portText), relayPort >= 1 else {
            showError("Ungültiger Relay-Port: \(portText) — erlaubt sind 1–65535.")
            return
        }
        // Kein Empfänger ⇒ Versand aus; sonst braucht das Relay auch einen Absender.
        if !recipient.isEmpty && sender.isEmpty {
            showError("Ohne Absender nimmt das Relay die Mail nicht an.")
            return
        }
        let old = mail
        mail = MailConfig(host: host.isEmpty ? MailConfig.defaultHost : host,
                          port: relayPort, sender: sender, recipient: recipient)
        saveMailConfig()
        log(mail.isConfigured ? "Absturz-Mail an \(recipient) über \(mail.host):\(relayPort)"
                              : "Absturz-Mail deaktiviert")

        // Die Konfiguration steckt in den Plists – die Supervisor sehen
        // Änderungen erst nach Neuinstallation.
        let changed = old.host != mail.host || old.port != mail.port
            || old.sender != mail.sender || old.recipient != mail.recipient
        if changed && (DaemonControl.isInstalled || DaemonControl.isPartiallyInstalled) {
            suppressNextStopNotification = true   // Reinstallation, kein "unerwartet"
            if DaemonControl.install(basePort: basePort, mail: mail, onError: { [weak self] in self?.showError($0) }) {
                log("Daemons mit neuer Mail-Konfiguration neu installiert")
            }
            refreshSoon()
        }
        updateUI()
    }

    @objc private func sendTestMail() {
        guard mail.isConfigured else {
            showError("Erst unter „Absturz-Mail…\" Empfänger und Absender eintragen.")
            return
        }
        let cfg = mail
        let body = """
        Test der Absturz-Benachrichtigung von \(Config.displayName).

        Kommt diese Mail an, erreicht auch die echte Absturzmeldung ihr Ziel.
        Sie wird von der Steuer-App verschickt; im Ernstfall verschickt sie der
        Supervisor des betroffenen Dienstes über dieselbe Konfiguration.

        Relay:     \(cfg.host):\(cfg.port)
        Zeitpunkt: \(ISO8601DateFormatter().string(from: Date()))
        """
        log("Test-Mail an \(cfg.recipient) über \(cfg.host):\(cfg.port)…")
        // Nebenläufig: ein totes Relay würde die Menüleiste sonst einfrieren.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = MailNotifier.send(cfg, subject: "\(Config.displayName): Test-Mail", body: body)
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.showError("Test-Mail fehlgeschlagen: \(err)")
                } else {
                    self.log("Test-Mail zugestellt")
                    let ok = NSAlert()
                    ok.messageText = Config.displayName
                    ok.informativeText = "Test-Mail an \(cfg.recipient) zugestellt."
                    ok.runModal()
                }
            }
        }
    }

    // MARK: - Beim Anmelden öffnen (betrifft die Steuer-App)

    private func loginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log("Login-Item deaktiviert")
            } else {
                try SMAppService.mainApp.register()
                log("Login-Item aktiviert")
            }
        } catch {
            showError("Login-Item: \(error.localizedDescription)")
        }
        updateUI()
    }

    // MARK: - Log

    @objc private func showLog() {
        if logController == nil {
            let c = LogWindowController()
            c.provider = { [weak self] role in self?.buildLogText(role) ?? "" }
            logController = c
        }
        logController?.show()
    }

    private func log(_ message: String) {
        appLog.append("\(logFormatter.string(from: Date()))  \(message)")
        if appLog.count > 500 { appLog.removeFirst(appLog.count - 500) }
        logController?.refresh()
    }

    private func buildLogText(_ role: Role) -> String {
        var out = "── Steuer-App ──\n"
        out += appLog.isEmpty ? "(keine)\n" : appLog.joined(separator: "\n") + "\n"
        out += "\n── \(role.displayName) (\(role.logPath)) ──\n"
        if let data = FileManager.default.contents(atPath: role.logPath),
           let text = String(data: data, encoding: .utf8) {
            out += text.isEmpty ? "(leer)\n" : text
        } else {
            out += "(kein Log – Dienst nicht aktiviert oder Datei nicht lesbar)\n"
        }
        return out
    }

    // MARK: - Helfer

    private func showError(_ message: String) {
        log("Fehler: \(message)")
        let alert = NSAlert()
        alert.messageText = Config.displayName
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit() {
        // Beendet nur die Steuer-App; die Dienste laufen unabhängig weiter.
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateUI()
    }
}
