import CoreMedia
import Foundation
import VideoToolbox

struct EncoderError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "Falha ao criar o codificador H.264 (OSStatus \(status))." }
}

/// Codificador H.264 por hardware (VideoToolbox) ajustado para baixa latência.
final class VideoEncoder {
    /// SPS e PPS sem start code; emitidos antes de todo quadro-chave.
    var onParameterSets: ((Data, Data) -> Void)?
    /// Quadro em Annex B, se é quadro-chave, PTS em microssegundos.
    var onFrame: ((Data, Bool, Int64) -> Void)?

    private let session: VTCompressionSession
    private let queue = DispatchQueue(label: "encoder", qos: .userInteractive)
    private var forceKeyframe = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var lastEncodeTime = DispatchTime.now()
    private var repeatTimer: DispatchSourceTimer?

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        var created: VTCompressionSession?
        var lowLatency = true
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        if status != noErr {
            lowLatency = false
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let created else { throw EncoderError(status: status) }
        session = created

        let profile = lowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        // Com a tela parada o ScreenCaptureKit não manda quadros, mas vários decodificadores de TV (ex.: Realtek)
        // só exibem depois de receber alguns quadros. Repetimos o último quadro (custa poucos bytes) a 30 fps.
        let interval = DispatchTimeInterval.milliseconds(33)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let last = self.lastPixelBuffer,
                  DispatchTime.now().uptimeNanoseconds - self.lastEncodeTime.uptimeNanoseconds > 30_000_000
            else { return }
            self.encodeOnQueue(last, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        timer.resume()
        repeatTimer = timer
    }

    /// Libera o codificador (troca de resolução cria outro).
    func invalidate() {
        queue.sync {
            repeatTimer?.cancel()
            repeatTimer = nil
            lastPixelBuffer = nil
            onFrame = nil
            onParameterSets = nil
            VTCompressionSessionInvalidate(session)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        queue.async { self.encodeOnQueue(pixelBuffer, pts: pts) }
    }

    /// Força um quadro-chave. Reenvia o último quadro porque, com a tela parada, o ScreenCaptureKit não manda nada novo.
    func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            if let last = self.lastPixelBuffer {
                self.encodeOnQueue(last, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    private func encodeOnQueue(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lastPixelBuffer = pixelBuffer
        lastEncodeTime = DispatchTime.now()
        // O codificador exige PTS sempre crescente; quadros reenviados podem chegar fora de ordem.
        let minimum = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1_000_000))
        let timestamp = CMTimeCompare(pts, minimum) < 0 ? minimum : pts
        lastPTS = timestamp

        let frameProperties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: timestamp, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.handle(sampleBuffer)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync

        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let sps = parameterSet(format, index: 0), let pps = parameterSet(format, index: 1) {
            onParameterSets?(sps, pps)
        }

        // VideoToolbox entrega AVCC (NALs com prefixo de 4 bytes de tamanho); o Android quer Annex B.
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        let copyStatus = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        var annexB = Data(capacity: avcc.count)
        var offset = 0
        while offset + 4 <= avcc.count {
            let length = avcc[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard offset + length <= avcc.count else { break }
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(avcc[offset..<offset + length])
            offset += length
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(annexB, keyframe, Int64(CMTimeGetSeconds(pts) * 1_000_000))
    }

    private func parameterSet(_ format: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
