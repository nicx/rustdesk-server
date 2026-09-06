import Foundation

// Die beiden Serverprozesse von RustDesk. Sie vermitteln nur:
//  - hbbs löst eine RustDesk-ID auf eine erreichbare Adresse auf (Adressbuch),
//  - hbbr reicht Pakete durch, wenn kein Direktweg zustande kommt (Relay).
// Die eigentliche Fernsteuerung leistet die RustDesk-App auf der gesteuerten
// Maschine, nicht diese Server.
enum Role: String, CaseIterable {
    case hbbs, hbbr

    var displayName: String {
        switch self {
        case .hbbs: return "ID-Server (hbbs)"
        case .hbbr: return "Relay (hbbr)"
        }
    }

    var label: String       { "\(Config.bundleID).\(rawValue)" }
    var plistPath: String   { "/Library/LaunchDaemons/\(label).plist" }
    var binaryPath: String  { "/usr/local/libexec/rustdesk-\(rawValue)" }
    var logPath: String     { "/var/log/rustdeskserver-\(rawValue).log" }
    var markerName: String  { "\(rawValue).state" }

    // hbbs bekommt den Basisport, hbbr den darauf folgenden. Beide binden noch
    // weitere Ports daneben, siehe Config.ports(basePort:).
    func port(basePort: UInt16) -> UInt16 {
        switch self {
        case .hbbs: return basePort
        case .hbbr: return basePort &+ 1
        }
    }
}

// Zentrale Namen und Pfade, von Menü-App und Supervisor gemeinsam genutzt.
// Alles hier ist ortsunabhängig: keine IP-Adressen, keine Domains, keine
// Benutzerpfade. Was von der Umgebung abhängt, kommt aus UserDefaults.
enum Config {
    static let appName     = "RustDeskServer"
    static let displayName = "RustDesk Server"
    static let bundleID    = "app.rustdeskserver"

    // Der Supervisor ist dieselbe Binärdatei wie die App, nur im Headless-Modus.
    static let supervisorBinary = "/usr/local/libexec/rustdeskserver-supervisor"

    // Arbeitsverzeichnis beider Serverprozesse. Hier legt hbbs sein Schlüsselpaar
    // und die SQLite-Datei ab; hier liegen auch die Absturzmarker.
    static let workDir = "/usr/local/var/rustdeskserver"

    static var publicKeyPath: String  { "\(workDir)/id_ed25519.pub" }
    static var privateKeyPath: String { "\(workDir)/id_ed25519" }

    // Benutzer, unter dem die Serverprozesse laufen. Alle benötigten Ports
    // liegen über 1024, der Dienst braucht also kein root; root gibt es nur
    // einmalig beim Installieren der Daemons.
    static let runAsUser = "daemon"

    static let defaultBasePort: UInt16 = 21116

    // Alle Ports, die bei einem gegebenen Basisport belegt werden. hbbs bindet
    // zusätzlich Port-1 (NAT-Typ-Test) und Port+2 (WebSocket), hbbr ebenfalls
    // Port+2. Wird nur für Anzeige und Selbsttest gebraucht.
    static func ports(basePort: UInt16) -> (tcp: [UInt16], udp: [UInt16]) {
        let hbbs = basePort
        let hbbr = basePort &+ 1
        return (tcp: [hbbs &- 1, hbbs, hbbs &+ 2, hbbr, hbbr &+ 2].sorted(), udp: [hbbs])
    }

    // Umgebungsvariablen, über die der Supervisor konfiguriert wird. Der Name
    // des Präfixes ist bewusst kurz und neutral.
    enum Env {
        static let headless = "RDS_HEADLESS"
        static let role     = "RDS_ROLE"
        static let port     = "RDS_PORT"
        static let workDir  = "RDS_WORKDIR"
        static let binary   = "RDS_BINARY"
        static let mailHost = "RDS_MAIL_HOST"
        static let mailPort = "RDS_MAIL_PORT"
        static let mailFrom = "RDS_MAIL_FROM"
        static let mailTo   = "RDS_MAIL_TO"
    }

    static var currentWorkDir: String {
        ProcessInfo.processInfo.environment[Env.workDir] ?? workDir
    }

    // LaunchDaemon-Plist für eine Rolle, zur Laufzeit erzeugt — so kommt die App
    // ohne mitgelieferte Konfigurationsdateien aus. Die Mail-Konfiguration reist
    // über dieselbe Env zum Supervisor; ohne Empfänger bleibt sie ganz weg.
    static func daemonPlistXML(role: Role, basePort: UInt16, mail: MailConfig) -> String {
        var mailEnv = ""
        if mail.isConfigured {
            mailEnv = """
            \n            <key>\(Env.mailHost)</key><string>\(xml(mail.host))</string>
                        <key>\(Env.mailPort)</key><string>\(mail.port)</string>
                        <key>\(Env.mailFrom)</key><string>\(xml(mail.sender))</string>
                        <key>\(Env.mailTo)</key><string>\(xml(mail.recipient))</string>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(role.label)</string>
            <key>ProgramArguments</key>
            <array><string>\(supervisorBinary)</string></array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>\(Env.headless)</key><string>1</string>
                <key>\(Env.role)</key><string>\(role.rawValue)</string>
                <key>\(Env.port)</key><string>\(role.port(basePort: basePort))</string>
                <key>\(Env.workDir)</key><string>\(workDir)</string>
                <key>\(Env.binary)</key><string>\(role.binaryPath)</string>
                <key>RUST_LOG</key><string>info</string>
                <key>TEST_HBBS</key><string>no</string>\(mailEnv)
            </dict>
            <key>WorkingDirectory</key><string>\(workDir)</string>
            <key>UserName</key><string>\(runAsUser)</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>StandardOutPath</key><string>\(role.logPath)</string>
            <key>StandardErrorPath</key><string>\(role.logPath)</string>
        </dict>
        </plist>
        """
    }

    // Mail-Adressen sind frei eingegeben und landen in XML – maskieren, sonst
    // zerlegt ein "&" oder "<" die Plist.
    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
