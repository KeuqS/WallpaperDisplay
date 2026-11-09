import Cocoa
import WebKit
import Network
import UniformTypeIdentifiers

struct DisplayMedia {
    let url: String
    let kind: String
}

final class LocalServer {
    private let root: URL
    private let listener: NWListener
    private var state: [String: Any] = ["type": "empty", "version": Date().timeIntervalSince1970]
    private let queue = DispatchQueue(label: "wallpaper.server")

    init(root: URL) throws {
        self.root = root
        self.listener = try NWListener(using: .tcp, on: 8765)
        if let data = try? Data(contentsOf: root.appendingPathComponent(".media-state.json")),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { state = saved }
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.receive(connection, buffer: buffer); return
            }
            let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let bodyStart = headerEnd.upperBound
            let contentLength = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") } ?? 0
            guard buffer.count - bodyStart >= contentLength else { self.receive(connection, buffer: buffer); return }
            let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
            self.handle(header: header, body: body, connection: connection)
        }
    }

    private func handle(header: String, body: Data, connection: NWConnection) {
        let first = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { respond(400, "Bad Request", connection); return }
        let method = parts[0], path = URL(string: parts[1])?.path ?? "/"
        if method == "GET" { serveGet(path, connection); return }
        if method == "POST" && path == "/api/url" { updateURL(body, connection); return }
        if method == "POST" && path == "/api/upload" { updateUpload(body, connection); return }
        if method == "DELETE" && path == "/api/state" { state = ["type": "empty", "version": Date().timeIntervalSince1970]; saveState(); respond(200, "{\"ok\":true}", connection, contentType: "application/json"); return }
        respond(404, "Not Found", connection)
    }

    private func serveGet(_ path: String, _ connection: NWConnection) {
        if path == "/api/state" { respond(200, json(state), connection, contentType: "application/json"); return }
        let clean = path == "/" ? "/index.html" : path
        let file = root.appendingPathComponent(String(clean.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else { respond(404, "Not Found", connection); return }
        respond(200, data, connection, contentType: mime(file.pathExtension))
    }

    private func updateURL(_ body: Data, _ connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let url = object["url"] as? String else { respond(400, "Bad Request", connection); return }
        state = ["type": "url", "url": url, "kind": object["kind"] as? String ?? "video", "version": Date().timeIntervalSince1970]
        saveState(); respond(200, "{\"ok\":true}", connection, contentType: "application/json")
    }

    private func updateUpload(_ body: Data, _ connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let encoded = object["data"] as? String, let data = Data(base64Encoded: encoded) else { respond(400, "Bad Request", connection); return }
        let ext = URL(fileURLWithPath: object["name"] as? String ?? "media.mp4").pathExtension.isEmpty ? "mp4" : URL(fileURLWithPath: object["name"] as? String ?? "media.mp4").pathExtension
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("current-media.") }) ?? [] { try? FileManager.default.removeItem(at: file) }
        let target = root.appendingPathComponent("current-media.").appendingPathExtension(ext)
        try? data.write(to: target)
        let type = object["type"] as? String ?? "video/mp4"
        state = ["type": "media", "url": "/" + target.lastPathComponent, "kind": type, "version": Date().timeIntervalSince1970]
        saveState(); respond(200, "{\"ok\":true}", connection, contentType: "application/json")
    }

    private func saveState() { if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: root.appendingPathComponent(".media-state.json")) } }
    func setURL(_ url: String, kind: String) { state = ["type": "url", "url": url, "kind": kind, "version": Date().timeIntervalSince1970]; saveState() }
    func setFile(_ file: URL, name: String, type: String) {
        for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("current-media.") }) ?? [] { try? FileManager.default.removeItem(at: old) }
        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension
        let target = root.appendingPathComponent("current-media.").appendingPathExtension(ext)
        try? FileManager.default.copyItem(at: file, to: target)
        state = ["type": "media", "url": "/" + target.lastPathComponent, "kind": type, "version": Date().timeIntervalSince1970]; saveState()
    }
    func clear() { state = ["type": "empty", "version": Date().timeIntervalSince1970]; saveState() }
    private func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8) }
    private func mime(_ ext: String) -> String { ["html":"text/html", "js":"text/javascript", "css":"text/css", "mp4":"video/mp4", "webm":"video/webm", "mov":"video/quicktime", "jpg":"image/jpeg", "jpeg":"image/jpeg", "png":"image/png", "gif":"image/gif", "mp3":"audio/mpeg" ][ext.lowercased()] ?? "application/octet-stream" }
    private func respond(_ status: Int, _ text: String, _ connection: NWConnection, contentType: String = "text/plain; charset=utf-8") { respond(status, Data(text.utf8), connection, contentType: contentType) }
    private func respond(_ status: Int, _ data: Data, _ connection: NWConnection, contentType: String) { let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"; var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8); response.append(data); connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var webViews: [WKWebView] = []
    var controlWindow: NSWindow?
    var controlController: ControlViewController?
    var statusItem: NSStatusItem?
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    var displayStates: [Int: DisplayMedia] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        for (index, screen) in NSScreen.screens.enumerated() { makeWindow(screen, index: index) }
        makeStatusItem()
        showControlPanel()
    }
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem(title: "Düzen", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Düzen")
        edit.addItem(withTitle: "Geri Al", action: #selector(UndoManager.undo), keyEquivalent: "z").keyEquivalentModifierMask = .command
        edit.addItem(withTitle: "Yinele", action: #selector(UndoManager.redo), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x").keyEquivalentModifierMask = .command
        edit.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c").keyEquivalentModifierMask = .command
        edit.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v").keyEquivalentModifierMask = .command
        edit.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a").keyEquivalentModifierMask = .command
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
    private func makeWindow(_ screen: NSScreen, index: Int) {
        let web = WKWebView(frame: screen.frame, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
        web.setValue(false, forKey: "drawsBackground")
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.contentView = web; window.setFrame(screen.frame, display: true, animate: false); window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))); window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]; window.ignoresMouseEvents = true; window.isOpaque = true; window.backgroundColor = .black; window.orderFrontRegardless(); windows.append(window); webViews.append(web); displayStates[index] = nil
    }
    func setURL(_ url: String, kind: String, target: Int?, quality: String) {
        let indices = target.map({ [$0] }) ?? Array(0..<webViews.count)
        guard kind == "youtube" else { for index in indices { displayStates[index] = DisplayMedia(url: url, kind: kind); applyState(to: index) }; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let media: DisplayMedia?
            if let stream = self.resolveYouTube(url, quality: quality) {
                media = DisplayMedia(url: stream, kind: "video")
            } else if let local = self.downloadYouTube(url, quality: quality) {
                media = DisplayMedia(url: local.lastPathComponent, kind: "video")
            } else {
                media = nil
            }
            DispatchQueue.main.async {
                if let media {
                    for index in indices { self.displayStates[index] = media; self.applyState(to: index) }
                }
            }
        }
    }
    func setFile(_ file: URL, type: String, target: Int?) { let indices = target.map({ [$0] }) ?? Array(0..<webViews.count); let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension; for index in indices { let targetURL = root.appendingPathComponent("display-media-\(index).").appendingPathExtension(ext); try? FileManager.default.removeItem(at: targetURL); try? FileManager.default.copyItem(at: file, to: targetURL); displayStates[index] = DisplayMedia(url: targetURL.lastPathComponent, kind: type); applyState(to: index) } }
    func clear(target: Int?) { let indices = target.map({ [$0] }) ?? Array(0..<webViews.count); for index in indices { displayStates.removeValue(forKey: index); webViews[index].evaluateJavaScript("window.clearNativeMedia && window.clearNativeMedia()") } }
    private func applyState(to index: Int) {
        guard index < webViews.count else { return }
        let script: String
        if let state = displayStates[index] {
            if state.kind == "youtube", let embed = youtubeEmbed(state.url) {
                var request = URLRequest(url: embed)
                request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
                request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                webViews[index].load(request)
                return
            }
            script = "window.setNativeMedia && window.setNativeMedia(\(jsonString(state.url)), \(jsonString(state.kind)))"
        } else {
            script = "window.clearNativeMedia && window.clearNativeMedia()"
        }
        DispatchQueue.main.async { self.webViews[index].evaluateJavaScript(script) }
    }
    private func resolveYouTube(_ url: String, quality: String) -> String? {
        guard let executable = ytDLPURL() else { return nil }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = executable
        task.arguments = ["--no-playlist", "-f", format(for: quality), "-g", url]
        task.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, new in new }
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let lines = String(data: data, encoding: .utf8)?.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) ?? []
        return lines.count == 1 ? String(lines[0]) : nil
    }
    private func downloadYouTube(_ url: String, quality: String) -> URL? {
        guard let executable = ytDLPURL() else { return nil }
        for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("youtube-fallback.") }) ?? [] { try? FileManager.default.removeItem(at: old) }
        let target = root.appendingPathComponent("youtube-fallback.%(ext)s")
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--no-playlist", "-f", format(for: quality), "-o", target.path, url]
        task.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, new in new }
        task.standardOutput = Pipe(); task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        guard task.terminationStatus == 0 else { return nil }
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("youtube-fallback.") })
    }
    private func format(for quality: String) -> String {
        switch quality {
        case "performance": return "bestvideo[height<=720]/bestvideo[height<=1080]/bestvideo"
        case "balanced": return "bestvideo[height<=1080]/bestvideo"
        default: return "bestvideo"
        }
    }
    private func ytDLPURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "yt-dlp", withExtension: nil), FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }
    private func youtubeEmbed(_ value: String) -> URL? {
        guard let parsed = URLComponents(string: value) else { return nil }
        var videoID = parsed.queryItems?.first(where: { $0.name == "v" })?.value
        if videoID == nil, parsed.host?.contains("youtu.be") == true { videoID = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        guard let videoID, !videoID.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")!
        components.queryItems = [URLQueryItem(name: "autoplay", value: "1"), URLQueryItem(name: "mute", value: "1"), URLQueryItem(name: "loop", value: "1"), URLQueryItem(name: "playlist", value: videoID), URLQueryItem(name: "playsinline", value: "1"), URLQueryItem(name: "controls", value: "0"), URLQueryItem(name: "rel", value: "0"), URLQueryItem(name: "origin", value: "https://www.youtube.com"), URLQueryItem(name: "widget_referrer", value: "https://www.youtube.com/")]
        return components.url
    }
    private func jsonString(_ value: String) -> String { (try? String(data: JSONSerialization.data(withJSONObject: [value]), encoding: .utf8))?.dropFirst().dropLast().description ?? "\"\"" }
    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "◉"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Kontrol Panelini Aç", action: #selector(showControlPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Uygulamayı Kapat", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    @objc func showControlPanel() {
        if controlWindow == nil {
            let content = ControlViewController(app: self)
            controlController = content
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Wallpaper Display"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.contentView = content.view
            panel.center()
            panel.isReleasedWhenClosed = false
            controlWindow = panel
        }
        controlWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if let index = webViews.firstIndex(where: { $0 === webView }), displayStates[index]?.kind != "youtube" { applyState(to: index) } }
}

