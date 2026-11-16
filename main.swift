// Alerte Contexte — quand une conversation Claude Code devient trop lourde, un chef de chantier
// passe en bas de l'écran avec une pancarte qui montre la jauge de contexte.
import Cocoa
import WebKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct Config: Codable {
    var window: Int = 200000
    var percent: Int = 50
    var capOn: Bool = false
    var cap: Int = 300000
    var paused: Bool = false
    var sound: Bool = true
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var panel: OverlayPanel!
    private var web: WKWebView!
    private var statusItem: NSStatusItem!
    private var pageReady = false
    private var showing = false
    private var showingSince = Date()
    private var sounds: [String: NSSound] = [:]
    private var playing: [NSSound] = []
    private var config = Config()

    private var pauseItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var capItem: NSMenuItem!
    private var percentItems: [NSMenuItem] = []
    private var windowItems: [NSMenuItem] = []

    private let home = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/alerte-contexte")
    private var eventsDir: String { (home as NSString).appendingPathComponent("events") }
    private var configPath: String { (home as NSString).appendingPathComponent("config.json") }
    private var demoFlag: String { (home as NSString).appendingPathComponent("demo") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: eventsDir, withIntermediateDirectories: true)
        loadConfig()
        let frame = currentScreen().visibleFrame

        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "alerte")
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        panel.contentView = web
        if let url = Bundle.main.url(forResource: "overlay", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        for name in ["pop", "whistle", "tick"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
                sounds[name] = NSSound(contentsOf: url, byReference: false)
            }
        }
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageReady = true }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let value = body["value"] as? String ?? ""
        if type == "sfx", config.sound { play(value) }
        if type == "done" { showing = false }
    }

    private func play(_ name: String) {
        playing.removeAll { !$0.isPlaying }
        guard let s = sounds[name]?.copy() as? NSSound else { return }
        s.play()
        playing.append(s)
    }

    // MARK: - Boucle : une alerte à la fois

    private func tick() {
        guard pageReady else { return }
        let fm = FileManager.default
        if showing {
            if Date().timeIntervalSince(showingSince) > 40 { showing = false }   // garde-fou
            return
        }
        if fm.fileExists(atPath: demoFlag) {
            try? fm.removeItem(atPath: demoFlag)
            runDemo()
            return
        }
        guard let names = try? fm.contentsOfDirectory(atPath: eventsDir) else { return }
        let files = names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        guard let first = files.first else {
            followScreen()
            return
        }
        let path = (eventsDir as NSString).appendingPathComponent(first)
        let data = fm.contents(atPath: path)
        try? fm.removeItem(atPath: path)
        guard !config.paused, let data, let json = String(data: data, encoding: .utf8),
              json.trimmingCharacters(in: .whitespaces).hasPrefix("{") else { return }
        show(json)
    }

    private func show(_ eventJSON: String) {
        showing = true
        showingSince = Date()
        followScreen()
        web.evaluateJavaScript("alerte.show(\(eventJSON))", completionHandler: nil)
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func followScreen() {
        let frame = currentScreen().visibleFrame
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: - Réglages (partagés avec le script du hook)

    private func loadConfig() {
        if let data = FileManager.default.contents(atPath: configPath),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        }
        saveConfig()
    }

    private func saveConfig() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        }
    }

    // MARK: - Menu (icône 🪧)

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪧"
        let menu = NSMenu()
        let title = NSMenuItem(title: "Alerte Contexte", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Lancer la démo", #selector(runDemo)))
        pauseItem = item("En pause", #selector(togglePause)); menu.addItem(pauseItem)
        soundItem = item("Son", #selector(toggleSound)); menu.addItem(soundItem)

        let pctMenu = NSMenu()
        for p in [50, 60, 70, 80] {
            let it = item("\(p) %", #selector(choosePercent(_:)))
            it.tag = p
            pctMenu.addItem(it)
            percentItems.append(it)
        }
        let pctParent = NSMenuItem(title: "Prévenir à…", action: nil, keyEquivalent: "")
        pctParent.submenu = pctMenu
        menu.addItem(pctParent)

        capItem = item("…ou dès 300 000 tokens", #selector(toggleCap))
        menu.addItem(capItem)

        let winMenu = NSMenu()
        for (label, value) in [("200 000 tokens", 200000), ("1 million de tokens", 1000000)] {
            let it = item(label, #selector(chooseWindow(_:)))
            it.tag = value
            winMenu.addItem(it)
            windowItems.append(it)
        }
        let winParent = NSMenuItem(title: "Mémoire de Claude", action: nil, keyEquivalent: "")
        winParent.submenu = winMenu
        menu.addItem(winParent)

        menu.addItem(.separator())
        menu.addItem(item("Quitter", #selector(quit), key: "q"))
        statusItem.menu = menu
        refreshMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func refreshMenu() {
        pauseItem.state = config.paused ? .on : .off
        soundItem.state = config.sound ? .on : .off
        capItem.state = config.capOn ? .on : .off
        percentItems.forEach { $0.state = $0.tag == config.percent ? .on : .off }
        windowItems.forEach { $0.state = $0.tag == config.window ? .on : .off }
    }

    @objc private func runDemo() {
        // La démo montre le vrai seuil : le pourcentage choisi, ou la limite fixe si elle arrive avant.
        let w = config.window
        var threshold = Double(config.percent)
        if config.capOn { threshold = min(threshold, Double(config.cap) * 100 / Double(w)) }
        let th = Int(threshold.rounded())
        let pct = th + 2
        let json = "{\"title\":\"Démo\",\"tokens\":\(w * pct / 100),\"window\":\(w),\"pct\":\(pct),\"threshold\":\(th),\"level\":1}"
        show(json)
    }

    @objc private func togglePause() { config.paused.toggle(); saveConfig(); refreshMenu() }
    @objc private func toggleSound() { config.sound.toggle(); saveConfig(); refreshMenu() }
    @objc private func toggleCap() { config.capOn.toggle(); saveConfig(); refreshMenu() }
    @objc private func choosePercent(_ s: NSMenuItem) { config.percent = s.tag; saveConfig(); refreshMenu() }
    @objc private func chooseWindow(_ s: NSMenuItem) { config.window = s.tag; saveConfig(); refreshMenu() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
