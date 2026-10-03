import AppKit
import Network
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
    private var testButton: NSButton!
    private let discovery = CableDiscovery()
    private var candidates: [ObjectIdentifier: CablePeer] = [:]
    private var diagnosticLines: [String] = []
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
    private var transportReady = false
    private var connecting = false
    private var stopping = false
    private var quitting = false
    private var lastSendPacket = DispatchTime.now().uptimeNanoseconds

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        discovery.onReceivers = { [weak self] addresses in
            guard let self, !self.connecting, self.peer == nil else { return }
            let remote = addresses.filter { $0 != CableAddress.current()?.ip }
            if self.addressField.stringValue.isEmpty, remote.count == 1 {
                self.addressField.stringValue = remote[0]
            }
        }
        discovery.start()
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
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
        testButton = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
        let networkSettings = NSButton(title: "本地网络设置", target: self, action: #selector(openNetworkSettings))
        let copy = NSButton(title: "拷贝诊断", target: self, action: #selector(copyDiagnostics))
        stack.addArrangedSubview(NSStackView(views: [testButton, networkSettings, copy]))
        statusLabel.isSelectable = true
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
        testButton.isEnabled = !busy
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
                DispatchQueue.main.async { [accepted] in
                    guard let self, self.sessionID == generation, self.listener != nil,
                          self.candidates.count < 8 else { accepted.stop(); return }
                    self.candidates[ObjectIdentifier(accepted)] = accepted
                    self.accept(accepted, code: self.code)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak accepted] in
                        guard let self, let accepted,
                              self.candidates[ObjectIdentifier(accepted)] != nil else { return }
                        accepted.stop()
                    }
                }
            }
            listener.onState = { [weak self] message, _ in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == generation else { return }
                    self.record(message)
                }
            }
            listener.start()
            pairingLabel.stringValue = "地址 \(cable.ip)    配对码 \(code)"
            record("正在启动接收端 · \(cable.description)")
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
        let generation = sessionID
        session.decoder.onImage = { [weak self, weak session] image, sequence in
            guard let self, let session else { return }
            self.receiveLock.lock()
            if self.receiveSession === session { self.surface.offer(image, sequence: sequence) }
            self.receiveLock.unlock()
        }
        session.decoder.onFailure = { [weak accepted] _ in accepted?.stop() }
        accepted.onPacket = { [weak self, weak accepted] kind, data in
            guard let self, let accepted else { return }
            self.receiveLock.lock(); session.lastSeen = DispatchTime.now().uptimeNanoseconds; self.receiveLock.unlock()
            if !session.authenticated {
                do {
                    guard kind == .hello else { throw WireError.invalid("请先配对") }
                    let hello = try Wire.decode(Hello.self, data)
                    guard hello.version == Wire.protocolVersion else {
                        throw WireError.invalid("协议版本不兼容，请更新两台 Mac")
                    }
                    guard hello.code == code else { throw WireError.invalid("配对码不正确") }
                    try profile.validate()
                    if hello.probe == true {
                        accepted.send(.profile, try Wire.json(profile)) { accepted.stop() }
                        return
                    }
                    let promoted = DispatchQueue.main.sync { () -> Bool in
                        guard self.sessionID == generation, self.listener != nil else { return false }
                        self.candidates.removeValue(forKey: ObjectIdentifier(accepted))
                        let previous = self.peer
                        self.peer = accepted
                        self.receiveLock.lock(); self.receiveSession = session; self.receiveLock.unlock()
                        previous?.stop()
                        self.surface.reset()
                        self.surface.onSubmit = { [weak accepted] sequence in
                            var data = Data(); Wire.append(sequence, to: &data)
                            accepted?.send(.acknowledgment, data)
                        }
                        self.surface.onFirstImage = { [weak self] in self?.showVideo() }
                        self.record("配对通过 · 发射端 \(hello.appVersion ?? "未知") · 等待视频配置")
                        return true
                    }
                    guard promoted else { accepted.stop(); return }
                    session.authenticated = true
                    accepted.send(.profile, try Wire.json(profile))
                } catch {
                    accepted.send(.end, Data(error.localizedDescription.utf8)) { accepted.stop() }
                }
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
                    guard let self, self.sessionID == generation, self.peer === accepted else { return }
                    self.surface.setPointer(pointer)
                }
            case .heartbeat: accepted.send(.heartbeat)
            case .end: accepted.stop()
            default: throw WireError.invalid("接收端收到不支持的消息")
            }
        }
        accepted.onClose = { [weak self, weak accepted] reason in
            session.decoder.stop()
            DispatchQueue.main.async {
                guard let self, let accepted, self.sessionID == generation else { return }
                self.candidates.removeValue(forKey: ObjectIdentifier(accepted))
                guard self.peer === accepted else {
                    if self.peer == nil { self.record("\(reason) · 监听中 · TCP \(Wire.port)") }
                    return
                }
                self.peer = nil
                self.receiveLock.lock(); self.receiveSession = nil; self.receiveLock.unlock()
                self.surface.reset()
                self.videoWindow?.orderOut(nil); self.videoWindow = nil
                self.record("\(reason)；接收端仍在监听，可直接重连。")
            }
        }
        accepted.onState = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.sessionID == generation else { return }
                self.record(message)
            }
        }
        accepted.start()
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

    @objc private func sendDisplay() { startConnection(probe: false) }
    @objc private func testConnection() { startConnection(probe: true) }

    private func startConnection(probe: Bool) {
        guard #available(macOS 14.0, *) else { statusLabel.stringValue = "发送扩展屏需要 macOS 14 或更新。"; return }
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
        diagnosticLines.removeAll()
        record("WiredDisplay \(Wire.appVersion) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        record("本机 \(cable.description) → \(ip):\(Wire.port)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let peer = try CablePeer.connect(ip: ip, cable: cable)
                DispatchQueue.main.async { [peer] in
                    guard let self, self.sessionID == generation else { peer.stop(); return }
                    self.connecting = false
                    self.peer = peer
                    self.lastSendPacket = DispatchTime.now().uptimeNanoseconds
                    var receivedProfile = false
                    peer.onPacket = { [weak self, weak peer] kind, data in
                        guard let self, let connection = peer else { return }
                        DispatchQueue.main.async {
                            guard self.sessionID == generation else { return }
                            self.lastSendPacket = DispatchTime.now().uptimeNanoseconds
                        }
                        switch kind {
                        case .profile:
                            guard !receivedProfile else { throw WireError.invalid("重复屏幕信息") }
                            let profile = try Wire.decode(DisplayProfile.self, data)
                            try profile.validate()
                            receivedProfile = true
                            Task { @MainActor [weak self] in
                                guard let self, self.sessionID == generation else { return }
                                self.record("配对通过 · 已收到 \(profile.width) × \(profile.height) 屏幕参数 · 接收端 \(profile.appVersion ?? "未知")")
                                if probe { self.endSession("测试成功：雷雳 TCP、配对与屏幕参数交换均已通过。"); return }
                                guard CGPreflightScreenCaptureAccess() else {
                                    CGRequestScreenCaptureAccess()
                                    self.endSession("网络连接已验证。请允许屏幕录制后重新连接。")
                                    return
                                }
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
                        case .end:
                            guard data.count < 4096 else { throw WireError.invalid("错误消息过大") }
                            let reason = String(data: data, encoding: .utf8) ?? "对方结束连接"
                            DispatchQueue.main.async {
                                guard self.sessionID == generation else { return }
                                self.endSession(reason)
                            }
                        default: throw WireError.invalid("发送端收到不支持的消息")
                        }
                    }
                    peer.onClose = { [weak self] message in
                        let probeCompleted = probe && receivedProfile
                        DispatchQueue.main.async {
                            guard let self, self.sessionID == generation else { return }
                            if probeCompleted { return }
                            let detail = self.transportReady && !probeCompleted && self.sender == nil
                                ? "TCP 已连接，接收端未完成屏幕参数交换：\(message)。旧版接收端可能因版本或配对码不符而直接断开；请更新两台 Mac。"
                                : message
                            self.endSession(detail)
                        }
                    }
                    peer.onState = { [weak self] message in
                        DispatchQueue.main.async {
                            guard let self, self.sessionID == generation else { return }
                            self.record(message)
                        }
                    }
                    peer.onReady = { [weak peer] in
                        peer?.send(.hello, (try? Wire.json(Hello(version: Wire.protocolVersion, code: code, probe: probe))) ?? Data())
                        DispatchQueue.main.async {
                            guard self.sessionID == generation else { return }
                            self.transportReady = true
                            self.lastSendPacket = DispatchTime.now().uptimeNanoseconds
                            self.record("TCP 已连接 · 正在验证配对并交换屏幕参数")
                        }
                    }
                    peer.start()
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
        cableLabel.stringValue = cable.map { "雷雳网桥  \($0.ip) · \($0.name)" } ?? "雷雳网桥  未就绪"
        let now = DispatchTime.now().uptimeNanoseconds
        if let peer {
            receiveLock.lock(); let receiver = receiveSession; let last = receiver?.lastSeen; receiveLock.unlock()
            if let last, now > last, now - last > 8_000_000_000 { peer.stop(); return }
            if receiver == nil && transportReady {
                if sender != nil { peer.send(.heartbeat) }
                if now > lastSendPacket, now - lastSendPacket > 8_000_000_000 {
                    endSession("TCP 已连接，但对方未返回有效协议消息；请检查接收端版本与配对码。")
                    return
                }
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
        transportReady = false
        pointerTimer?.invalidate(); pointerTimer = nil
        listener?.stop(); listener = nil
        for candidate in candidates.values { candidate.stop() }
        candidates.removeAll()
        peer?.stop(); peer = nil
        receiveLock.lock(); receiveSession = nil; receiveLock.unlock()
        videoWindow?.orderOut(nil); videoWindow = nil
        surface.reset()
        surface.onSubmit = nil; surface.onFirstImage = nil
        pairingLabel.stringValue = ""
        metricsLabel.stringValue = ""
        record(message)
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
    private func record(_ message: String) {
        diagnosticLines.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        if diagnosticLines.count > 100 { diagnosticLines.removeFirst() }
        statusLabel.stringValue = message
        NSLog("%@", message)
    }
    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticLines.joined(separator: "\n"), forType: .string)
    }
    @objc private func openNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")!)
    }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "WiredDisplay \(Wire.appVersion)"
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
