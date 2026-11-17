import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .displayNotFound(let id): return "Tela \(id) não apareceu no ScreenCaptureKit."
        }
    }
}

/// Captura uma tela com ScreenCaptureKit.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "capture.video", qos: .userInteractive)

    func stop() async {
        onVideo = nil
        try? await stream?.stopCapture()
        stream = nil
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        // Um monitor virtual recém-criado leva alguns instantes para aparecer na lista.
        var display: SCDisplay?
        for _ in 0..<150 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let display else { throw CaptureError.displayNotFound(displayID) }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = true
        config.queueDepth = 6

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // O ScreenCaptureKit também entrega quadros "idle" sem imagem quando nada mudou na tela.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            onVideo?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        default:
            break
        }
    }

    /// A captura caiu sozinha (ex.: a tela mudou de resolução); quem usa reinicia.
    var onStopped: ((Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
