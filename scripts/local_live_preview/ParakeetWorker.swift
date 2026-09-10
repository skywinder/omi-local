// Resident, offline FluidAudio worker. Private PCM and JSON use anonymous pipes only.
import Foundation
import AVFoundation
import CoreML
import FluidAudio
import Darwin

enum ProtocolError: Error { case invalidFrame, invalidState }

@main struct ParakeetWorker {
    static func emit(_ value: [String: Any], to output: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try output.write(contentsOf: data)
    }

    static func readExact(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try FileHandle.standardInput.read(upToCount: count - data.count), !part.isEmpty else {
                throw ProtocolError.invalidFrame
            }
            data.append(part)
        }
        return data
    }

    static func readFrame() throws -> Data {
        let header = try readExact(4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= 60 * 32000 + 1 else { throw ProtocolError.invalidFrame }
        return try readExact(size)
    }

    static func main() async {
        let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO))
        let null = open("/dev/null", O_WRONLY)
        dup2(null, STDOUT_FILENO); dup2(null, STDERR_FILENO); close(null)
        do {
            ModelHub.offlineMode = true
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await AsrModels.load(
                from: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
                configuration: configuration, version: .v3, encoderPrecision: .int8)
            // One shared model set, new stream/decoder/audio state for every Start.
            // The SDK chunk path is sequential and operates on raw audio windows;
            // batch parallelChunkConcurrency/melChunkContext are not used by it.
            try emit(["type": "model_ready"], to: output)
            var stream: SlidingWindowAsrManager?
            var reader: Task<Void, Error>?
            while true {
                let frame = try await Task.detached { try readFrame() }.value
                switch frame.first {
                case 1:
                    guard stream == nil, frame.count == 1 else { throw ProtocolError.invalidState }
                    let next = SlidingWindowAsrManager(config: .default)
                    try await next.loadModels(models)
                    let updates = await next.transcriptionUpdates
                    let vocabulary = models.vocabulary
                    reader = Task {
                        var tokens: [Int] = []
                        for await update in updates {
                            // Updates contain newly deduplicated tokens, not replacements
                            // for the preceding low-confidence window. Reconstruct all of
                            // them using the SDK's SentencePiece rule to preserve history
                            // and words that cross window boundaries.
                            tokens.append(contentsOf: update.tokenIds)
                            let text = tokens.compactMap { vocabulary[$0] }.joined()
                                .replacingOccurrences(of: "▁", with: " ")
                                .trimmingCharacters(in: .whitespaces)
                            try emit(["type": "snapshot", "text": text], to: output)
                        }
                    }
                    try await next.startStreaming()
                    stream = next
                    try emit(["type": "started"], to: output)
                case 2:
                    guard let stream, frame.count > 1, frame.count % 2 == 1 else {
                        throw ProtocolError.invalidFrame
                    }
                    let pcm = frame.dropFirst()
                    let count = pcm.count / 2
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                               channels: 1, interleaved: false)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                    buffer.frameLength = AVAudioFrameCount(count)
                    pcm.withUnsafeBytes { bytes in
                        for i in 0..<count {
                            let word = bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                            buffer.floatChannelData![0][i] = Float(Int16(littleEndian: word)) / 32768
                        }
                    }
                    await stream.streamAudio(buffer)
                case 3:
                    guard let current = stream, frame.count == 1 else { throw ProtocolError.invalidState }
                    _ = try await current.finish()
                    // finish drains inference; cancel now closes the update stream.
                    await current.cancel()
                    try await reader?.value
                    await current.cleanup()
                    reader = nil; stream = nil
                    try emit(["type": "finished"], to: output)
                default:
                    throw ProtocolError.invalidFrame
                }
            }
        } catch {
            try? emit(["type": "error"], to: output)
            exit(1)
        }
    }
}
