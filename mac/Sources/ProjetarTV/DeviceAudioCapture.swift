import CoreAudio
import CGVirtualDisplayPrivate
import Foundation

/// Lê o áudio que o macOS toca no dispositivo de som "AirView" (driver em mac/AudioDriver, um loopback).
/// O dispositivo só existe enquanto há uma TV conectada; só chega som quando o usuário o escolhe como saída
/// em Ajustes → Som, caso contrário silêncio.
final class DeviceAudioCapture {
    static let deviceUID = "ProjetarTV_UID"

    var onAudio: ((AudioPCM.Chunk) -> Void)?

    private let device: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "audio.device", qos: .userInteractive)

    /// Espera o dispositivo aparecer (o driver só o mostra com uma TV conectada). nil se não aparecer a tempo,
    /// por exemplo se o driver não estiver instalado.
    init?(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var found = Self.findDevice(uid: Self.deviceUID)
        while found == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            found = Self.findDevice(uid: Self.deviceUID)
        }
        guard let device = found else { return nil }
        self.device = device
        // 48 kHz é a taxa nativa da maioria das TVs; evita reamostragem no Android.
        var rate = Float64(48_000)
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/ProjetarTVAudio.driver")
    }

    func start() throws {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format), "ler o formato do áudio")
        let sampleRate = Int(format.mSampleRate)

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let chunk = AudioPCM.convert(inputData, format: format) else { return }
            let nanos = AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime)
            self.onAudio?(AudioPCM.Chunk(data: chunk.data, sampleRate: sampleRate, channels: chunk.channels,
                                         pts: Int64(nanos / 1000)))
        }
        try check(status, "abrir o dispositivo AirView")
        try check(AudioDeviceStart(device, procID), "iniciar a captura do dispositivo AirView")
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
        onAudio = nil
    }

    /// Saída que estava em uso antes de passar o som para a TV, para "Som no Mac" voltar a ela.
    private var previousOutput: AudioDeviceID?

    var isDefaultOutput: Bool { Self.defaultOutput() == device }

    /// Torna "AirView" a saída de som do Mac, como acontece ao conectar um fone ou uma TV por HDMI.
    /// Ao desconectar, o dispositivo some e o macOS volta sozinho para a saída anterior.
    func makeDefaultOutput() {
        let current = Self.defaultOutput()
        if current != device && current != kAudioObjectUnknown { previousOutput = current }
        Self.setDefaultOutput(device)
    }

    /// Devolve o som para a saída anterior do Mac (ou os alto-falantes internos).
    func restoreMacOutput() {
        guard isDefaultOutput else { return }
        if let target = previousOutput ?? Self.builtInOutput() { Self.setDefaultOutput(target) }
    }

    private static func setDefaultOutput(_ device: AudioDeviceID) {
        var device = device
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        }
    }

    private static func defaultOutput() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func builtInOutput() -> AudioDeviceID? {
        allDevices().first { device in
            var address = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
                && transport == kAudioDeviceTransportTypeBuiltIn && streamsSize > 0
        }
    }

    /// Mostra ou esconde a saída "AirView" no macOS (o driver escuta esta notificação).
    static func setDeviceVisible(_ visible: Bool) {
        let name = "br.com.maico.projetartv.connected"
        var token: Int32 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return }
        notify_set_state(token, visible ? 1 : 0)
        notify_post(name)
        notify_cancel(token)
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        return devices
    }

    private static func findDevice(uid: String) -> AudioDeviceID? {
        allDevices().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Não consegui \(action) (OSStatus \(status))."])
        }
    }
}
