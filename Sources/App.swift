import AppKit
import Darwin
import Network
import VideoToolbox
import WebKit

private final class ReceiveSession {
    let decoder = HardwareDecoder()
    let audio = AudioRenderer()
    var authenticated = false
    var configured = false
    var lastSequence: UInt64 = 0
    var lastSeen = DispatchTime.now().uptimeNanoseconds
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    private enum Page: CaseIterable { case connection, diagnostics, settings }

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
    private let quality = NSSegmentedControl(labels: ["原生 Retina", "4K 流畅"], trackingMode: .selectOne, target: nil, action: nil)
    private var transmissionMode = TransmissionMode(rawValue: UserDefaults.standard.string(forKey: "transmissionMode") ?? "") ?? .lowLatency
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
    private var monitorTimer: Timer?
    private var firstFrameAcknowledged = false
    private var receiverCursorHidden = false
    private var statusItem: NSStatusItem?
    private var statusText: NSMenuItem?
    private var disconnectItem: NSMenuItem?
    private var reconnectItem: NSMenuItem?
    private var systemSleeping = false
    private var resumeAfterSleep = false
    private var reconnectAttempt = false
    private var pendingReconnect = false
    private var reconnectDeadline = Date.distantPast
    private var ticks = 0
    private var sessionID = UUID()
    private var code = ""
    private var mirrorRequested = false
    private var audioRequested = true
    private let receiveLock = NSLock()
    private var receiveSession: ReceiveSession?
    private var transportReady = false
    private var connecting = false
    private var stopping = false
    private var quitting = false
    private var lastSendPacket = DispatchTime.now().uptimeNanoseconds
    private var pages: [Page: NSView] = [:]
    private var navigation: [Page: NSButton] = [:]
    private var senderControls: NSView!
    private var receiverControls: NSView!
    private var roleControl: NSSegmentedControl!
    private var mainActionButton: NSButton!
    private var displaySleepButton: NSButton!
    private var selectedDeviceButton: NSButton!
    private var contentStack: NSStackView!
    private var toolbarTitle: NSTextField!
    private var sleepActivity: NSObjectProtocol?
    private var receiverKeepAwake = true
    private var remoteSleepRequested = true
    private var webView: WKWebView?
    private let touchBar = TouchBarService()
    private let roleLabel = NSTextField(labelWithString: "本机作为主机")
    private let connectionStateLabel = NSTextField(labelWithString: "未连接")
    private let diagnosticCableLabel = NSTextField(labelWithString: "正在检查雷雳网桥…")
    private let diagnosticStatusLabel = NSTextField(wrappingLabelWithString: "等待连接诊断")

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppIcon()
        buildMenu()
        buildWindow()
        buildStatusMenu()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(monitorTimer!, forMode: .common)
        discovery.onReceivers = { [weak self] addresses in
            guard let self, !self.connecting, self.peer == nil else { return }
            let remote = addresses.filter { $0 != CableAddress.current()?.ip }
            if self.addressField.stringValue.isEmpty, remote.count == 1 {
                self.addressField.stringValue = remote[0]
            }
        }
        discovery.start()
        tick()
        if UserDefaults.standard.bool(forKey: "displayRole") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.receive() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusText = menu.addItem(withTitle: "未连接", action: nil, keyEquivalent: "")
        statusText?.isEnabled = false
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "打开 Thunder Display", action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        disconnectItem = menu.addItem(withTitle: "断开连接", action: #selector(disconnect), keyEquivalent: "")
        disconnectItem?.target = self
        reconnectItem = menu.addItem(withTitle: "重新连接", action: #selector(reconnectFromMenu), keyEquivalent: "")
        reconnectItem?.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Thunder Display", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        item.menu = menu
        item.isVisible = UserDefaults.standard.object(forKey: "menuBarStatus") == nil || UserDefaults.standard.bool(forKey: "menuBarStatus")
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        let live = !stopping && !systemSleeping && peer != nil && (firstFrameAcknowledged || videoWindow != nil)
        let busy = connecting || pendingReconnect || (peer != nil && !live)
        let label = systemSleeping ? "已暂停" : stopping ? "正在断开" : live ? "已连接" : busy ? "正在连接" : listener != nil ? "等待主机连接" : "未连接"
        let symbol = live ? "display" : busy ? "arrow.triangle.2.circlepath" : "display.trianglebadge.exclamationmark"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: label)
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = "Thunder Display · \(label)"
        statusText?.title = label
        disconnectItem?.isEnabled = !stopping && (peer != nil || listener != nil || connecting || pendingReconnect)
        reconnectItem?.isEnabled = !stopping && !systemSleeping
    }

    @objc private func showMainWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reconnectFromMenu() {
        endSession("正在重新连接…")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        pendingReconnect = true
        reconnectDeadline = Date().addingTimeInterval(30)
        updateStatusMenu()
    }

    @objc private func systemWillSleep() {
        guard !systemSleeping else { return }
        resumeAfterSleep = peer != nil || listener != nil || connecting || pendingReconnect
        systemSleeping = true
        endSession("系统进入睡眠，已暂停连接。")
    }

    @objc private func systemDidWake() {
        guard systemSleeping else { return }
        systemSleeping = false
        let resume = resumeAfterSleep
        resumeAfterSleep = false
        endSession("系统已唤醒，旧显示会话已清理。")
        let automatic = UserDefaults.standard.object(forKey: "autoReconnect") == nil || UserDefaults.standard.bool(forKey: "autoReconnect")
        if resume && (UserDefaults.standard.bool(forKey: "displayRole") || automatic) { scheduleReconnect() }
    }

    // Retry transport failures while the other Mac is still waking up. Explicit
    // disconnect, role changes and successful first-frame delivery cancel retries.
    private func connectionFailed(_ message: String) {
        let retry = reconnectAttempt && Date() < reconnectDeadline && !quitting && !systemSleeping
        let deadline = reconnectDeadline
        endSession(message)
        if retry {
            pendingReconnect = true
            reconnectDeadline = deadline
        }
    }

    private func clearVideoPresentation() {
        if receiverCursorHidden { NSCursor.unhide(); receiverCursorHidden = false }
        let video = videoWindow
        videoWindow = nil
        video?.delegate = nil
        video?.orderOut(nil)
        video?.close()
        surface.reset()
        surface.onSubmit = nil
        surface.onFirstImage = nil
        updateSleepActivity()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Thunder Display", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Thunder Display", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        buildPrototypeWindow()
    }

