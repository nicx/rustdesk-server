import AppKit

// Zwei Betriebsarten aus einem Binary:
//  - Headless (RDS_HEADLESS gesetzt): Supervisor für einen der beiden
//    RustDesk-Serverprozesse, so laufen die LaunchDaemons. Keine Menüleiste,
//    kein Dock.
//  - Sonst: Menüleisten-App ohne Dock-Icon (.accessory) mit allen Funktionen.
//
// Falle: keine Top-Level-`var` in dieser Datei. Globale Variablen werden hier in
// Quelltext-Reihenfolge als Anweisungen initialisiert (nicht lazy wie in anderen
// Dateien); der Headless-Zweig läuft ganz oben und griffe sonst auf noch nicht
// initialisierten Zustand zu. Was den Start überleben muss, gehört in eine
// static Property.
if ProcessInfo.processInfo.environment[Config.Env.headless] != nil {
    Supervisor.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
