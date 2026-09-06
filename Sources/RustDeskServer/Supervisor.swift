import Foundation

// Headless-Betriebsart: startet einen der beiden RustDesk-Serverprozesse
// (hbbs/hbbr) als Kindprozess und bleibt selbst am Leben, solange das Kind läuft.
//
// Warum überhaupt ein Supervisor, statt launchd direkt auf hbbs zeigen zu lassen?
// hbbs und hbbr sind Fremdprogramme und können die Absturz-Benachrichtigung des
// Projekts nicht selbst leisten. Der Supervisor setzt und räumt den Marker,
// meldet einen unerwarteten Neustart per Mail und reicht Signale sauber durch.
// Er kostet einen zusätzlichen Prozess pro Rolle und ist ansonsten transparent.
enum Supervisor {

    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        guard let roleName = env[Config.Env.role], let role = Role(rawValue: roleName) else {
            fail("Keine gültige Rolle in \(Config.Env.role) (erwartet: hbbs oder hbbr).")
        }
        guard let binary = env[Config.Env.binary] else {
            fail("Kein Serverprogramm in \(Config.Env.binary) angegeben.")
        }
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            fail("Serverprogramm nicht ausführbar: \(binary)")
        }
        let port = UInt16(env[Config.Env.port] ?? "") ?? role.port(basePort: Config.defaultBasePort)
        let workDir = Config.currentWorkDir
        let mail = MailConfig.fromEnvironment()

        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        let marker = CrashMarker(role: role, workDir: workDir)
        reportCrashIfAny(marker: marker, role: role, port: port, mail: mail)
        marker.arm(port: port)

        // hbbs erzeugt das Schlüsselpaar beim ersten Start. hbbr braucht dasselbe
        // Paar; startet es zuerst, würde es ein zweites erzeugen und die beiden
        // Server hätten verschiedene Schlüssel. Deshalb wartet hbbr, bis die
        // Datei da ist, statt selbst zu erzeugen.
        if role == .hbbr {
            waitForKeyPair(workDir: workDir)
        } else {
            // hbbs legt das Paar mit der Standard-umask an, der private
            // Schlüssel wäre damit für jeden lesbar. Sobald er da ist, wird er
            // eingeengt; der öffentliche bleibt lesbar, damit die Menü-App ihn
            // anzeigen kann.
            DispatchQueue.global(qos: .utility).async { hardenKeyPair(workDir: workDir) }
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = arguments(for: role, port: port)
        child.currentDirectoryURL = URL(fileURLWithPath: workDir)

        // Signale an das Kind durchreichen und den Marker abräumen: launchctl
        // bootout und das Herunterfahren sind ein sauberes Ende und dürfen keine
        // Absturzmeldung auslösen. DispatchSource statt signal(): in einem echten
        // Handler wären nur async-signal-sichere Aufrufe erlaubt, Dateizugriff
        // gehört nicht dazu.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                marker.disarm()
                if child.isRunning { child.terminate() }
                // Dem Kind kurz Zeit zum Beenden geben, danach hart nachhelfen.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
            src.resume()
            sources.append(src)
        }
        _ = sources   // stark referenziert halten, sonst räumt ARC die Quellen ab

        note("\(role.rawValue) wird gestartet: \(binary) \(child.arguments!.joined(separator: " "))")
        do {
            try child.run()
        } catch {
            marker.disarm()
            fail("\(role.rawValue) ließ sich nicht starten: \(error.localizedDescription)")
        }
        child.waitUntilExit()

        // Endet das Kind von sich aus, endet auch der Supervisor. launchd startet
        // beides per KeepAlive neu; der noch liegende Marker macht daraus beim
        // nächsten Lauf die Absturzmeldung.
        let status = child.terminationStatus
        note("\(role.rawValue) beendet (Status \(status))")
        exit(status == 0 ? 0 : 1)
    }

    // hbbs bekommt nur den Port: Relay-Adresse und Schlüssel leitet der Client
    // selbst ab, solange hbbr auf derselben Adresse und dem Folgeport läuft.
    // hbbr lädt mit "-k _" dasselbe Schlüsselpaar aus dem Arbeitsverzeichnis,
    // damit die Relay-Nutzung nicht ohne Schlüsselprüfung offensteht.
    private static func arguments(for role: Role, port: UInt16) -> [String] {
        switch role {
        case .hbbs: return ["-p", String(port)]
        case .hbbr: return ["-p", String(port), "-k", "_"]
        }
    }

    // Wartet, bis hbbs das Paar erzeugt hat, und setzt dann die Rechte:
    // privater Schlüssel nur für den Dienstbenutzer, öffentlicher für alle.
    private static func hardenKeyPair(workDir: String, timeout: TimeInterval = 60) {
        guard waitForFile("\(workDir)/id_ed25519", timeout: timeout) else {
            note("Schlüsselpaar nach \(Int(timeout)) s nicht vorhanden – Rechte nicht gesetzt.")
            return
        }
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: "\(workDir)/id_ed25519")
        if waitForFile("\(workDir)/id_ed25519.pub", timeout: 10) {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(workDir)/id_ed25519.pub")
        }
    }

    private static func waitForFile(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) && Date() < deadline {
            usleep(500_000)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private static func waitForKeyPair(workDir: String, timeout: TimeInterval = 60) {
        if !waitForFile("\(workDir)/id_ed25519", timeout: timeout) {
            note("Schlüsselpaar nach \(Int(timeout)) s nicht vorhanden – hbbr startet trotzdem und erzeugt eines.")
        }
    }

    // Lag beim Start noch ein Marker, endete der Vorlauf unsauber. Der Versand
    // läuft nebenläufig, damit ein langsames oder totes Relay den Serverstart
    // nicht verzögert.
    private static func reportCrashIfAny(marker: CrashMarker, role: Role, port: UInt16, mail: MailConfig) {
        guard let stale = marker.stale() else { return }
        note("unerwarteter Neustart von \(role.rawValue) erkannt (Vorlauf: \(stale))")
        guard mail.isConfigured else { return }

        let host = Host.current().localizedName ?? "unbekannt"
        let body = """
        \(role.displayName) wurde unerwartet neu gestartet.

        Der vorherige Prozess hat sich nicht sauber beendet – er ist abgestürzt oder
        der Mac wurde hart ausgeschaltet. launchd hat den Dienst per KeepAlive
        automatisch wieder gestartet; er läuft jetzt wieder auf Port \(port).

        Mac:               \(host)
        Vorheriger Lauf:   \(stale)
        Neustart:          \(ISO8601DateFormatter().string(from: Date()))

        Details im Log: \(role.logPath)
        """
        DispatchQueue.global(qos: .utility).async {
            if let err = MailNotifier.send(mail, subject: "\(Config.displayName): unerwarteter Neustart (\(role.rawValue))", body: body) {
                note("Absturz-Mail fehlgeschlagen: \(err)")
            }
        }
    }

    private static func note(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(Config.appName): \(message)\n".utf8))
    }

    private static func fail(_ message: String) -> Never {
        note(message)
        exit(1)
    }
}
