import CoreAudio
import Foundation

/// Converte áudio Float32 do Core Audio (intercalado ou não) em PCM 16-bit intercalado little-endian,
/// que o AudioTrack do Android toca diretamente.
enum AudioPCM {
    struct Chunk {
        let data: Data
        let sampleRate: Int
        let channels: Int
        /// Momento da captura em µs, no mesmo relógio do vídeo (host time); a TV usa para sincronizar.
        let pts: Int64
    }

    static func convert(_ list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) -> (data: Data, channels: Int)? {
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }
        let inChannels = Int(format.mChannelsPerFrame)
        let outChannels = min(inChannels, 2)
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let frames = Int(first.mDataByteSize) / (nonInterleaved ? 4 : 4 * inChannels)
        guard frames > 0, outChannels > 0 else { return nil }

        var out = Data(count: frames * outChannels * 2)
        out.withUnsafeMutableBytes { outRaw in
            let dst = outRaw.bindMemory(to: Int16.self)
            for channel in 0..<outChannels {
                let buffer = nonInterleaved ? buffers[channel] : buffers[0]
                guard let src = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = nonInterleaved ? 1 : inChannels
                let offset = nonInterleaved ? 0 : channel
                for frame in 0..<frames {
                    let sample = max(-1, min(1, src[frame * stride + offset]))
                    dst[frame * outChannels + channel] = Int16(sample * 32767).littleEndian
                }
            }
        }
        return (out, outChannels)
    }
}
