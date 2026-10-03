import AppKit
import VideoToolbox

private final class ReceiveSession {
    let decoder = HardwareDecoder()
    var authenticated = false
    var configured = false
    var lastSequence: UInt64 = 0
    var lastSeen = DispatchTime.now().uptimeNanoseconds
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var videoWindow: NSWindow?
    private let surface = VideoSurface(frame: .zero)
    private let statusLabel = NSTextField(wrappingLabelWithString: "插入雷雳线，在两台 Mac 打开 WiredDisplay。")
    private let cableLabel = NSTextField(labelWithString: "正在检查雷雳接口…")
    private let pairingLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let addressField = NSTextField()
    private let codeField = NSTextField()
    private let quality = NSPopUpButton()
    private var sendButton: NSButton!
    private var receiveButton: NSButton!
    private var stopButton: NSButton!
    private var listener: CableListener?
    private var peer: CablePeer?
    private var sender: AnyObject?
    private var pointerTimer: Timer?
    private var monitorTimer: Timer?
    private var lastCursorImage: Data?
    private var ticks = 0
    private var sessionID = UUID()
    private var code = ""
    private let receiveLock = NSLock()
    private var receiveSession: ReceiveSession?
    private var connecting = false
    private var stopping = false
    private var quitting = false
    private var lastSendPacket = DispatchTime.now().uptimeNanoseconds

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WiredDisplay", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 WiredDisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("拷贝", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WiredDisplay"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 26, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor)
        ])
        let heading = NSTextField(labelWithString: "两台 Mac，一根雷雳线。")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        stack.addArrangedSubview(heading)
        cableLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        cableLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(cableLabel)
        let separator = NSBox(); separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: 404).isActive = true
        receiveButton = NSButton(title: "将这台 Mac 用作显示器", target: self, action: #selector(receive))
        receiveButton.bezelStyle = .rounded
        stack.addArrangedSubview(receiveButton)
        pairingLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        pairingLabel.isSelectable = true
        stack.addArrangedSubview(pairingLabel)
        addressField.placeholderString = "接收端雷雳地址"
        addressField.stringValue = UserDefaults.standard.string(forKey: "receiverAddress") ?? ""
        addressField.setAccessibilityLabel("接收端雷雳地址")
        codeField.placeholderString = "6 位配对码"
        codeField.setAccessibilityLabel("接收端配对码")
        let fields = NSStackView(views: [addressField, codeField])
        fields.spacing = 10
        addressField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        codeField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        stack.addArrangedSubview(fields)
        quality.addItems(withTitles: ["原生清晰 · 60 帧", "4K 流畅 · 60 帧"])
        quality.selectItem(at: UserDefaults.standard.integer(forKey: "quality"))
        quality.setAccessibilityLabel("画质")
        sendButton = NSButton(title: "扩展到这台 Mac", target: self, action: #selector(sendDisplay))
        sendButton.bezelStyle = .rounded
        let actions = NSStackView(views: [quality, sendButton])
        actions.spacing = 12
        stack.addArrangedSubview(actions)
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.widthAnchor.constraint(equalToConstant: 404).isActive = true
        stack.addArrangedSubview(statusLabel)
        metricsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metricsLabel.textColor = .secondaryLabelColor
        metricsLabel.toolTip = "从送入编码器到接收端提交画面、确认返回的耗时。不是屏幕实际亮起的延迟。静止桌面会自动减少帧数。"
        stack.addArrangedSubview(metricsLabel)
        versionLabel.stringValue = "WiredDisplay \(Wire.appVersion) · Protocol \(Wire.protocolVersion)"
        versionLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(versionLabel)
        stopButton = NSButton(title: "断开", target: self, action: #selector(disconnect))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false
        stack.addArrangedSubview(stopButton)
        window.makeKeyAndOrderFront(nil)
    }

    private func setBusy(_ busy: Bool) {
        sendButton.isEnabled = !busy
        receiveButton.isEnabled = !busy
        addressField.isEnabled = !busy
        codeField.isEnabled = !busy
        quality.isEnabled = !busy
        stopButton.isEnabled = busy && !stopping
    }
    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.endSession(message) }
    }

    @objc private func receive() {
        guard let cable = CableAddress.current() else { statusLabel.stringValue = "未找到雷雳网络地址。请连接两台 Mac，并检查系统设置 → 网络 → 雷雳网桥。"; return }
        do {
            let listener = try CableListener(cable: cable)
            code = String(format: "%06d", Int.random(in: 0...999999))
            self.listener = listener
            sessionID = UUID()
            let generation = sessionID
            listener.onAccept = { [weak self] accepted in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == generation, self.listener != nil, self.peer == nil else {
                        accepted.stop(); accepted.start(); return
                    }
                    self.accept(accepted, code: self.code)
                }
            }
            listener.start()
            pairingLabel.stringValue = "地址 \(cable.ip)    配对码 \(code)"
            statusLabel.stringValue = "监听中 · TCP \(Wire.port)\n在 MacBook 填入地址与配对码。接收后自动全屏，Esc 返回。"
            setBusy(true)
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    private func panelProfile() -> DisplayProfile {
        let screen = window.screen ?? NSScreen.main!
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
        let native = modes.filter { $0.pixelWidth <= 5120 && $0.pixelHeight <= 2880 }
            .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        let width = native?.pixelWidth ?? CGDisplayPixelsWide(id)
        let height = native?.pixelHeight ?? CGDisplayPixelsHigh(id)
        return DisplayProfile(width: width, height: height, hiDPI: screen.backingScaleFactor > 1,
                              hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                              appVersion: Wire.appVersion)
    }

    private func accept(_ accepted: CablePeer, code: String) {
        let session = ReceiveSession()
        let profile = panelProfile()
        receiveLock.lock(); receiveSession = session; receiveLock.unlock()
        peer = accepted
        let generation = sessionID
        session.decoder.onImage = { [weak self] image, sequence in self?.surface.offer(image, sequence: sequence) }
        session.decoder.onFailure = { [weak accepted] _ in accepted?.stop() }
        accepted.onPacket = { [weak self, weak accepted] kind, data in
            guard let self, let accepted else { return }
            self.receiveLock.lock(); session.lastSeen = DispatchTime.now().uptimeNanoseconds; self.receiveLock.unlock()
            if !session.authenticated {
                guard kind == .hello else { throw WireError.invalid("请先配对") }
                let hello = try Wire.decode(Hello.self, data)
                guard hello.version == Wire.protocolVersion else {
                    throw WireError.invalid("协议版本不兼容，请在两台 Mac 安装同一版本 WiredDisplay")
                }
                guard hello.appVersion == Wire.appVersion else {
                    throw WireError.invalid("发射端版本 \(hello.appVersion ?? "旧版") 与接收端 \(Wire.appVersion) 不一致，请更新两台 Mac")
                }
                guard hello.code == code else { throw WireError.invalid("配对码不正确") }
                session.authenticated = true
                try profile.validate()
                accepted.send(.profile, try Wire.json(profile))
                return
            }
            switch kind {
            case .configuration:
                guard !session.configured else { throw WireError.invalid("重复视频配置") }
                let config = try Wire.decode(VideoConfiguration.self, data)
                guard config.width <= profile.width, config.height <= profile.height else { throw WireError.invalid("视频超过接收屏幕尺寸") }
                try session.decoder.configure(config)
                session.configured = true
            case .video:
                guard session.configured else { throw WireError.invalid("未配置解码器") }
                let sequence = try Wire.integer(data, at: 0, as: UInt64.self)
                guard sequence > session.lastSequence, sequence <= UInt64(Int64.max) else { throw WireError.invalid("视频序号错误") }
                session.lastSequence = sequence
                try session.decoder.decode(data)
            case .cursor:
                let pointer = try Wire.decode(PointerUpdate.self, data)
                try pointer.validate()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionID == generation else { return }
                    self.surface.setPointer(pointer)
                }
            case .heartbeat: accepted.send(.heartbeat)
            case .end: accepted.stop()
            default: throw WireError.invalid("接收端收到不支持的消息")
            }
        }
        accepted.onClose = { [weak self] reason in
            session.decoder.stop()
            DispatchQueue.main.async {
                guard let self, self.sessionID == generation else { return }
                self.endSession(reason)
            }
        }
        surface.onSubmit = { [weak accepted] sequence in
            var data = Data(); Wire.append(sequence, to: &data)
            accepted?.send(.acknowledgment, data)
        }
        surface.onFirstImage = { [weak self] in self?.showVideo() }
        accepted.start()
        statusLabel.stringValue = "正在接收画面…"
    }

    private func showVideo() {
        guard videoWindow == nil else { return }
        let screen = window.screen ?? NSScreen.main!
        let video = NSWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false, screen: screen)
        video.title = "WiredDisplay · Esc 返回"
        video.isReleasedWhenClosed = false
        video.collectionBehavior = [.fullScreenPrimary]
        video.delegate = self
        video.contentView = surface
        videoWindow = video
        video.makeKeyAndOrderFront(nil)
        video.toggleFullScreen(nil)
        statusLabel.stringValue = "已连接 · 仅雷雳有线"
    }

    @objc private func sendDisplay() {
        guard #available(macOS 14.0, *) else { statusLabel.stringValue = "发送扩展屏需要 macOS 14 或更新；这台 Mac 仍可作接收端。"; return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            statusLabel.stringValue = "请在系统设置 → 隐私与安全性 → 屏幕录制中允许 WiredDisplay，然后退出并重新打开。"
            return
        }
        guard let cable = CableAddress.current() else { statusLabel.stringValue = "请连接雷雳线，并等待雷雳网桥获得地址。"; return }
        let ip = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { statusLabel.stringValue = "请输入接收端显示的 6 位配对码。"; return }
        UserDefaults.standard.set(ip, forKey: "receiverAddress")
        UserDefaults.standard.set(quality.indexOfSelectedItem, forKey: "quality")
        sessionID = UUID()
        let generation = sessionID
        let limited = quality.indexOfSelectedItem == 1
        connecting = true
        setBusy(true)
        statusLabel.stringValue = "正在通过雷雳连接…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let peer = try CablePeer.connect(ip: ip, cable: cable)
                DispatchQueue.main.async {
                    guard let self, self.sessionID == generation else { peer.stop(); peer.start(); return }
                    self.connecting = false
                    self.peer = peer
                    self.lastSendPacket = DispatchTime.now().uptimeNanoseconds
                    var receivedProfile = false
                    peer.onPacket = { [weak self] kind, data in
                        guard let self, let connection = self.peer else { return }
                        DispatchQueue.main.async { self.lastSendPacket = DispatchTime.now().uptimeNanoseconds }
                        switch kind {
                        case .profile:
                            guard !receivedProfile else { throw WireError.invalid("重复屏幕信息") }
                            receivedProfile = true
                            let profile = try Wire.decode(DisplayProfile.self, data)
                            try profile.validate()
                            guard profile.appVersion == Wire.appVersion else {
                                throw WireError.invalid("接收端版本 \(profile.appVersion ?? "旧版") 与发射端 \(Wire.appVersion) 不一致，请更新两台 Mac")
                            }
                            Task { @MainActor [weak self] in
                                guard let self, self.sessionID == generation else { return }
                                let selected = profile.limited(to4K: limited)
                                let sender = ScreenSender(peer: connection)
                                self.sender = sender
                                sender.onFailure = { [weak self] message in self?.fail(message) }
                                sender.onStats = { [weak self] text in
                                    DispatchQueue.main.async {
                                        guard let self, self.sessionID == generation else { return }
                                        self.metricsLabel.stringValue = text
                                    }
                                }
                                do {
                                    try await sender.start(profile: selected)
                                    guard self.sessionID == generation else { await sender.stop(); return }
                                    self.statusLabel.stringValue = "已扩展 · \(selected.width) × \(selected.height) · 60 帧目标\n在系统设置 → 显示器中调整屏幕排列。"
                                    self.startPointer(sender: sender, peer: connection)
                                } catch { if self.sessionID == generation { self.endSession(error.localizedDescription) } }
                            }
                        case .acknowledgment:
                            DispatchQueue.main.async {
                                guard self.sessionID == generation else { return }
                                (self.sender as? ScreenSender)?.acknowledge(data)
                            }
                        case .heartbeat: break
                        case .end: connection.stop()
                        default: throw WireError.invalid("发送端收到不支持的消息")
                        }
                    }
                    peer.onClose = { [weak self] message in
                        DispatchQueue.main.async {
                            guard let self, self.sessionID == generation else { return }
                            self.endSession(message)
                        }
                    }
                    peer.start()
                    peer.send(.hello, (try? Wire.json(Hello(version: 1, code: code))) ?? Data())
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.sessionID == generation else { return }
                    self.endSession(error.localizedDescription)
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private func startPointer(sender: ScreenSender, peer: CablePeer) {
        lastCursorImage = nil
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak sender, weak peer] _ in
            guard let self, let sender, let peer, let event = CGEvent(source: nil) else { return }
            let rect = CGDisplayBounds(sender.displayID)
            guard rect.width > 0, rect.height > 0 else { return }
            let location = event.location
            guard let cursor = NSCursor.currentSystem else { return }
            let bitmap = cursor.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            let image = bitmap?.representation(using: .png, properties: [:])
            let changed = image != self.lastCursorImage
            self.lastCursorImage = image
            let pixelWidth = Double(bitmap?.pixelsWide ?? 32)
            let pixelHeight = Double(bitmap?.pixelsHigh ?? 32)
            let scale = pixelWidth / max(1, cursor.image.size.width)
            let pointer = PointerUpdate(x: (location.x - rect.minX) / rect.width,
                y: (location.y - rect.minY) / rect.height, visible: rect.contains(location),
                hotX: cursor.hotSpot.x * scale, hotY: cursor.hotSpot.y * scale,
                width: pixelWidth, height: pixelHeight, png: changed ? image : nil)
            // Hidden positions are clamped to keep the protocol bounded across screen arrangements.
            let bounded = PointerUpdate(x: min(2, max(-2, pointer.x)), y: min(2, max(-2, pointer.y)),
                visible: pointer.visible, hotX: pointer.hotX, hotY: pointer.hotY,
                width: pointer.width, height: pointer.height, png: pointer.png)
            if let payload = try? Wire.json(bounded) { peer.sendPointer(payload) }
        }
        RunLoop.main.add(pointerTimer!, forMode: .common)
    }

    private func tick() {
        let cable = CableAddress.current()
        cableLabel.stringValue = cable.map { "雷雳网桥  \($0.ip)" } ?? "雷雳网桥  未就绪"
        let now = DispatchTime.now().uptimeNanoseconds
        if let peer {
            receiveLock.lock(); let receiver = receiveSession; let last = receiver?.lastSeen; receiveLock.unlock()
            if let last, now > last, now - last > 8_000_000_000 { endSession("接收超时，请重新连接。"); return }
            if receiver == nil {
                peer.send(.heartbeat)
                if now > lastSendPacket, now - lastSendPacket > 8_000_000_000 { endSession("对方未响应，请检查雷雳连接。"); return }
            }
        }
        if cable == nil && (peer != nil || listener != nil) { endSession("雷雳连接已断开。") }
    }

    @objc private func disconnect() { endSession("已断开，可以开始新的连接。") }
    private func endSession(_ message: String) {
        guard !stopping else { return }
        stopping = true
        sessionID = UUID()
        connecting = false
        pointerTimer?.invalidate(); pointerTimer = nil
        listener?.stop(); listener = nil
        peer?.stop(); peer = nil
        receiveLock.lock(); receiveSession = nil; receiveLock.unlock()
        videoWindow?.orderOut(nil); videoWindow = nil
        surface.reset()
        surface.onSubmit = nil; surface.onFirstImage = nil
        pairingLabel.stringValue = ""
        metricsLabel.stringValue = ""
        statusLabel.stringValue = message
        setBusy(true)
        let previous = sender
        sender = nil
        Task { @MainActor in
            if #available(macOS 14.0, *), let sender = previous as? ScreenSender { await sender.stop() }
            self.stopping = false
            self.setBusy(false)
            if self.quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "WiredDisplay 0.1"
        alert.informativeText = "仅雷雳有线扩展屏。采用 macOS 原生采集、硬件编解码与原生画面显示。\n\n部分虚拟屏与消息封装思路来自 TargetBridge（MIT，Marco Caciotti）。独立实现，不与 Duet 私有协议互通。"
        alert.runModal()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === videoWindow { endSession("显示已停止。"); return false }
        NSApp.terminate(nil)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if self.sender == nil && !stopping { listener?.stop(); peer?.stop(); return .terminateNow }
        quitting = true
        if !stopping { endSession("正在停止…") }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum WiredDisplayApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
