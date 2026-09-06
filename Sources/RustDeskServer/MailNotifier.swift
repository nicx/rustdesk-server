import Foundation

// Zustellung an ein lokales Mail-Relay per einfachem
// Klartext-SMTP: Upstream-Auth, STARTTLS und Retry macht das Relay, hier also
// kein Auth/TLS. Bewusst mit POSIX-Sockets statt einer Abhängigkeit; blockierend,
// weil der Aufruf nur beim Daemon-Start auf einer Hintergrund-Queue passiert.
struct MailConfig {
    var host: String
    var port: UInt16
    var sender: String
    var recipient: String

    // Relay-Default: "localhost", bewusst nicht die IP "127.0.0.1". macOS löst
    // localhost zuerst nach ::1 auf (siehe /etc/hosts) und erst danach nach
    // 127.0.0.1; connectSocket nimmt die erste Adresse, die verbindet. Das
    // umgeht die Eigenheit mancher Relays, reines IPv4-Loopback nur sporadisch
    // anzunehmen, behält aber den Fallback, falls IPv6 fehlt.
    static let defaultHost = "localhost"
    static let defaultPort: UInt16 = 2525

    var isConfigured: Bool {
        !host.isEmpty && !sender.isEmpty && !recipient.isEmpty
    }

    // Der Daemon bekommt seine Mail-Konfiguration ausschließlich über die Plist-Env
    // (wie den Port). Nichts davon liegt im Code – Adressen sind Laufzeitdaten.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MailConfig {
        MailConfig(host: env[Config.Env.mailHost] ?? defaultHost,
                   port: UInt16(env[Config.Env.mailPort] ?? "") ?? defaultPort,
                   sender: env[Config.Env.mailFrom] ?? "",
                   recipient: env[Config.Env.mailTo] ?? "")
    }
}

enum MailNotifier {
    private static let ioTimeout: TimeInterval = 10

    // Liefert nil bei Erfolg, sonst eine Fehlerbeschreibung. Wirft nie – eine
    // nicht zustellbare Benachrichtigung darf den Serverbetrieb nie beeinflussen.
    @discardableResult
    static func send(_ cfg: MailConfig, subject: String, body: String) -> String? {
        guard cfg.isConfigured else { return "Mailversand ist nicht konfiguriert." }
        guard let fd = connectSocket(host: cfg.host, port: cfg.port) else {
            return "Keine Verbindung zu \(cfg.host):\(cfg.port)."
        }
        defer { close(fd) }

        let message = buildMessage(cfg, subject: subject, body: body)
        let steps: [(send: String?, expect: Int)] = [
            (nil,                              220),   // Begrüßung des Relays
            ("EHLO rustdeskserver",                 250),
            ("MAIL FROM:<\(cfg.sender)>",      250),
            ("RCPT TO:<\(cfg.recipient)>",     250),
            ("DATA",                           354),
            (message + "\r\n.",                250),   // Ende der Daten
            ("QUIT",                           221),
        ]
        for step in steps {
            if let line = step.send, !write(fd, line + "\r\n") {
                return "Senden abgebrochen (\(line.prefix(12))…)."
            }
            guard let reply = readReply(fd) else { return "Keine Antwort vom Relay." }
            guard reply.code == step.expect else {
                return "Relay antwortete \(reply.code): \(reply.text)"
            }
        }
        return nil
    }

    // MARK: - Nachricht

    private static func buildMessage(_ cfg: MailConfig, subject: String, body: String) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")   // RFC 5322 verlangt englische Namen
        date.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"

        var out = "From: <\(cfg.sender)>\r\n"
        out += "To: <\(cfg.recipient)>\r\n"
        out += "Subject: \(encodeHeader(subject))\r\n"
        out += "Date: \(date.string(from: Date()))\r\n"
        out += "MIME-Version: 1.0\r\n"
        out += "Content-Type: text/plain; charset=\"utf-8\"\r\n"
        out += "Content-Transfer-Encoding: 8bit\r\n"
        out += "\r\n"
        // CRLF-Normalisierung + Dot-Stuffing: eine Zeile aus nur "." würde die
        // Daten sonst vorzeitig beenden.
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            out += (line.hasPrefix(".") ? "." + line : line) + "\r\n"
        }
        return out
    }

    // Betreffzeilen sind deutsch und damit nicht ASCII – RFC 2047 (encoded-word).
    private static func encodeHeader(_ text: String) -> String {
        guard text.contains(where: { !$0.isASCII }) else { return text }
        let b64 = Data(text.utf8).base64EncodedString()
        return "=?UTF-8?B?\(b64)?="
    }

    // MARK: - Socket

    private static func connectSocket(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // v4 und v6, Reihenfolge macht das System
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }

        var node: UnsafeMutablePointer<addrinfo>? = first
        while let cur = node {
            let fd = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if fd >= 0 {
                applyTimeout(fd)
                if connect(fd, cur.pointee.ai_addr, cur.pointee.ai_addrlen) == 0 { return fd }
                close(fd)
            }
            node = cur.pointee.ai_next
        }
        return nil
    }

    // Ohne Timeout könnte ein hängendes Relay den Daemon-Start blockieren.
    private static func applyTimeout(_ fd: Int32) {
        var tv = timeval(tv_sec: Int(ioTimeout), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
    }

    private static func write(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            // Darwin.send explizit: sonst greift die statische send(_:subject:body:) oben.
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    // SMTP-Antworten sind mehrzeilig: "250-…" setzt fort, "250 …" schließt ab.
    private static func readReply(_ fd: Int32) -> (code: Int, text: String)? {
        var buffer = ""
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer += String(decoding: chunk[0..<n], as: UTF8.self)
            let lines = buffer.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            if let last = lines.last, last.count >= 4 {
                let idx = last.index(last.startIndex, offsetBy: 3)
                if last[idx] == " ", let code = Int(last.prefix(3)) {
                    return (code, lines.joined(separator: " ").trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }
}
