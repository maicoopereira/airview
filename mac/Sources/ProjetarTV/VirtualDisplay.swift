import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// Monitor virtual "AirView". O macOS trata como uma tela física: em Ajustes → Monitores dá para escolher
/// a resolução e se ele estende ou espelha a tela do Mac. Existe enquanto este objeto (e o processo) viver.
final class VirtualDisplay {
    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    private static let serialKey = "virtualDisplaySerial"

    /// Resoluções oferecidas no painel Monitores (com variantes Retina geradas pelo macOS). A primeira é a padrão.
    private static let modes: [(Int, Int)] = [(1920, 1080), (1280, 720), (2560, 1440), (3840, 2160)]

    /// Cria o monitor e espera ele ficar online. No macOS 26 uma identidade (vendor/produto/série) que já falhou
    /// pode ficar bloqueada pelo estado salvo do WindowServer; nesse caso tenta números de série novos
    /// e lembra o que funcionou.
    static func create(name: String, refreshRate: Double) -> VirtualDisplay? {
        let defaults = UserDefaults.standard
        let firstSerial = max(defaults.integer(forKey: serialKey), 1)
        for serial in firstSerial..<firstSerial + 8 {
            guard let display = VirtualDisplay(name: name, refreshRate: refreshRate, serial: UInt32(serial))
            else { continue }
            if display.waitUntilOnline(timeout: 3) {
                defaults.set(serial, forKey: serialKey)
                return display
            }
            print("Monitor virtual (série \(serial)) não ficou online; tentando outra identidade…")
        }
        return nil
    }

    private init?(name: String, refreshRate: Double, serial: UInt32) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        // Tamanho de um monitor de ~27". Tamanhos de TV grande atrasam ou impedem o monitor de ficar online no macOS 26.
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.vendorID = 0x5054
        descriptor.productID = 0x0005
        descriptor.serialNum = serial
        descriptor.terminationHandler = { _, _ in
            print("O macOS encerrou o monitor virtual.")
        }

        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = Self.modes.map {
            CGVirtualDisplayMode(width: UInt32($0.0), height: UInt32($0.1), refreshRate: refreshRate)
        }
        guard display.apply(settings) else { return nil }
        self.display = display
    }

    private func waitUntilOnline(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.onlineDisplays().contains(displayID) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Tela que deve ser capturada agora: o próprio monitor quando estendido; quando o usuário escolheu
    /// espelhar no painel Monitores, a tela principal do grupo espelhado (o monitor espelho some do ScreenCaptureKit).
    var captureSource: CGDirectDisplayID {
        guard CGDisplayIsInMirrorSet(displayID) == 1 else { return displayID }
        let primary = CGDisplayPrimaryDisplay(displayID)
        return primary == kCGNullDirectDisplay ? displayID : primary
    }

    var isMirrored: Bool { CGDisplayIsInMirrorSet(displayID) == 1 }

    /// Mesmo efeito de Ajustes → Monitores → Usar como: espelhar a tela do Mac ou estender.
    func setMirrored(_ mirrored: Bool) {
        let master = mirrored ? Self.macDisplay() : kCGNullDirectDisplay
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(config, displayID, master)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    /// A tela do próprio Mac (a interna, ou a principal que não seja a TV).
    private static func macDisplay() -> CGDirectDisplayID {
        let displays = onlineDisplays()
        return displays.first { CGDisplayIsBuiltin($0) == 1 } ?? CGMainDisplayID()
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
