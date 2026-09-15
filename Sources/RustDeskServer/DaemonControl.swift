import AppKit

// Installiert und entfernt die beiden LaunchDaemons direkt aus der App heraus.
// Die privilegierten Schritte laufen über einen einmaligen Admin-Prompt
// (osascript „with administrator privileges"), und zwar für beide Rollen
// zusammen — kein sudo im Terminal, keine zwei Passwortabfragen.
//
// Die Daemons laufen selbst nicht als root: alle benötigten Ports liegen über
// 1024, deshalb setzt die Plist UserName auf einen unprivilegierten Benutzer.
enum DaemonControl {

    static func isInstalled(_ role: Role) -> Bool {
        FileManager.default.fileExists(atPath: role.plistPath)
    }

    static var isInstalled: Bool {
        Role.allCases.allSatisfy { isInstalled($0) }
    }

    static var isPartiallyInstalled: Bool {
        Role.allCases.contains { isInstalled($0) } && !isInstalled
    }

    // Basisport, mit dem die Daemons tatsächlich installiert sind (aus der
    // hbbs-Plist gelesen, nicht aus den Einstellungen).
    static var installedBasePort: UInt16? {
        guard let data = FileManager.default.contents(atPath: Role.hbbs.plistPath),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let env = dict["EnvironmentVariables"] as? [String: Any],
              let s = env[Config.Env.port] as? String,
              let p = UInt16(s) else { return nil }
        return p
    }

    // Schreibt eine installierte Plist ihr Log noch an einen anderen Ort als
    // vorgesehen (z. B. das alte /var/log)? Dann muss neu installiert werden,
    // sonst legt das nächste macOS-Update den Daemon wieder lahm.
    static var hasOutdatedLogPath: Bool {
        Role.allCases.contains { role in
            guard let data = FileManager.default.contents(atPath: role.plistPath),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = obj as? [String: Any],
                  let path = dict["StandardOutPath"] as? String else { return false }
            return path != role.logPath
        }
    }

