import AppKit

// Log-Fenster: zeigt die Ereignisse der Steuer-App und wahlweise das Log von
// hbbs oder hbbr. Aktualisiert sich alle 2 s, solange das Fenster offen ist.
final class LogWindowController: NSWindowController, NSWindowDelegate {

    private var textView: NSTextView!
    private var picker: NSSegmentedControl!
    private var timer: Timer?

    // Liefert den Text für die gewählte Rolle.
    var provider: ((Role) -> String)?

    private var selectedRole: Role = .hbbs

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(Config.displayName) – Log"
        window.center()
        self.init(window: window)
        window.delegate = self

        let content = window.contentView!

        let seg = NSSegmentedControl(labels: Role.allCases.map(\.displayName),
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(roleChanged))
        seg.selectedSegment = 0
        seg.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(seg)
        self.picker = seg

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        content.addSubview(scroll)

        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = tv
        self.textView = tv

        NSLayoutConstraint.activate([
            seg.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            seg.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    @objc private func roleChanged() {
        let index = picker.selectedSegment
        guard index >= 0, index < Role.allCases.count else { return }
        selectedRole = Role.allCases[index]
        textView.string = ""   // erzwingt ein Neuzeichnen im refresh()
        refresh()
    }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let text = provider?(selectedRole) ?? ""
        guard textView.string != text else { return }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
