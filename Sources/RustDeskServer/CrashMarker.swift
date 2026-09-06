import Foundation

// Absturzerkennung für die überwachten Serverprozesse. Ein abgestürzter Prozess
// kann nicht mehr über sich selbst berichten, also läuft es indirekt: beim Start
// setzt der Supervisor einen Marker, bei sauberem Beenden (SIGTERM von launchctl
// oder beim Herunterfahren) entfernt er ihn wieder. Liegt er beim Start noch da,
// endete der Vorlauf unsauber und launchd hat per KeepAlive neu gestartet.
//
// Der Marker liegt im Arbeitsverzeichnis unter /usr/local/var und bewusst nicht
// in /var/run: letzteres leert macOS beim Boot, ein Absturz beim Herunterfahren
// bliebe damit unsichtbar.
struct CrashMarker {
    let path: String

    init(role: Role, workDir: String = Config.currentWorkDir) {
        self.path = "\(workDir)/\(role.markerName)"
    }

    // Inhalt des Markers vom Vorlauf, falls dieser nicht sauber beendet wurde.
    func stale() -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func arm(port: UInt16) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "pid=\(getpid()) port=\(port) gestartet=\(stamp)\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func disarm() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
