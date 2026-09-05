import AVFoundation
import Foundation

struct SubtitleTranscriptionSettings: Sendable {
    static let maximumCharactersKey = "subtitleMaximumCharacters"
    static let splitOnWordBoundariesKey = "subtitleSplitOnWordBoundaries"

    let maximumCharacters: Int
    let splitOnWordBoundaries: Bool

    static var current: SubtitleTranscriptionSettings {
        let defaults = UserDefaults.standard
        let savedMaximum = defaults.object(forKey: maximumCharactersKey) as? Int ?? 15
        let splitOnWords = defaults.object(forKey: splitOnWordBoundariesKey) as? Bool ?? true
        return SubtitleTranscriptionSettings(
            maximumCharacters: min(max(savedMaximum, 5), 80),
            splitOnWordBoundaries: splitOnWords
        )
    }
}

actor VideoMetadataService {
    func clip(for url: URL) async throws -> VideoClip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return VideoClip(sourceURL: url, name: url.deletingPathExtension().lastPathComponent, sourceDuration: seconds, trimEnd: seconds)
    }
}

/// Builds the same ordered, trimmed timeline used for export, but keeps it in
/// memory so the editor can play it immediately.
enum VideoPreviewCompositionService {
    @MainActor
    static func make(clips: [VideoClip]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.coderInvalidValue)
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero

        for clip in clips {
            let asset = AVURLAsset(url: clip.sourceURL)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try videoTrack.insertTimeRange(clip.assetRange, of: sourceVideo, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(clip.assetRange, of: sourceAudio, at: cursor)
            }
            cursor = cursor + clip.assetRange.duration
        }
        return composition
    }
}

final class VideoExportService: @unchecked Sendable {
    func export(clips: [VideoClip], to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.coderInvalidValue) }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for clip in clips {
            let asset = AVURLAsset(url: clip.sourceURL)
            let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
            guard let sourceVideo else { throw CocoaError(.fileReadCorruptFile) }
            try videoTrack.insertTimeRange(clip.assetRange, of: sourceVideo, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first { try? audioTrack?.insertTimeRange(clip.assetRange, of: sourceAudio, at: cursor) }
            cursor = cursor + clip.assetRange.duration
        }
        let preset = AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { throw CocoaError(.coderInvalidValue) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        session.outputURL = destination; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        await session.export()
        progress(1)
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        return destination
    }
}

final class NativeWhisperSubtitleService: @unchecked Sendable {
    func transcribe(
        video: URL,
        to destination: URL,
        settings: SubtitleTranscriptionSettings
    ) async throws -> [SubtitleCue] {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zack-NativeWhisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let audioURL = temporaryDirectory.appendingPathComponent("timeline.wav")
        try await AudioExtractionService.extractMono16BitWAV(from: video, to: audioURL)
        let outputStem = temporaryDirectory.appendingPathComponent("subtitles")
        let process = Process()
        process.executableURL = try NativeWhisperRuntime.cliURL()
        var arguments = [
            "--model", try NativeWhisperRuntime.modelURL().path,
            "--file", audioURL.path,
            "--language", "en",
            "--output-srt",
            "--max-len", String(settings.maximumCharacters),
            "--output-file", outputStem.path,
            "--no-prints",
            "--no-gpu"
        ]
        if settings.splitOnWordBoundaries {
            arguments.append("--split-on-word")
        }
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Zack.NativeWhisper", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "The bundled transcription engine exited with status \(process.terminationStatus)."])
        }

        let generatedSRT = outputStem.appendingPathExtension("srt")
        let contents = try String(contentsOf: generatedSRT, encoding: .utf8)
        let subtitles = try parseSRT(contents)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try contents.write(to: destination, atomically: true, encoding: .utf8)
        return subtitles
    }

    private func parseSRT(_ contents: String) throws -> [SubtitleCue] {
        let blocks = contents.components(separatedBy: "\n\n")
        let cues = blocks.compactMap { block -> SubtitleCue? in
            let lines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard let timestampIndex = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let timestamps = lines[timestampIndex].components(separatedBy: " --> ")
            guard timestamps.count == 2,
                  let start = srtTime(timestamps[0]),
                  let end = srtTime(timestamps[1]) else { return nil }
            let text = lines.dropFirst(timestampIndex + 1).joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            return SubtitleCue(startTime: start, endTime: end, text: text)
        }
        guard !cues.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return cues
    }

    private func srtTime(_ value: String) -> Double? {
        let components = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

private enum NativeWhisperRuntime {
    static func cliURL() throws -> URL {
        let bundleCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper-cli")
        let developmentCLI = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/whisper.cpp/build-macos/bin/whisper-cli")
        return try executableURL(bundleCLI, fallback: developmentCLI, name: "native transcription engine")
    }

    static func modelURL() throws -> URL {
        let bundleModel = Bundle.main.resourceURL?
            .appendingPathComponent("Whisper/ggml-small.en.bin")
        let developmentModel = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Whisper/ggml-small.en.bin")
        return try existingURL(bundleModel, fallback: developmentModel, name: "English transcription model")
    }

    private static func executableURL(_ primary: URL, fallback: URL, name: String) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: primary.path) || FileManager.default.isExecutableFile(atPath: fallback.path) else {
            throw NSError(domain: "Zack.NativeWhisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled \(name) is missing."])
        }
        return FileManager.default.isExecutableFile(atPath: primary.path) ? primary : fallback
    }

    private static func existingURL(_ primary: URL?, fallback: URL, name: String) throws -> URL {
        if let primary, FileManager.default.fileExists(atPath: primary.path) { return primary }
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw NSError(domain: "Zack.NativeWhisper", code: 2, userInfo: [NSLocalizedDescriptionKey: "The bundled \(name) is missing."])
        }
        return fallback
    }
}

private enum AudioExtractionService {
    static func extractMono16BitWAV(from video: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadNoPermission)
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        guard reader.canAdd(output) else { throw CocoaError(.coderInvalidValue) }
        reader.add(output)
        FileManager.default.createFile(atPath: destination.path, contents: Data(repeating: 0, count: 44))
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seek(toOffset: 44)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var dataLength = 0
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            // AVAssetReader preserves presentation timestamps. Insert any gap
            // before this buffer as PCM silence instead of compacting speech
            // toward 0:00; Whisper's timestamps then match the video timeline.
            let presentationTime = max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            let expectedDataLength = Int((presentationTime * 16_000).rounded()) * 2
            if expectedDataLength > dataLength {
                let silenceLength = expectedDataLength - dataLength
                try handle.write(contentsOf: Data(repeating: 0, count: silenceLength))
                dataLength += silenceLength
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw CocoaError(.fileReadUnknown) }
            try handle.write(contentsOf: Data(bytes))
            dataLength += length
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: wavHeader(dataLength: dataLength))
    }

    private static func wavHeader(dataLength: Int) -> Data {
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + dataLength), to: &data)
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(16_000), to: &data)
        append(UInt32(32_000), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append("data".data(using: .ascii)!)
        append(UInt32(dataLength), to: &data)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
