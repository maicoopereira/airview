import Foundation

/// Liga o monitor "AirView" e a saída de som "AirView" só enquanto há uma TV conectada, como o AirPlay.
/// Quedas curtas do Wi-Fi não desmontam nada: espera alguns segundos antes de desligar.
final class TVSession {
    private let server: StreamServer
    private let fps: Int
    private let bitrate: Int
    private let maxWidth: Int
    private let maxHeight: Int
    private let audio: Bool

    private var display: VirtualDisplay?
    private var video: VideoPipeline?
    private var audioCapture: DeviceAudioCapture?
    private var pendingTeardown: DispatchWorkItem?
    private var busy = false
    private var clients = 0

    private static let disconnectGrace: TimeInterval = 5

    /// Avisa a interface (barra de menus) que algo mudou: conectou, desconectou, som ou vídeo trocados.
    var onChange: (() -> Void)?
    /// Último problema a mostrar para o usuário (permissão, driver ausente…).
    private(set) var problem: String?

    var isActive: Bool { display != nil }
    var isMirrored: Bool { display?.isMirrored ?? false }
    var audioOnTV: Bool { audioCapture?.isDefaultOutput ?? false }
    var hasAudio: Bool { audioCapture != nil }

    /// Estender (false) ou espelhar (true) a tela do Mac na TV.
    func setMirrored(_ mirrored: Bool) {
        display?.setMirrored(mirrored)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.onChange?() }
    }

    /// Som na TV (saída "AirView") ou de volta na saída anterior do Mac.
    func setAudioOnTV(_ onTV: Bool) {
        if onTV { audioCapture?.makeDefaultOutput() } else { audioCapture?.restoreMacOutput() }
        onChange?()
    }

    /// Desconecta agora (botão Desconectar), sem a espera de queda de Wi-Fi.
    func disconnectNow(completion: @escaping () -> Void) {
        pendingTeardown?.cancel()
        pendingTeardown = nil
        clients = 0
        guard display != nil, !busy else { completion(); return }
        disconnect(completion: completion)
    }

    private func report(_ message: String) {
        print(message)
        problem = message
        onChange?()
    }

    init(server: StreamServer, fps: Int, bitrate: Int, maxWidth: Int, maxHeight: Int, audio: Bool) {
        self.server = server
        self.fps = fps
        self.bitrate = bitrate
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.audio = audio
        DeviceAudioCapture.setDeviceVisible(false)
    }

    /// Chamado na fila principal sempre que o número de TVs conectadas muda.
    func clientsChanged(_ count: Int) {
        clients = count
        if count > 0 {
            pendingTeardown?.cancel()
            pendingTeardown = nil
            if display == nil { connect() }
        } else if display != nil, pendingTeardown == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingTeardown = nil
                if self?.clients == 0 { self?.disconnect() }
            }
            pendingTeardown = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.disconnectGrace, execute: work)
        }
    }

    private func connect() {
        guard !busy else { return }
        guard let display = VirtualDisplay.create(name: "AirView", refreshRate: Double(fps)) else {
            report("Não consegui criar o monitor AirView. Encerre a sessão do macOS (ou reinicie) e tente de novo.")
            return
        }
        problem = nil
        self.display = display
        let video = VideoPipeline(display: display, server: server, fps: fps, bitrate: bitrate,
                                  maxWidth: maxWidth, maxHeight: maxHeight)
        video.onProblem = { [weak self] message in self?.report(message) }
        video.start()
        self.video = video
        print("TV conectada: monitor \"AirView\" disponível em Ajustes do Sistema → Monitores.")
        onChange?()

        guard audio else { return }
        guard DeviceAudioCapture.isInstalled else {
            report("Saída de som AirView não instalada: rode mac/AudioDriver/install.sh para ter som na TV.")
            return
        }
        DeviceAudioCapture.setDeviceVisible(true)
        let server = self.server
        DispatchQueue.global(qos: .userInitiated).async {
            let capture = DeviceAudioCapture(timeout: 5)
            DispatchQueue.main.async {
                guard self.display != nil else { return } // a TV saiu enquanto esperávamos
                guard let capture else {
                    self.report("A saída de som AirView não apareceu. Reinstale com mac/AudioDriver/install.sh.")
                    return
                }
                capture.onAudio = { chunk in server.sendAudio(chunk) }
                do {
                    try capture.start()
                    capture.makeDefaultOutput()
                    self.audioCapture = capture
                    print("Som: saída do Mac trocada para \"AirView\" (dá para mudar em Ajustes do Sistema → Som).")
                    self.onChange?()
                } catch {
                    self.report("""
                    \(error.localizedDescription) Libere o Microfone para o AirView em Ajustes do Sistema → Privacidade e \
                    Segurança; o macOS trata a leitura da saída "AirView" como entrada de áudio.
                    """)
                }
            }
        }
    }

    private func disconnect(completion: (() -> Void)? = nil) {
        busy = true
        audioCapture?.restoreMacOutput()
        audioCapture?.stop()
        audioCapture = nil
        DeviceAudioCapture.setDeviceVisible(false)
        let video = self.video
        self.video = nil
        Task { @MainActor in
            await video?.stop()
            // Soltar o objeto remove o monitor do macOS; as janelas voltam para a tela do Mac.
            self.display = nil
            self.busy = false
            print("TV desconectada: monitor e saída de som \"AirView\" removidos.")
            self.onChange?()
            completion?()
            if self.clients > 0 { self.connect() }
        }
    }

    /// Ao encerrar o servidor: esconde a saída de som para ela não ficar órfã.
    func shutdown() {
        audioCapture?.restoreMacOutput()
        audioCapture?.stop()
        DeviceAudioCapture.setDeviceVisible(false)
    }
}
