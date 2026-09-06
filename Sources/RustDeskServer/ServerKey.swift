import AppKit

// Der öffentliche Schlüssel, den jeder RustDesk-Client eintragen muss, damit er
// diesen ID-Server akzeptiert. hbbs erzeugt ihn beim ersten Start im
// Arbeitsverzeichnis; die App liest ihn nur.
//
// Ausschließlich der öffentliche Teil wird angezeigt oder kopiert. Der private
// Schlüssel darf nirgends auftauchen — nicht im Menü, nicht im Log, nicht in
// einer Mail.
enum ServerKey {

    static var publicKey: String? {
        guard let text = try? String(contentsOfFile: Config.publicKeyPath, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Für die Anzeige gekürzt: der Schlüssel ist zu lang für eine Menüzeile.
    static func shortened(_ key: String, keep: Int = 8) -> String {
        guard key.count > 2 * keep + 1 else { return key }
        return "\(key.prefix(keep))…\(key.suffix(keep))"
    }

    @discardableResult
    static func copyToPasteboard(_ key: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(key, forType: .string)
    }
}