final class ControlViewController: NSViewController {
    weak var app: AppDelegate?
    let urlField = NSTextField(string: "")
    let qualityPopup = NSPopUpButton()
    let targetPopup = NSPopUpButton()
    let statusLabel = NSTextField(labelWithString: "Hazır")
    var screenStatus: [NSTextField] = []
    init(app: AppDelegate) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Wallpaper Display"); title.font = .systemFont(ofSize: 25, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Medya ekranlarını tek panelden yönetin"); subtitle.textColor = .secondaryLabelColor
        let separator1 = NSBox(); separator1.boxType = .separator
        let targetTitle = NSTextField(labelWithString: "Hedef ekran"); targetTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        targetPopup.addItem(withTitle: "Tüm ekranlar")
        for (index, screen) in NSScreen.screens.enumerated() { targetPopup.addItem(withTitle: "Monitör \(index + 1) · \(screen.localizedName)") }
        targetPopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let targetRow = NSStackView(views: [targetTitle, targetPopup]); targetRow.orientation = .horizontal; targetRow.spacing = 14
        let displayTitle = NSTextField(labelWithString: "Ekranlar"); displayTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let screenList = NSStackView(); screenList.orientation = .vertical; screenList.alignment = .leading; screenList.spacing = 7
        for (index, screen) in NSScreen.screens.enumerated() { let state = NSTextField(labelWithString: "Boş"); state.textColor = .secondaryLabelColor; screenStatus.append(state); let row = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: nil) ?? NSImage()), NSTextField(labelWithString: "Monitör \(index + 1) · \(screen.localizedName)"), NSView(), state]); row.orientation = .horizontal; row.spacing = 8; row.widthAnchor.constraint(equalToConstant: 508).isActive = true; screenList.addArrangedSubview(row) }
        let separator2 = NSBox(); separator2.boxType = .separator
        let fileButton = NSButton(title: "Dosya Seç…", target: self, action: #selector(chooseFile)); fileButton.bezelStyle = .rounded
        let urlTitle = NSTextField(labelWithString: "Medya bağlantısı"); urlTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let urlFieldRow = NSStackView(views: [urlField]); urlFieldRow.orientation = .horizontal
        urlField.placeholderString = "https://…/video.mp4 veya YouTube bağlantısı"; urlField.translatesAutoresizingMaskIntoConstraints = false
        qualityPopup.addItems(withTitles: ["Maksimum kalite", "Dengeli", "Performans"])
        qualityPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let qualityRow = NSStackView(views: [NSTextField(labelWithString: "Kalite"), qualityPopup]); qualityRow.orientation = .horizontal; qualityRow.spacing = 12
        let applyButton = NSButton(title: "Bağlantıyı Uygula", target: self, action: #selector(applyURL)); applyButton.bezelStyle = .rounded
        let bottom = NSStackView(); bottom.orientation = .horizontal; bottom.spacing = 10
        let monitorLabel = NSTextField(labelWithString: "◉  \(NSScreen.screens.count) monitör algılandı"); monitorLabel.textColor = .secondaryLabelColor
        let clearButton = NSButton(title: "Seçili hedefi temizle", target: self, action: #selector(clear)); bottom.addArrangedSubview(monitorLabel); bottom.addArrangedSubview(NSView()); bottom.addArrangedSubview(clearButton)
        statusLabel.textColor = .secondaryLabelColor
        [title, subtitle, separator1, targetRow, displayTitle, screenList, separator2, fileButton, urlTitle, urlFieldRow, qualityRow, applyButton, bottom, statusLabel].forEach { stack.addArrangedSubview($0) }
        root.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -26), urlField.widthAnchor.constraint(equalToConstant: 508)])
        view = root
    }
    private var target: Int? { targetPopup.indexOfSelectedItem == 0 ? nil : targetPopup.indexOfSelectedItem - 1 }
    private func updateStatus(_ text: String) { if let target { screenStatus[target].stringValue = text } else { for label in screenStatus { label.stringValue = text } }; statusLabel.stringValue = text }
    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            let response = panel.runModal()
            NSApp.setActivationPolicy(previousPolicy)
            guard response == .OK, let file = panel.url else { return }
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "video/mp4"
            self?.app?.setFile(file, type: type, target: self?.target)
            self?.updateStatus("Dosya uygulandı")
        }
    }
    @objc private func applyURL() { let trimmed = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { statusLabel.stringValue = "Bir bağlantı girin"; return }; let kind = trimmed.localizedCaseInsensitiveContains("youtube.com") || trimmed.localizedCaseInsensitiveContains("youtu.be") ? "youtube" : "video"; let quality = ["maximum", "balanced", "performance"][qualityPopup.indexOfSelectedItem]; app?.setURL(trimmed, kind: kind, target: target, quality: quality); updateStatus("Bağlantı uygulanıyor…") }
    @objc private func clear() { app?.clear(target: target); updateStatus("Hedef temizlendi") }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
