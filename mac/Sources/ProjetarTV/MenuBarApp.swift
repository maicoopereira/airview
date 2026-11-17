import AppKit
import CryptoKit
import ServiceManagement

/// Abre o AirView como app de barra de menus (sem ícone no Dock).
func runMenuBarApp() -> Never {
    // Sem terminal: o que o app imprime vai para ~/Library/Logs/AirView.log (abre no app Console).
    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AirView.log").path
    freopen(log, "a", stdout)
    freopen(log, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    print("--- AirView iniciado \(Date()) — Gravação de Tela: \(CGPreflightScreenCaptureAccess() ? "liberada" : "NÃO liberada")")
    let app = NSApplication.shared
    let controller = MenuBarController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { app.run() }
    exit(0)
}

/// Ícone de TV na barra superior: escolher a TV da rede, estender/espelhar, som na TV/no Mac e desconectar.
/// O servidor só fica ligado entre escolher uma TV e Desconectar.
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let port: UInt16 = 7070
    private let macName = Host.current().localizedName ?? "Mac"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let browser = TVBrowser()

    private var server: StreamServer?
    private var session: TVSession?
    private var currentTV: DiscoveredTV?
    private var problem: String?

    private var isConnected: Bool { session?.isActive ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DeviceAudioCapture.setDeviceVisible(false)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false // os itens seguem o estado da conexão, definido em menuNeedsUpdate
        statusItem.menu = menu
        browser.onChange = { [weak self] in
            guard let self else { return }
            print("TVs na rede: \(self.browser.tvs.map(\.name)) \(self.browser.problem ?? "")")
            self.refresh()
        }
        browser.start()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tv = currentTV, let key = PairingStore.key(forTV: tv.name) { TVControl.disconnect(tv, key: key) }
        session?.shutdown()
        server?.stop()
    }

    // MARK: - Ações

    @objc private func chooseTV(_ sender: NSMenuItem) {
        guard let tv = sender.representedObject as? DiscoveredTVBox else { return }
        if currentTV == tv.value && (isConnected || server != nil) { return }
        if currentTV != nil {
            disconnect { self.connect(to: tv.value) }
        } else {
            connect(to: tv.value)
        }
    }

    private func connect(to tv: DiscoveredTV) {
        print("Conectando a \(tv.name)")
        problem = nil
        guard let key = PairingStore.key(forTV: tv.name) else {
            return pair(with: tv) { self.connect(to: tv) }
        }
        let sessionKey = SymmetricKey(size: .bits256)
        do {
            try startServer(sessionKey: sessionKey)
        } catch {
            problem = "Não consegui ligar o servidor: \(error.localizedDescription)"
            refresh()
            return
        }
        currentTV = tv
        refresh()
        // A TV abre a projeção e conecta neste Mac (no endereço de quem mandou o comando), provando que recebeu
        // a chave da sessão.
        TVControl.connect(tv, key: key, port: port, macName: macName, sessionKey: sessionKey) { result in
            guard case .failure(let error) = result, self.currentTV == tv, !self.isConnected else { return }
            if error == .notPaired { PairingStore.forget(tv: tv.name) }
            self.problem = "\(tv.name): \(error.localizedDescription)"
            print(self.problem!)
            self.disconnect()
        }
    }

    /// Primeiro uso com uma TV: mostra o código que a TV também mostra e espera o OK no controle.
    private func pair(with tv: DiscoveredTV, then next: @escaping () -> Void) {
        let panel = PairingPanel(tvName: tv.name)
        panel.show()
        TVControl.pair(tv, macName: macName, showCode: { panel.show(code: $0) }) { result in
            panel.close()
            switch result {
            case .success(let key):
                PairingStore.save(key, forTV: tv.name)
                print("Pareado com \(tv.name)")
                next()
            case .failure(let error):
                self.problem = "Pareamento com \(tv.name) não concluído: \(error.localizedDescription)"
                print(self.problem!)
                self.refresh()
            }
        }
    }

    @objc private func forgetPairings(_ sender: Any?) {
        disconnect()
        PairingStore.forgetAll()
        problem = nil
        refresh()
    }

    @objc private func disconnectAction(_ sender: Any?) {
        disconnect()
    }

    /// Fecha a projeção na TV, remove monitor e saída de som e desliga o servidor.
    private func disconnect(then next: (() -> Void)? = nil) {
        if let tv = currentTV, let key = PairingStore.key(forTV: tv.name) { TVControl.disconnect(tv, key: key) }
        currentTV = nil
        let finish = {
            self.server?.stop()
            self.server = nil
            self.session = nil
            self.refresh()
            next?()
        }
        if let session { session.disconnectNow(completion: finish) } else { finish() }
    }

    @objc private func extend(_ sender: Any?) { session?.setMirrored(false) }
    @objc private func mirror(_ sender: Any?) { session?.setMirrored(true) }
    @objc private func audioOnTV(_ sender: Any?) { session?.setAudioOnTV(true) }
    @objc private func audioOnMac(_ sender: Any?) { session?.setAudioOnTV(false) }

    @objc private func toggleLoginItem(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            problem = "Não consegui mudar o início automático: \(error.localizedDescription)"
        }
        refresh()
    }

    @objc private func openDisplaySettings(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func quit(_ sender: Any?) {
        disconnect { NSApp.terminate(nil) }
    }

    private func startServer(sessionKey: SymmetricKey) throws {
        server?.stop()
        let server = try StreamServer(port: port, serviceName: macName, sessionKey: sessionKey)
        let session = TVSession(server: server, fps: 60, bitrate: 15_000_000, maxWidth: 1920, maxHeight: 1080, audio: true)
        server.onClientsChanged = { count in
            DispatchQueue.main.async { session.clientsChanged(count) }
        }
        server.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.problem = message
                self?.disconnect()
            }
        }
        session.onChange = { [weak self] in self?.refresh() }
        self.server = server
        self.session = session
    }

    // MARK: - Menu

    private func refresh() {
        let symbol = isConnected ? "tv.fill" : "tv"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AirView")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = statusText
    }

    private var statusText: String {
        if let tv = currentTV {
            return isConnected ? "Conectado a \(tv.name)" : "Conectando a \(tv.name)…"
        }
        return "Desconectado"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(.sectionHeader(title: "AirView"))
        menu.addItem(disabled(statusText))
        if let message = problem ?? session?.problem ?? browser.problem {
            let item = disabled(message)
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "TVs na rede"))
        if browser.tvs.isEmpty {
            menu.addItem(disabled("Procurando TVs…"))
        }
        for tv in browser.tvs {
            let item = NSMenuItem(title: tv.name, action: #selector(chooseTV(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DiscoveredTVBox(tv)
            item.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
            item.state = currentTV == tv ? .on : .off
            menu.addItem(item)
        }

        let active = isConnected
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Vídeo"))
        let mirrored = session?.isMirrored ?? false
        menu.addItem(option("Estender a tela", symbol: "rectangle.on.rectangle", on: active && !mirrored,
                            enabled: active, action: #selector(extend(_:))))
        menu.addItem(option("Espelhar a tela", symbol: "rectangle.on.rectangle.angled", on: active && mirrored,
                            enabled: active, action: #selector(mirror(_:))))
        menu.addItem(.sectionHeader(title: "Som"))
        let hasAudio = session?.hasAudio ?? false
        let onTV = session?.audioOnTV ?? false
        menu.addItem(option("Na TV", symbol: "hifispeaker", on: hasAudio && onTV,
                            enabled: hasAudio, action: #selector(audioOnTV(_:))))
        menu.addItem(option("No Mac", symbol: "laptopcomputer", on: hasAudio && !onTV,
                            enabled: hasAudio, action: #selector(audioOnMac(_:))))

        menu.addItem(.separator())
        let disconnectItem = NSMenuItem(title: "Desconectar", action: #selector(disconnectAction(_:)), keyEquivalent: "d")
        disconnectItem.target = self
        disconnectItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        disconnectItem.isEnabled = currentTV != nil || server != nil
        menu.addItem(disconnectItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Ajustes de Monitores…", action: #selector(openDisplaySettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let forget = NSMenuItem(title: "Esquecer TVs pareadas", action: #selector(forgetPairings(_:)), keyEquivalent: "")
        forget.target = self
        menu.addItem(forget)
        let login = NSMenuItem(title: "Abrir ao iniciar sessão", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Sair do AirView", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func option(_ title: String, symbol: String, on: Bool, enabled: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.state = on ? .on : .off
        item.isEnabled = enabled
        return item
    }
}

/// NSMenuItem.representedObject precisa de um objeto.
private final class DiscoveredTVBox {
    let value: DiscoveredTV
    init(_ value: DiscoveredTV) { self.value = value }
}

/// Janela pequena do pareamento: mostra o código que deve aparecer igual na TV.
private final class PairingPanel {
    private let panel: NSPanel
    private let codeLabel = NSTextField(labelWithString: "· · ·")
    private let hint: NSTextField

    init(tvName: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 190),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.title = "Parear com \(tvName)"
        panel.isFloatingPanel = true
        panel.level = .floating

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        panel.contentView = effect

        codeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        codeLabel.alignment = .center
        hint = NSTextField(wrappingLabelWithString: "Confira se a TV mostra o mesmo código e aperte OK no controle.")
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [codeLabel, hint])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor, constant: 10),
            stack.widthAnchor.constraint(equalToConstant: 290),
        ])
    }

    func show(code: String? = nil) {
        if let code { codeLabel.stringValue = code }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.close() }
}
