import CoreGraphics
import Foundation

/// Captura + codificação de vídeo que acompanha o painel Ajustes → Monitores: se o usuário troca a resolução
/// do "AirView" ou escolhe espelhar/estender, recria a captura com a tela e o tamanho certos.
final class VideoPipeline {
    private let display: VirtualDisplay
    private let server: StreamServer
    private let fps: Int
    private let bitrate: Int
    private let maxWidth: Int
    private let maxHeight: Int

    private struct Target: Equatable {
        let source: CGDirectDisplayID
        let width: Int
        let height: Int
    }

    private var current: Target?
    private var capture: ScreenCapture?
    private var encoder: VideoEncoder?
    private var restarting = false
    /// A captura falhou (ex.: sem permissão): não tenta de novo nesta sessão, senão o macOS pede a permissão em loop.
    private var blocked = false
    private var timer: DispatchSourceTimer?
    /// Falha que o usuário precisa resolver (ex.: permissão de Gravação de Tela).
    var onProblem: ((String) -> Void)?

    init(display: VirtualDisplay, server: StreamServer, fps: Int, bitrate: Int, maxWidth: Int, maxHeight: Int) {
        self.display = display
        self.server = server
        self.fps = fps
        self.bitrate = bitrate
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        server.onKeyframeNeeded = { [weak self] in
            DispatchQueue.main.async { self?.encoder?.requestKeyframe() }
        }
    }

    /// Começa e passa a conferir a configuração da tela a cada segundo.
    func start() {
        reconcile()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        self.timer = timer
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        server.onKeyframeNeeded = nil
        await capture?.stop()
        encoder?.invalidate()
        capture = nil
        encoder = nil
        current = nil
    }

    private func desiredTarget() -> Target? {
        let source = display.captureSource
        var pixelWidth = 0, pixelHeight = 0
        if let mode = CGDisplayCopyDisplayMode(source) {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
        } else {
            // Monitor recriado: às vezes o macOS ainda não devolve o modo; os limites da tela já servem.
            let bounds = CGDisplayBounds(source)
            pixelWidth = Int(bounds.width)
            pixelHeight = Int(bounds.height)
        }
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        // Transmite na resolução real da tela, limitada ao que a TV mostra (padrão 1080p); mantém a proporção.
        let scale = min(1, Double(maxWidth) / Double(pixelWidth), Double(maxHeight) / Double(pixelHeight))
        return Target(source: source,
                      width: Int(Double(pixelWidth) * scale) & ~1,
                      height: Int(Double(pixelHeight) * scale) & ~1)
    }

    private func reconcile() {
        guard !restarting, !blocked, let target = desiredTarget(), target != current else { return }
        // Sem permissão de Gravação de Tela: pede uma vez (o macOS mostra o aviso) e para por aqui.
        guard CGPreflightScreenCaptureAccess() else {
            blocked = true
            CGRequestScreenCaptureAccess()
            onProblem?("""
            Falta permissão de Gravação de Tela. Libere o AirView em Ajustes do Sistema → Privacidade e Segurança → \
            Gravação de Tela e Áudio do Sistema, depois saia e abra o AirView de novo.
            """)
            return
        }
        restarting = true
        let oldCapture = capture
        let oldEncoder = encoder
        capture = nil
        encoder = nil

        // Fora da thread principal: iniciar o ScreenCaptureKit a partir dela trava o startCapture() neste processo.
        Task.detached {
            await oldCapture?.stop()
            oldEncoder?.invalidate()
            do {
                let (capture, encoder) = try await self.begin(target)
                DispatchQueue.main.async {
                    self.restarting = false
                    guard self.timer != nil else {
                        // stop() foi chamado enquanto a captura iniciava: descarta.
                        Task.detached { await capture.stop() }
                        encoder.invalidate()
                        return
                    }
                    self.capture = capture
                    self.encoder = encoder
                    self.current = target
                    self.restarting = false
                    encoder.requestKeyframe()
                    let mode = target.source == self.display.displayID ? "monitor estendido" : "espelhando a tela do Mac"
                    print("Vídeo: \(target.width)x\(target.height) @ \(self.fps) fps, \(mode).")
                }
            } catch {
                DispatchQueue.main.async {
                    self.restarting = false
                    self.blocked = true
                    self.onProblem?("""
                    Não consegui capturar a tela (\(error.localizedDescription)). Libere o AirView em Ajustes do Sistema → \
                    Privacidade e Segurança → Gravação de Tela e Áudio do Sistema e abra o app de novo.
                    """)
                }
            }
        }
    }

    private func begin(_ target: Target) async throws -> (ScreenCapture, VideoEncoder) {
        let encoder = try VideoEncoder(width: target.width, height: target.height, fps: fps, bitrate: bitrate)
        let server = self.server
        encoder.onParameterSets = { sps, pps in
            server.setVideoParameterSets(width: target.width, height: target.height, sps: sps, pps: pps)
        }
        encoder.onFrame = { data, keyframe, pts in
            server.sendVideoFrame(data, keyframe: keyframe, pts: pts)
        }

        let capture = ScreenCapture()
        capture.onVideo = { pixelBuffer, pts in encoder.encode(pixelBuffer, pts: pts) }
        capture.onStopped = { [weak self] _ in
            // Ex.: a tela mudou de modo no meio da captura; o próximo reconcile() recria tudo.
            DispatchQueue.main.async { self?.current = nil }
        }
        try await capture.start(displayID: target.source, width: target.width, height: target.height, fps: fps)
        return (capture, encoder)
    }
}