    private func legacyBuildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Thunder Display"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 560)
        window.center()

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])

        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 5
        sidebar.edgeInsets = NSEdgeInsets(top: 24, left: 14, bottom: 14, right: 14)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 205).isActive = true
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        root.addArrangedSubview(sidebar)

        let brand = NSTextField(labelWithString: "◈  Thunder Display")
        brand.font = .systemFont(ofSize: 15, weight: .semibold)
        sidebar.addArrangedSubview(brand)
        sidebar.addArrangedSubview(sectionLabel("设备"))
        selectedDeviceButton = NSButton(title: "▣  远端 Mac\n     型号未发现 · 系统版本未发现", target: self, action: #selector(showConnectionPage))
        selectedDeviceButton.alignment = .left
        selectedDeviceButton.lineBreakMode = .byWordWrapping
        selectedDeviceButton.bezelStyle = .texturedRounded
        selectedDeviceButton.setAccessibilityLabel("当前设备")
        sidebar.addArrangedSubview(selectedDeviceButton)
        sidebar.addArrangedSubview(sectionLabel("工具"))
        let diagnosticsButton = navigationButton("◌  配置检查", page: .diagnostics)
        let settingsButton = navigationButton("⚙  偏好设置", page: .settings)
        sidebar.addArrangedSubview(diagnosticsButton)
        sidebar.addArrangedSubview(settingsButton)
        let spacer = NSView(); sidebar.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        versionLabel.stringValue = "WiredDisplay \(Wire.appVersion) · Protocol \(Wire.protocolVersion)"
        versionLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.lineBreakMode = .byTruncatingTail
        sidebar.addArrangedSubview(versionLabel)

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 0
        main.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(main)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarTitle = NSTextField(labelWithString: "主机 · 远端 Mac")
        toolbarTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        toolbar.addArrangedSubview(toolbarTitle)
        let toolbarSpacer = NSView(); toolbar.addArrangedSubview(toolbarSpacer)
        toolbarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let refresh = NSButton(title: "↻", target: self, action: #selector(refreshCable))
        refresh.toolTip = "刷新雷雳网桥"
        refresh.bezelStyle = .texturedRounded
        toolbar.addArrangedSubview(refresh)
        testButton = NSButton(title: "检测雷雳线", target: self, action: #selector(testConnection))
        testButton.bezelStyle = .texturedRounded
        toolbar.addArrangedSubview(testButton)
        mainActionButton = NSButton(title: "扩展到远端 Mac", target: self, action: #selector(sendDisplay))
        mainActionButton.bezelStyle = .rounded
        mainActionButton.keyEquivalent = "\r"
        toolbar.addArrangedSubview(mainActionButton)
        main.addArrangedSubview(toolbar)
        let divider = NSBox(); divider.boxType = .separator; main.addArrangedSubview(divider)

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        main.addArrangedSubview(contentStack)
        contentStack.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        contentStack.heightAnchor.constraint(equalTo: main.heightAnchor, constant: -52).isActive = true
        pages[.connection] = buildConnectionPage()
        pages[.diagnostics] = buildDiagnosticsPage()
        pages[.settings] = buildSettingsPage()
        for page in Page.allCases {
            if let view = pages[page] { contentStack.addArrangedSubview(view); view.isHidden = page != .connection }
        }
        showPage(.connection)
        updateRoleUI()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildPrototypeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Thunder Display"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 560)
        window.center()

        // These controls retain the existing session implementation without adding
        // another connection path beside the approved prototype.
        sendButton = NSButton()
        testButton = NSButton()
        receiveButton = NSButton()
        stopButton = NSButton()
        quality.selectedSegment = UserDefaults.standard.integer(forKey: "quality")
        addressField.stringValue = UserDefaults.standard.string(forKey: "receiverAddress") ?? ""
        if !addressField.stringValue.isEmpty {
            codeField.stringValue = UserDefaults.standard.string(forKey: "pairingCode.\(addressField.stringValue)") ?? ""
        }

        let controller = WKUserContentController()
        controller.add(self, name: "thunderDisplay")
        controller.addUserScript(WKUserScript(source: "if (localStorage.getItem('tb-mvp-data-version') !== '3') { localStorage.removeItem('tb-mvp-connected'); localStorage.setItem('tb-mvp-data-version', '3'); }", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: nativeBridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        webView = web
        guard let url = Bundle.main.url(forResource: "mvp-ui-prototype", withExtension: "html") else {
            fatalError("Missing approved MVP prototype")
        }
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.prototypeVersion()
            self.prototypeDiagnostics(CableAddress.current())
            if self.listener != nil {
                self.prototypeListening(true)
                self.prototypePairing(address: CableAddress.current()?.ip, code: self.code)
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    private var nativeBridgeScript: String {
        """
        (() => {
          const post = (action, value = {}) => window.webkit?.messageHandlers?.thunderDisplay?.postMessage({ action, ...value });
          const role = () => document.querySelector('[data-local-role].active')?.dataset.localRole || 'host';
          const output = () => document.querySelector('[data-output-mode].active')?.dataset.outputMode || 'extend';
          const audio = () => document.getElementById('audio-relay')?.classList.contains('on') || false;
          const preventSleep = () => document.getElementById('prevent-sleep')?.classList.contains('on') || false;
          const selectedDevice = () => {
            try {
              const all = JSON.parse(localStorage.getItem('tb-mvp-devices') || '[]');
              const id = localStorage.getItem('tb-mvp-selected');
              return all.find((device) => device.id === id) || all[0] || {};
            } catch (_) { return {}; }
          };
          document.addEventListener('click', (event) => {
            const button = event.target.closest('button');
            if (!button) return;
            if (button.id === 'toolbar-connect') {
              event.preventDefault(); event.stopImmediatePropagation();
              const device = selectedDevice();
              post('session', { role: role(), output: output(), audio: audio(), preventSleep: preventSleep(), address: device.ip || '', code: device.pairingCode || '', transmissionMode: document.getElementById('transmission-mode').value, resolution: document.getElementById('stream-resolution').value });
            } else if (button.id === 'version-refresh') {
              event.preventDefault(); event.stopImmediatePropagation();
              const device = selectedDevice();
              post('test', { address: device.ip || '', code: device.pairingCode || '' });
            } else if (button.id === 'toolbar-test' || button.id === 'run-test') {
              const device = selectedDevice();
              post('test', { address: device.ip || '', code: device.pairingCode || '' });
            } else if (button.id === 'refresh') {
              event.preventDefault(); event.stopImmediatePropagation(); post('refresh');
            } else if (button.id === 'modal-save') {
              const device = {
                address: document.getElementById('device-ip')?.value || '',
                code: document.getElementById('device-code')?.value || ''
              };
              post('device', device);
            } else if (button.matches('[data-local-role]')) {
              setTimeout(() => {
                if (!document.querySelector('#role-modal.show')) post('role', { role: button.dataset.localRole });
              }, 0);
            } else if (button.id === 'role-confirm') {
              setTimeout(() => post('role', { role: role() }), 0);
            } else if (button.id === 'prevent-sleep') {
              setTimeout(() => post('preventSleep', { enabled: button.classList.contains('on'), role: role() }), 0);
            } else if (button.matches('[data-app-icon]')) {
              post('icon', { value: button.dataset.appIcon });
            } else if (button.matches('[data-settings]')) {
              event.preventDefault(); event.stopImmediatePropagation(); post('settings', { page: button.dataset.settings });
            }
          }, true);
          window.ThunderDisplayNative = {
            status(message, active) {
              const pill = document.getElementById('connection-pill');
              if (pill) pill.innerHTML = `<i style="background:${active ? 'var(--green)' : 'var(--secondary)'}"></i><span>${message}</span>`;
              const summary = document.querySelector('.stream-summary');
              if (summary) summary.innerHTML = `<b>${message}</b><br>仅雷雳有线`;
              const label = document.getElementById('connect-label');
              if (label) label.textContent = active ? '断开' : '连接';
            },
            toast(message) {
              if (typeof showToast === 'function') showToast(message);
            },
            pairing(address, code) {
              window.__thunderPairing = { address, code };
              const banner = document.getElementById('pairing-banner');
              if (banner) banner.hidden = !address || !code;
              const addressLabel = document.getElementById('pairing-address');
              const codeLabel = document.getElementById('pairing-code');
              if (addressLabel) addressLabel.textContent = address || '等待雷雳网桥';
              if (codeLabel) codeLabel.textContent = code || '切换为显示器后生成';
              renderDetail();
            },
            listening(active) {
              window.__thunderListening = active;
              renderDetail();
            },
            connection(live, roleName, message, peerId) {
              const device = peerId ? devices.find((item) => item.peerId === peerId) : devices.find((item) => item.id === connectedId) || selected();
              if (live && device?.id) { delete metricsByDevice[device.id]; connectedId = device.id; selectedId = device.id; showingLocal = false; device.state = 'online'; device.last = '刚刚'; }
              else if (connectedId) { const active = devices.find((item) => item.id === connectedId); if (active) active.state = 'away'; connectedId = null; }
              persist();
              renderDevices();
              if (message) showToast(message);
            },
            diagnostics(ip, ready, host, model, os, summary, cableDetail) {
              window.__thunderLocal = { name: host, model, os, ip };
              const link = document.getElementById('diag-link');
              const detail = document.getElementById('diag-link-detail');
              const cable = document.getElementById('diag-cable');
              if (link) link.textContent = ready ? 'Thunderbolt Bridge' : '未就绪';
              if (detail) detail.textContent = ready ? `${ip} · ${host}` : '请连接雷雳线并配置雷雳网桥';
              if (cable) cable.textContent = summary || (ready ? '已检测' : '未检测');
              const cableDetailNode = document.getElementById('diag-cable-detail');
              if (cableDetailNode) cableDetailNode.textContent = cableDetail || '点击检测读取系统报告。';
              if (showingLocal) renderDetail();
            },
            upsertDevice(peer) {
              if (!peer || !peer.id) return;
              let device = devices.find((item) => item.peerId === peer.id || (peer.address && item.ip === peer.address));
              if (!device) { device = { id: `device-${peer.id}`, icon: 'monitor-up', state: 'online', last: '刚刚' }; devices.push(device); }
              Object.assign(device, { peerId: peer.id, name: peer.name || device.name || '对端 Mac', model: peer.model || device.model,
                systemVersion: peer.systemVersion || device.systemVersion, ip: peer.address || device.ip || '', pairingCode: peer.code || device.pairingCode || '',
                receiverVersion: peer.version || device.receiverVersion || null, protocolVersion: senderProtocol || device.protocolVersion || null,
                detail: `雷雳桥接 · ${peer.address || device.ip || '地址待发现'} · ${peer.code ? '配对凭据已保存' : '等待首次配对'}` });
              if (!selectedId) selectedId = device.id;
              persist(); renderDevices();
            },
            metrics(stats) {
              if (typeof storeMetrics === 'function') storeMetrics(stats);
            },
            version(version, protocol) {
              senderVersion = version;
              senderProtocol = protocol;
              window.__thunderDisplayVersion = { version, protocol };
              const local = document.getElementById('sidebar-local-version');
              if (local) local.textContent = `本机 v${version}`;
              const build = document.getElementById('modal-local-build');
              const protocolValue = document.getElementById('modal-local-protocol');
              if (build) build.textContent = version;
              if (protocolValue) protocolValue.textContent = protocol;
              renderDetail();
            },
            testResult(ok, width, height, hevc, message) {
              const status = document.getElementById('test-status');
              const button = document.getElementById('run-test');
              const label = document.getElementById('test-button-label');
              const demand = document.getElementById('diag-demand');
              const detail = document.getElementById('diag-demand-detail');
              if (status) status.innerHTML = `<i data-lucide="${ok ? 'circle-check' : 'circle-x'}"></i><span>${message}</span>`;
              if (button) button.disabled = false;
              if (label) label.textContent = '重新检测';
              if (demand && ok) demand.textContent = `${width} × ${height}`;
              if (detail && ok) detail.textContent = `${hevc ? 'HEVC' : 'H.264'} · 屏幕参数握手通过`;
              updateIcons();
            }
          };
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "thunderDisplay", let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        DispatchQueue.main.async { [weak self] in self?.handlePrototypeAction(action, body: body) }
    }

    private func handlePrototypeAction(_ action: String, body: [String: Any]) {
        switch action {
        case "touchBar":
            touchBar.onStatus = { [weak self] payload in
                guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
                self?.webView?.evaluateJavaScript("window.ThunderTouchBar?.receive(\(json));", completionHandler: nil)
            }
            touchBar.handle(body)
        case "device":
            let address = (body["address"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let code = (body["code"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard IPv4Address(address) != nil else { prototypeToast("请输入有效的雷雳 IPv4 地址"); return }
            addressField.stringValue = address
            codeField.stringValue = code
            UserDefaults.standard.set(address, forKey: "receiverAddress")
            UserDefaults.standard.set(code, forKey: "pairingCode.\(address)")
            prototypeToast(code.isEmpty ? "设备已保存；连接前需要配对码" : "设备与配对码已准备")
        case "session":
            let address = body["address"] as? String ?? ""
            let pairingCode = body["code"] as? String ?? ""
            if !address.isEmpty { addressField.stringValue = address }
            if !pairingCode.isEmpty { codeField.stringValue = pairingCode; UserDefaults.standard.set(pairingCode, forKey: "pairingCode.\(address)") }
            if body["role"] as? String == "display" {
                if listener != nil || peer != nil { prototypeToast("接收端已在监听，等待主机输入地址和配对码"); return }
                receive()
                return
            }
            if peer != nil || connecting { endSession("已断开，可以开始新的连接。"); return }
            if address.isEmpty || codeField.stringValue.isEmpty { prototypeToast("请先添加接收端地址和配对码"); return }
            mirrorRequested = body["output"] as? String == "mirror"
            audioRequested = body["audio"] as? Bool ?? true
            remoteSleepRequested = body["preventSleep"] as? Bool ?? true
            guard let mode = TransmissionMode(rawValue: body["transmissionMode"] as? String ?? "") else {
                prototypeToast("请选择有效的传输模式"); return
            }
            transmissionMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "transmissionMode")
            quality.selectedSegment = body["resolution"] as? String == "compatible" ? 1 : 0
            startConnection(probe: false)
        case "preference":
            if let key = body["key"] as? String, ["autoReconnect", "menuBarStatus"].contains(key), let enabled = body["enabled"] as? Bool {
                UserDefaults.standard.set(enabled, forKey: key)
                if key == "menuBarStatus" { statusItem?.isVisible = enabled }
            }
        case "test":
            let address = body["address"] as? String ?? ""
            let pairingCode = body["code"] as? String ?? ""
            if !address.isEmpty { addressField.stringValue = address }
            if !pairingCode.isEmpty { codeField.stringValue = pairingCode }
            _ = ThunderboltInspector.refresh(cable: CableAddress.current())
            prototypeDiagnostics(CableAddress.current())
            startConnection(probe: true)
        case "refresh":
            _ = ThunderboltInspector.refresh(cable: CableAddress.current())
            tick()
            prototypeToast(CableAddress.current() == nil ? "未发现雷雳网桥" : "已读取雷雳网桥和系统链路状态")
        case "role":
            let display = body["role"] as? String == "display"
            if peer != nil || listener != nil || connecting { endSession("正在切换本机角色…") }
            UserDefaults.standard.set(display, forKey: "displayRole")
            if display && listener == nil && peer == nil {
                if stopping { scheduleReconnect() } else { receive() }
            }
            if !display { prototypePairing(address: nil, code: nil) }
        case "preventSleep":
            if body["role"] as? String == "host" {
                remoteSleepRequested = body["enabled"] as? Bool ?? true
            } else {
                UserDefaults.standard.set(body["enabled"] as? Bool ?? true, forKey: "preventDisplaySleep")
                updateSleepActivity()
            }
        case "icon":
            let value = body["value"] as? String == "two" ? "two" : "one"
            UserDefaults.standard.set(value, forKey: "appIcon")
            applyAppIcon()
        case "settings":
            let page = body["page"] as? String ?? ""
            let path: String
            switch page {
            case "privacy": path = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case "displays": path = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
            default: path = "x-apple.systempreferences:com.apple.Network-Settings.extension"
            }
            if let url = URL(string: path) { NSWorkspace.shared.open(url) }
        default: break
        }
    }

    private func prototypeToast(_ message: String) {
        webView?.evaluateJavaScript("window.ThunderDisplayNative?.toast(\(javaScriptString(message)));", completionHandler: nil)
    }

    private func prototypeStatus(_ message: String, active: Bool) {
        webView?.evaluateJavaScript("window.ThunderDisplayNative?.status(\(javaScriptString(message)), \(active));", completionHandler: nil)
    }

    private func prototypePairing(address: String?, code: String?) {
        let addressValue = address ?? ""
        let codeValue = code ?? ""
        webView?.evaluateJavaScript("window.ThunderDisplayNative?.pairing(\(javaScriptString(addressValue)), \(javaScriptString(codeValue)));", completionHandler: nil)
    }

    private func prototypeListening(_ active: Bool) {
        webView?.evaluateJavaScript("window.ThunderDisplayNative?.listening(\(active ? "true" : "false"));", completionHandler: nil)
    }

    private func prototypeConnection(_ live: Bool, message: String? = nil, peerID: String? = nil) {
        let messageValue = message.map(javaScriptString) ?? "null"
        let peerValue = peerID.map(javaScriptString) ?? "null"
        webView?.evaluateJavaScript("window.ThunderDisplayNative?.connection(\(live ? "true" : "false"), \(UserDefaults.standard.bool(forKey: "displayRole") ? "'display'" : "'host'"), \(messageValue), \(peerValue));", completionHandler: nil)
    }

    private func prototypeDiagnostics(_ cable: CableAddress?) {
        let address = cable?.ip ?? ""
        let ready = cable != nil ? "true" : "false"
        let identity = localIdentity
        let report = ThunderboltInspector.report(cable: cable)
        let script = "window.ThunderDisplayNative?.diagnostics(\(javaScriptString(address)), \(ready), \(javaScriptString(identity.name)), \(javaScriptString(identity.model)), \(javaScriptString(identity.systemVersion)), \(javaScriptString(report.summary)), \(javaScriptString(report.detail)));"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private var localIdentity: PeerIdentity {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "deviceIdentity") ?? UUID().uuidString
        defaults.set(id, forKey: "deviceIdentity")
        return PeerIdentity(id: id, name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                            model: hardwareModel(), systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private var localPairingCode: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "localPairingCode"), existing.count == 6 { return existing }
        let created = String(format: "%06d", Int.random(in: 0...999_999))
        defaults.set(created, forKey: "localPairingCode")
        return created
    }

    private func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        guard size > 0, sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: value)
    }

    private func prototypeUpsertDevice(_ identity: PeerIdentity?, address: String?, code: String?, version: String?) {
        guard let identity else { return }
        let payload: [String: String] = ["id": identity.id, "name": identity.name, "model": identity.model,
                                         "systemVersion": identity.systemVersion, "address": address ?? "",
                                         "code": code ?? "", "version": version ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.ThunderDisplayNative?.upsertDevice(\(json));", completionHandler: nil)
    }

    private func prototypeMetrics(_ stats: StreamStatistics) {
        guard let data = try? Wire.json(stats), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.ThunderDisplayNative?.metrics(\(json));", completionHandler: nil)
    }

    private func applyAppIcon() {
        let name = UserDefaults.standard.string(forKey: "appIcon") == "two" ? "IconTwo" : "IconOne"
        if let image = Bundle.main.image(forResource: NSImage.Name(name)) { NSApp.applicationIconImage = image }
    }

    private func prototypeVersion() {
        let script = "window.ThunderDisplayNative?.version(\(javaScriptString(Wire.appVersion)), \(javaScriptString(String(Wire.protocolVersion))));"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private func prototypeTestResult(_ ok: Bool, profile: DisplayProfile?, message: String) {
        let width = profile?.logicalWidth ?? 0
        let height = profile?.logicalHeight ?? 0
        let hevc = profile?.hevc == true ? "true" : "false"
        let script = "window.ThunderDisplayNative?.testResult(\(ok ? "true" : "false"), \(width), \(height), \(hevc), \(javaScriptString(message)));"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private func javaScriptString(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func navigationButton(_ title: String, page: Page) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(navigate(_:)))
        button.bezelStyle = .texturedRounded
        button.alignment = .left
        button.tag = page == .diagnostics ? 1 : 2
        navigation[page] = button
        return button
    }

    private func card(_ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16)
        ])
        return box
    }

    private func buildConnectionPage() -> NSView {
        let page = NSStackView()
        page.orientation = .vertical; page.alignment = .leading; page.spacing = 16
        page.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 30, right: 30)
        let hero = NSStackView(); hero.orientation = .vertical; hero.alignment = .leading; hero.spacing = 12
        let title = NSTextField(labelWithString: "远端 Mac")
        title.font = .systemFont(ofSize: 22, weight: .bold); hero.addArrangedSubview(title)
        cableLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular); cableLabel.textColor = .secondaryLabelColor; hero.addArrangedSubview(cableLabel)
        connectionStateLabel.font = .systemFont(ofSize: 12, weight: .semibold); connectionStateLabel.textColor = .systemGreen; hero.addArrangedSubview(connectionStateLabel)
        let identity = NSStackView(); identity.orientation = .horizontal; identity.distribution = .fillEqually; identity.spacing = 18
        identity.addArrangedSubview(identityFact("设备名称", "远端 Mac")); identity.addArrangedSubview(identityFact("设备型号", "型号未发现")); identity.addArrangedSubview(identityFact("系统版本", "系统版本未发现")); hero.addArrangedSubview(identity)
        roleControl = NSSegmentedControl(labels: ["主机", "显示器"], trackingMode: .selectOne, target: self, action: #selector(roleChanged(_:)))
        roleControl.selectedSegment = UserDefaults.standard.bool(forKey: "displayRole") ? 1 : 0
        roleControl.setAccessibilityLabel("本机角色")
        let roleRow = NSStackView(views: [roleLabel, roleControl]); roleRow.spacing = 18; roleRow.alignment = .centerY; hero.addArrangedSubview(roleRow)

        senderControls = buildSenderControls()
        receiverControls = buildReceiverControls()
        hero.addArrangedSubview(senderControls); hero.addArrangedSubview(receiverControls)
        statusLabel.isSelectable = true; statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor; statusLabel.maximumNumberOfLines = 3; hero.addArrangedSubview(statusLabel)
        metricsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); metricsLabel.textColor = .secondaryLabelColor; hero.addArrangedSubview(metricsLabel)
        stopButton = NSButton(title: "断开", target: self, action: #selector(disconnect)); stopButton.bezelStyle = .texturedRounded; stopButton.isEnabled = false; hero.addArrangedSubview(stopButton)
        let box = card(hero); box.translatesAutoresizingMaskIntoConstraints = false; page.addArrangedSubview(box); box.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -60).isActive = true
        let setup = NSTextField(labelWithString: "配置引导\n1. 两台 Mac 的系统设置 → 网络 → 雷雳网桥应显示地址。\n2. 显示器端先点击“作为显示器”，主机端再输入地址与配对码。\n3. 首次扩展需要在发送端允许屏幕录制。")
        setup.font = .systemFont(ofSize: 12); setup.textColor = .secondaryLabelColor; setup.maximumNumberOfLines = 5
        let setupBox = card(setup); setupBox.translatesAutoresizingMaskIntoConstraints = false; page.addArrangedSubview(setupBox); setupBox.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -60).isActive = true
        return page
    }

    private func identityFact(_ name: String, _ value: String) -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 4
        let label = NSTextField(labelWithString: name); label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .secondaryLabelColor
        let valueLabel = NSTextField(labelWithString: value); valueLabel.font = .systemFont(ofSize: 12, weight: .medium); valueLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(label); stack.addArrangedSubview(valueLabel); return stack
    }

    private func buildSenderControls() -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        let label = NSTextField(labelWithString: "主机输出"); label.font = .systemFont(ofSize: 12, weight: .semibold); stack.addArrangedSubview(label)
        let fields = NSStackView(views: [addressField, codeField]); fields.spacing = 8
        addressField.placeholderString = "接收端雷雳地址"; addressField.stringValue = UserDefaults.standard.string(forKey: "receiverAddress") ?? ""; addressField.setAccessibilityLabel("接收端雷雳地址")
        codeField.placeholderString = "6 位配对码"; codeField.setAccessibilityLabel("接收端配对码")
        addressField.widthAnchor.constraint(equalToConstant: 250).isActive = true; codeField.widthAnchor.constraint(equalToConstant: 125).isActive = true; stack.addArrangedSubview(fields)
        quality.selectedSegment = UserDefaults.standard.integer(forKey: "quality"); quality.setAccessibilityLabel("画质"); quality.segmentStyle = .rounded; stack.addArrangedSubview(quality)
        sendButton = NSButton(title: "扩展到远端 Mac", target: self, action: #selector(sendDisplay)); sendButton.bezelStyle = .rounded; stack.addArrangedSubview(sendButton)
        return stack
    }

    private func buildReceiverControls() -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        let label = NSTextField(labelWithString: "显示器接收"); label.font = .systemFont(ofSize: 12, weight: .semibold); stack.addArrangedSubview(label)
        pairingLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium); pairingLabel.isSelectable = true; stack.addArrangedSubview(pairingLabel)
        displaySleepButton = NSButton(checkboxWithTitle: "防止显示器息屏", target: self, action: #selector(togglePreventSleep(_:)))
        displaySleepButton.state = UserDefaults.standard.bool(forKey: "preventDisplaySleep") ? .on : .off; stack.addArrangedSubview(displaySleepButton)
        receiveButton = NSButton(title: "作为显示器等待连接", target: self, action: #selector(receive)); receiveButton.bezelStyle = .rounded; stack.addArrangedSubview(receiveButton)
        return stack
    }

    private func buildDiagnosticsPage() -> NSView {
        let page = NSStackView(); page.orientation = .vertical; page.alignment = .leading; page.spacing = 16; page.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 30, right: 30)
        let title = NSTextField(labelWithString: "配置检查"); title.font = .systemFont(ofSize: 26, weight: .bold); page.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "验证雷雳网桥路径、协议握手和当前图传状态。"); subtitle.textColor = .secondaryLabelColor; page.addArrangedSubview(subtitle)
        diagnosticCableLabel.font = .systemFont(ofSize: 13, weight: .medium); diagnosticStatusLabel.font = .systemFont(ofSize: 13); diagnosticStatusLabel.textColor = .secondaryLabelColor
        let info = NSStackView(views: [diagnosticCableLabel, diagnosticStatusLabel]); info.orientation = .vertical; info.alignment = .leading; info.spacing = 9
        let box = card(info); box.translatesAutoresizingMaskIntoConstraints = false; page.addArrangedSubview(box); box.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -60).isActive = true
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
        let network = NSButton(title: "打开网络设置", target: self, action: #selector(openNetworkSettings)); network.bezelStyle = .texturedRounded
        let copy = NSButton(title: "拷贝诊断", target: self, action: #selector(copyDiagnostics)); copy.bezelStyle = .texturedRounded
        actions.addArrangedSubview(network); actions.addArrangedSubview(copy); page.addArrangedSubview(actions)
        return page
    }

    private func buildSettingsPage() -> NSView {
        let page = NSStackView(); page.orientation = .vertical; page.alignment = .leading; page.spacing = 16; page.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 30, right: 30)
        let title = NSTextField(labelWithString: "偏好设置"); title.font = .systemFont(ofSize: 26, weight: .bold); page.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "连接选项保留在设备页；这里仅放全局行为。"); subtitle.textColor = .secondaryLabelColor; page.addArrangedSubview(subtitle)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 11
        for (title, key, value) in [("唤醒后自动重连", "autoReconnect", true), ("显示菜单栏状态", "menuBarStatus", true), ("连接前检查配置", "preflight", true)] {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleSetting(_:))); button.identifier = NSUserInterfaceItemIdentifier(key); button.state = UserDefaults.standard.object(forKey: key) == nil ? (value ? .on : .off) : (UserDefaults.standard.bool(forKey: key) ? .on : .off); stack.addArrangedSubview(button)
        }
        let box = card(stack); box.translatesAutoresizingMaskIntoConstraints = false; page.addArrangedSubview(box); box.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -60).isActive = true
        let reset = NSButton(title: "恢复默认设置", target: self, action: #selector(resetSettings)); reset.bezelStyle = .texturedRounded; page.addArrangedSubview(reset)
        return page
    }

    private func setBusy(_ busy: Bool) {
        webView?.evaluateJavaScript("window.__transmissionBusy = \(busy ? "true" : "false"); if (typeof renderDetail === 'function') renderDetail();", completionHandler: nil)
        sendButton?.isEnabled = !busy
        testButton?.isEnabled = !busy
        receiveButton?.isEnabled = !busy
        addressField.isEnabled = !busy
        codeField.isEnabled = !busy
        quality.isEnabled = !busy
        stopButton?.isEnabled = busy && !stopping
        roleControl?.isEnabled = !busy
        mainActionButton?.isEnabled = !busy
        updateRoleUI()
    }

    private func showPage(_ page: Page) {
        for item in Page.allCases { pages[item]?.isHidden = item != page }
        for item in Page.allCases { navigation[item]?.state = item == page ? .on : .off }
        toolbarTitle.stringValue = page == .connection ? (roleControl.selectedSegment == 0 ? "主机 · 远端 Mac" : "显示器 · 远端 Mac") : (page == .diagnostics ? "配置检查" : "偏好设置")
    }

    private func updateRoleUI() {
        guard roleControl != nil else { return }
        let host = roleControl.selectedSegment == 0
        roleLabel.stringValue = host ? "本机作为主机" : "本机作为显示器"
        senderControls?.isHidden = !host
        receiverControls?.isHidden = host
        mainActionButton?.title = host ? "扩展到远端 Mac" : "等待主机连接"
        mainActionButton?.action = host ? #selector(sendDisplay) : #selector(receive)
        toolbarTitle?.stringValue = host ? "主机 · 远端 Mac" : "显示器 · 远端 Mac"
    }

    @objc private func navigate(_ sender: NSButton) { showPage(sender.tag == 1 ? .diagnostics : .settings) }
    @objc private func showConnectionPage() { showPage(.connection) }
    @objc private func refreshCable() {
        tick()
        diagnosticCableLabel.stringValue = CableAddress.current().map { "雷雳网桥  \($0.ip) · \($0.name) · 已就绪" } ?? "雷雳网桥未就绪"
        record("已刷新设备发现与本地雷雳接口")
    }
    @objc private func roleChanged(_ sender: NSSegmentedControl) {
        let active = peer != nil || listener != nil || connecting
        let requestedDisplay = sender.selectedSegment == 1
        if active {
            let alert = NSAlert()
            alert.messageText = "切换本机角色？"
            alert.informativeText = "切换角色会停止当前显示会话。确认后才会应用新角色。"
            alert.addButton(withTitle: "切换角色")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn {
                sender.selectedSegment = requestedDisplay ? 0 : 1
                return
            }
            endSession("正在切换本机角色…")
        }
        UserDefaults.standard.set(requestedDisplay, forKey: "displayRole")
        updateRoleUI()
    }
    @objc private func togglePreventSleep(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "preventDisplaySleep")
        updateSleepActivity()
    }
    @objc private func toggleSetting(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }
    @objc private func resetSettings() {
        for key in ["autoReconnect", "menuBarStatus", "preflight"] { UserDefaults.standard.set(true, forKey: key) }
        showPage(.settings)
        record("偏好设置已恢复默认")
    }
    private func updateSleepActivity() {
        let enabled = UserDefaults.standard.object(forKey: "preventDisplaySleep") == nil || UserDefaults.standard.bool(forKey: "preventDisplaySleep")
        if enabled && receiverKeepAwake && videoWindow != nil && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .automaticTerminationDisabled], reason: "WiredDisplay display session")
        } else if (!enabled || !receiverKeepAwake || videoWindow == nil), let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
    @objc private func receive() {
        guard !systemSleeping, !stopping, listener == nil else { return }
        guard let cable = CableAddress.current() else { statusLabel.stringValue = "未找到雷雳网络地址。请连接两台 Mac，并检查系统设置 → 网络 → 雷雳网桥。"; return }
        do {
            let listener = try CableListener(cable: cable)
            code = localPairingCode
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
            prototypeListening(true)
            pairingLabel.stringValue = "地址 \(cable.ip)    配对码 \(code)"
            prototypePairing(address: cable.ip, code: code)
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
        let hiDPI = screen.backingScaleFactor > 1
        // Catalog dimensions describe built-in physical panels, not external monitors
        // or supersampled display modes. Unknown panels retain runtime geometry.
        let catalog = Bundle.main.url(forResource: "apple-thunderbolt-display-catalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(PanelCatalog.self, from: $0) }
        let pixels = catalog?.nativePixels(model: localIdentity.model, builtIn: CGDisplayIsBuiltin(id) != 0)
        var result = DisplayProfile(width: pixels?.width ?? width, height: pixels?.height ?? height, hiDPI: hiDPI,
                              hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                              appVersion: Wire.appVersion, identity: localIdentity, receiverCode: localPairingCode)
        result.wideGamut = screen.colorSpace?.cgColorSpace?.isWideGamutRGB ?? false
        return result
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
        session.decoder.onFailure = { [weak accepted] reason in
            accepted?.send(.end, Data(reason.utf8)) { accepted?.stop() }
        }
        accepted.onPacket = { [weak self, weak accepted] kind, data in
            guard let self, let accepted else { return }
            self.receiveLock.lock(); session.lastSeen = DispatchTime.now().uptimeNanoseconds; self.receiveLock.unlock()
            if !session.authenticated {
                do {
                    guard kind == .hello else { throw WireError.invalid("请先配对") }
                    let hello = try Wire.decode(Hello.self, data)
                    try Wire.validateProtocol(hello.version)
                    guard hello.code == code else { throw WireError.invalid("配对码不正确") }
                    try profile.validate()
                    DispatchQueue.main.async {
                        self.prototypeUpsertDevice(hello.identity, address: hello.address,
                                                   code: hello.receiverCode, version: hello.appVersion)
                    }
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
                        self.clearVideoPresentation()
                        self.surface.onSubmit = { [weak accepted] sequence in
                            var data = Data(); Wire.append(sequence, to: &data)
                            accepted?.send(.acknowledgment, data)
                        }
                        self.surface.onFirstImage = { [weak self, weak accepted] in
                            guard let self, let accepted, self.sessionID == generation, self.peer === accepted else { return }
                            self.showVideo()
                        }
                        self.record("配对通过 · 发射端 \(hello.appVersion ?? "未知") · 等待视频配置")
                        self.receiverKeepAwake = hello.preventDisplaySleep ?? true
                        self.prototypeConnection(true, message: "已配对，等待视频", peerID: hello.identity?.id)
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
                do { try session.decoder.configure(config) }
                catch {
                    accepted.send(.end, Data(error.localizedDescription.utf8)) { accepted.stop() }
                    return
                }
                session.configured = true
            case .video:
                guard session.configured else { throw WireError.invalid("未配置解码器") }
                let sequence = try Wire.integer(data, at: 0, as: UInt64.self)
                guard sequence > session.lastSequence, sequence <= UInt64(Int64.max) else { throw WireError.invalid("视频序号错误") }
                session.lastSequence = sequence
                try session.decoder.decode(data)
            case .cursor:
                // Cursor delivery is best-effort. It must never tear down video.
                guard session.configured,
                      let pointer = try? Wire.decode(PointerUpdate.self, data),
                      (try? pointer.validate()) != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionID == generation, self.peer === accepted else { return }
                    self.surface.setPointer(pointer)
                }
            case .statistics:
                let stats = try Wire.decode(StreamStatistics.self, data)
                DispatchQueue.main.async { [weak self] in self?.prototypeMetrics(stats) }
            case .audioConfiguration:
                if let config = try? Wire.decode(AudioConfiguration.self, data) { try? session.audio.configure(config) }
            case .audio:
                session.audio.enqueue(data)
            case .heartbeat: accepted.send(.heartbeat)
            case .end: accepted.stop()
            default: throw WireError.invalid("接收端收到不支持的消息")
            }
        }
        accepted.onClose = { [weak self, weak accepted] reason in
            session.decoder.stop()
            session.audio.stop()
            DispatchQueue.main.async {
                guard let self, let accepted, self.sessionID == generation else { return }
                self.candidates.removeValue(forKey: ObjectIdentifier(accepted))
                guard self.peer === accepted else {
                    if self.peer == nil { self.record("\(reason) · 监听中 · TCP \(Wire.port)") }
                    return
                }
                self.peer = nil
                self.receiveLock.lock(); self.receiveSession = nil; self.receiveLock.unlock()
                self.clearVideoPresentation()
                self.prototypeConnection(false)
                self.metricsLabel.stringValue = ""
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
        video.title = "Thunder Display · Esc 返回"
        video.isReleasedWhenClosed = false
        video.collectionBehavior = [.fullScreenPrimary]
        video.delegate = self
        video.contentView = surface
        videoWindow = video
        video.makeKeyAndOrderFront(nil)
        video.toggleFullScreen(nil)
        NSCursor.hide()
        receiverCursorHidden = true
        updateSleepActivity()
        statusLabel.stringValue = "已连接 · 仅雷雳有线"
    }

    @objc private func sendDisplay() { startConnection(probe: false) }
    @objc private func testConnection() { startConnection(probe: true) }

    private func startConnection(probe: Bool) {
        guard !systemSleeping, !stopping, !connecting, peer == nil else { return }
        guard #available(macOS 14.0, *) else { if probe { prototypeTestResult(false, profile: nil, message: "当前 macOS 不支持发送端虚拟显示器。") }; statusLabel.stringValue = "发送扩展屏需要 macOS 14 或更新。"; return }
        guard let cable = CableAddress.current() else { if probe { prototypeTestResult(false, profile: nil, message: "未发现雷雳网桥，请先连接雷雳线并配置网络。") }; statusLabel.stringValue = "请连接雷雳线，并等待雷雳网桥获得地址。"; return }
        let ip = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { if probe { prototypeTestResult(false, profile: nil, message: "缺少接收端 6 位配对码，无法开始检测。") }; statusLabel.stringValue = "请输入接收端显示的 6 位配对码。"; return }
        UserDefaults.standard.set(ip, forKey: "receiverAddress")
        UserDefaults.standard.set(quality.selectedSegment, forKey: "quality")
        sessionID = UUID()
        let generation = sessionID
        let limited = quality.selectedSegment == 1
        let transmissionMode = self.transmissionMode
        connecting = true
        setBusy(true)
        diagnosticLines.removeAll()
        record("Thunder Display \(Wire.appVersion) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        record("本机 \(cable.description) → \(ip):\(Wire.port)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let peer = try CablePeer.connect(ip: ip, cable: cable)
                DispatchQueue.main.async { [peer] in
                    guard let self, self.sessionID == generation else { peer.stop(); return }
                    self.connecting = false
                    self.peer = peer
                    self.firstFrameAcknowledged = false
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
                                let mode = "\(profile.logicalWidth) × \(profile.logicalHeight)"
                                let backing = profile.hiDPI ? " · Retina 视频 \(profile.width) × \(profile.height)" : ""
                                self.record("配对通过 · 显示模式 \(mode)\(backing) · 接收端 \(profile.appVersion ?? "未知")")
                                self.prototypeUpsertDevice(profile.identity, address: ip, code: profile.receiverCode,
                                                           version: profile.appVersion)
                                if probe {
                                    self.prototypeTestResult(true, profile: profile, message: "检测成功：雷雳 TCP、配对码和屏幕参数交换均已通过。")
                                    self.endSession("测试成功：雷雳 TCP、配对与屏幕参数交换均已通过。"); return
                                }
                                self.prototypeConnection(true, message: "已连接，正在启动桌面采集", peerID: profile.identity?.id)
                                guard CGPreflightScreenCaptureAccess() else {
                                    CGRequestScreenCaptureAccess()
                                    self.endSession("网络连接已验证。请允许屏幕录制后重新连接。")
                                    return
                                }
                                let selected = profile.limited(to4K: limited)
                                if limited { self.record("已选择 4K 兼容档 · 文字清晰度会低于原生 Retina 档") }
                                let sender = ScreenSender(peer: connection)
                                self.sender = sender
                                sender.onFailure = { [weak self] message in
                                    DispatchQueue.main.async {
                                        guard let self, self.sessionID == generation else { return }
                                        self.endSession(message)
                                    }
                                }
                                sender.onStatus = { [weak self] message in
                                    DispatchQueue.main.async {
                                        guard let self, self.sessionID == generation else { return }
                                        self.record("发送端：\(message)")
                                    }
                                }
                                sender.onStats = { [weak self] stats in
                                    DispatchQueue.main.async {
                                        guard let self, self.sessionID == generation else { return }
                                        self.metricsLabel.stringValue = String(format: "%.0f 帧/秒 · 确认往返 %.0f ms", stats.fps, stats.roundTripMilliseconds)
                                        self.prototypeMetrics(stats)
                                    }
                                }
                                do {
                                    self.record("传输模式：\(transmissionMode.rawValue) · \(selected.width) × \(selected.height) · 面板色域：\(selected.wideGamut ? "广色域" : "标准色域")")
                                    try await sender.start(profile: selected, mirror: self.mirrorRequested, audio: self.audioRequested, mode: transmissionMode)
                                    guard self.sessionID == generation else { await sender.stop(); return }
                                    self.statusLabel.stringValue = "已扩展 · \(selected.logicalWidth) × \(selected.logicalHeight)\(selected.hiDPI ? " Retina" : "") · 60 帧目标\n在系统设置 → 显示器中调整屏幕排列。"
                                } catch {
                                    if self.sessionID == generation {
                                        self.record("发送端视频启动失败：\(error.localizedDescription)")
                                        self.endSession("发送端视频启动失败：\(error.localizedDescription)")
                                    }
                                }
                            }
                        case .acknowledgment:
                            DispatchQueue.main.async {
                                guard self.sessionID == generation else { return }
                                guard let sender = self.sender as? ScreenSender else { return }
                                sender.acknowledge(data)
                                guard !self.firstFrameAcknowledged else { return }
                                self.firstFrameAcknowledged = true
                                self.reconnectAttempt = false
                                self.record("首帧已确认 · 系统光标随画面同步")
                            }
                        case .statistics:
                            let stats = try Wire.decode(StreamStatistics.self, data)
                            DispatchQueue.main.async { [weak self] in self?.prototypeMetrics(stats) }
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
                            if probe { self.prototypeTestResult(false, profile: nil, message: detail) }
                            self.connectionFailed(detail)
                        }
                    }
                    peer.onState = { [weak self] message in
                        DispatchQueue.main.async {
                            guard let self, self.sessionID == generation else { return }
                            self.record(message)
                        }
                    }
                    peer.onReady = { [weak peer] in
                        let hello = Hello(version: Wire.protocolVersion, code: code, probe: probe,
                                          identity: self.localIdentity, address: cable.ip,
                                          receiverCode: self.localPairingCode,
                                          preventDisplaySleep: self.remoteSleepRequested)
                        peer?.send(.hello, (try? Wire.json(hello)) ?? Data())
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
                    if probe { self.prototypeTestResult(false, profile: nil, message: error.localizedDescription) }
                    self.connectionFailed(error.localizedDescription)
                }
            }
        }
    }

    private func tick() {
        defer { updateStatusMenu() }
        guard !systemSleeping else { return }
        let cable = CableAddress.current()
        if pendingReconnect && !stopping {
            if Date() > reconnectDeadline {
                pendingReconnect = false
                record("重连等待超时，请检查雷雳连接后从菜单栏重试。")
            } else if cable != nil {
                pendingReconnect = false
                if UserDefaults.standard.bool(forKey: "displayRole") { receive() }
                else {
                    reconnectAttempt = true
                    startConnection(probe: false)
                }
            }
        }
        prototypeVersion()
        cableLabel.stringValue = cable.map { "雷雳网桥  \($0.ip) · \($0.name)" } ?? "雷雳网桥  未就绪"
        diagnosticCableLabel.stringValue = CableAddress.current().map { "雷雳网桥  \($0.ip) · \($0.name) · 已就绪" } ?? "雷雳网桥未就绪"
        prototypeDiagnostics(cable)
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
        pendingReconnect = false
        reconnectAttempt = false
        guard !stopping else { return }
        stopping = true
        sessionID = UUID()
        connecting = false
        transportReady = false
        receiverKeepAwake = true
        firstFrameAcknowledged = false
        if receiverCursorHidden { NSCursor.unhide(); receiverCursorHidden = false }
        listener?.stop(); listener = nil
        for candidate in candidates.values { candidate.stop() }
        candidates.removeAll()
        peer?.stop(); peer = nil
        receiveLock.lock(); receiveSession = nil; receiveLock.unlock()
        clearVideoPresentation()
        pairingLabel.stringValue = ""
        prototypeConnection(false)
        prototypeListening(false)
        if listener == nil { prototypePairing(address: nil, code: nil) }
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
        connectionStateLabel.stringValue = message
        diagnosticStatusLabel.stringValue = message
        prototypeStatus(message, active: peer != nil || listener != nil || connecting)
        updateStatusMenu()
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
        alert.messageText = "Thunder Display \(Wire.appVersion)"
        alert.informativeText = "仅雷雳有线扩展屏。采用 macOS 原生采集、硬件编解码与原生画面显示。\n\n部分虚拟屏与消息封装思路来自 TargetBridge（MIT，Marco Caciotti）。独立实现，不与 Duet 私有协议互通。"
        alert.runModal()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === videoWindow { endSession("显示已停止。"); return false }
        sender.miniaturize(nil)
        return false
    }
    func applicationWillTerminate(_ notification: Notification) { touchBar.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if self.sender == nil && !stopping { listener?.stop(); peer?.stop(); return .terminateNow }
        quitting = true
        if !stopping { endSession("正在停止…") }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
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