    // Läuft der überwachte Serverprozess? (best effort, ohne root)
    static func isRunning(_ role: Role) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", role.binaryPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return isInstalled(role)   // Fallback: installiert ⇒ vermutlich aktiv
        }
    }

    static var isRunning: Bool {
        Role.allCases.allSatisfy { isRunning($0) }
    }

    @discardableResult
    static func install(basePort: UInt16, mail: MailConfig, onError: (String) -> Void) -> Bool {
        // Der Supervisor ist dieselbe Binärdatei wie die laufende App; hbbs und
        // hbbr liegen als mitgelieferte Programme im Bundle. Damit ist alles
        // Nötige an Bord und die Installation braucht nichts aus dem Netz.
        guard let exe = Bundle.main.executablePath else {
            onError("Programm-Binary nicht gefunden."); return false
        }
        var bundled: [Role: String] = [:]
        for role in Role.allCases {
            guard let path = bundledBinary(role) else {
                onError("\(role.rawValue) fehlt im App-Bundle. Erst Scripts/build-server-binaries.sh ausführen und neu bauen.")
                return false
            }
            bundled[role] = path
        }

        let tmp = NSTemporaryDirectory()
        var script = """
        #!/bin/sh
        set -e
        mkdir -p /usr/local/libexec '\(Config.workDir)' '\(Config.logDir)'
        chown \(Config.runAsUser) '\(Config.logDir)'
        chmod 755 '\(Config.logDir)'
        cp '\(exe)' '\(Config.supervisorBinary)'
        chmod 755 '\(Config.supervisorBinary)'

        """
        for role in Role.allCases {
            let tmpPlist = tmp + "\(role.label).plist"
            do {
                try Config.daemonPlistXML(role: role, basePort: basePort, mail: mail)
                    .write(toFile: tmpPlist, atomically: true, encoding: .utf8)
            } catch {
                onError("Vorbereitung fehlgeschlagen: \(error.localizedDescription)"); return false
            }
            script += """
            cp '\(bundled[role]!)' '\(role.binaryPath)'
            chmod 755 '\(role.binaryPath)'
            cp '\(tmpPlist)' '\(role.plistPath)'
            chown root:wheel '\(role.plistPath)'
            chmod 644 '\(role.plistPath)'
            : > '\(role.logPath)'
            chown \(Config.runAsUser) '\(role.logPath)'
            rm -f '\(role.legacyLogPath)'

            """
        }
        // Das Arbeitsverzeichnis muss dem Dienstbenutzer gehören: dort legt hbbs
        // sein Schlüsselpaar und die Datenbank an. Es bleibt für alle lesbar,
        // damit die Menü-App den öffentlichen Schlüssel anzeigen kann; den
        // privaten Schlüssel engt der Supervisor danach auf 600 ein.
        script += """
        chown -R \(Config.runAsUser) '\(Config.workDir)'
        chmod 755 '\(Config.workDir)'

        """
        // hbbs zuerst laden: es erzeugt das Schlüsselpaar, auf das hbbr wartet.
        for role in [Role.hbbs, Role.hbbr] {
            script += """
            launchctl bootout system '\(role.plistPath)' 2>/dev/null || true
            launchctl bootstrap system '\(role.plistPath)'
            launchctl enable system/\(role.label)

            """
        }

        let tmpScript = tmp + "rustdeskserver-install.sh"
        do { try script.write(toFile: tmpScript, atomically: true, encoding: .utf8) }
        catch { onError("Vorbereitung fehlgeschlagen: \(error.localizedDescription)"); return false }
        return runPrivileged(scriptPath: tmpScript, onError: onError)
    }

    // Entfernt Daemons und Programme. Das Arbeitsverzeichnis bleibt bewusst
    // stehen: dort liegt das Schlüsselpaar, und ein neues würde jeden schon
    // eingerichteten Client aussperren.
    @discardableResult
    static func uninstall(onError: (String) -> Void) -> Bool {
        var script = "#!/bin/sh\n"
        for role in Role.allCases {
            // Marker mit entfernen: bootout beendet sauber und der Supervisor
            // räumt ihn selbst weg – lag er aber noch (Prozess war abgestürzt),
            // meldete die nächste Installation sonst einen Absturz, den es in
            // dieser Form nie gab.
            script += """
            launchctl bootout system '\(role.plistPath)' 2>/dev/null || true
            rm -f '\(role.plistPath)' '\(role.binaryPath)' '\(Config.workDir)/\(role.markerName)'

            """
        }
        script += "rm -f '\(Config.supervisorBinary)'\n"

        let tmpScript = NSTemporaryDirectory() + "rustdeskserver-uninstall.sh"
        do { try script.write(toFile: tmpScript, atomically: true, encoding: .utf8) }
        catch { onError("Vorbereitung fehlgeschlagen: \(error.localizedDescription)"); return false }
        return runPrivileged(scriptPath: tmpScript, onError: onError)
    }

    // hbbs/hbbr liegen neben der App-Binärdatei in Contents/MacOS. Ausführbare
    // Beilagen gehören dorthin und nicht nach Resources, sonst stolpert codesign.
    static func bundledBinary(_ role: Role) -> String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent(role.rawValue).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // Führt ein Shell-Skript als root aus. Liefert false bei Fehler/Abbruch.
    private static func runPrivileged(scriptPath: String, onError: (String) -> Void) -> Bool {
        let src = "do shell script \"/bin/sh -- '\(scriptPath)'\" with administrator privileges"
        guard let apple = NSAppleScript(source: src) else {
            onError("AppleScript konnte nicht erstellt werden."); return false
        }
        var errInfo: NSDictionary?
        apple.executeAndReturnError(&errInfo)
        if let err = errInfo {
            let num = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if num == -128 { return false }   // Benutzer hat den Prompt abgebrochen
            let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "\(err)"
            onError(msg)
            return false
        }
        return true
    }
}
