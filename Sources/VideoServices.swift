import AVFoundation
import CoreVideo
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

actor MusicMetadataService {
    func clip(for url: URL) async throws -> MusicClip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0,
              try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return MusicClip(sourceURL: url, name: url.deletingPathExtension().lastPathComponent, sourceDuration: seconds, trimEnd: seconds)
    }
}

/// Reads the actual PCM samples in a trimmed clip to find its loudest output
/// sample. The UI adds the user's gain setting to this value, so the meter is
/// meaningful for both quiet and already-loud source recordings.
actor AudioLevelAnalysisService {
    func peakDecibels(for clip: VideoClip) async -> Double? {
        let asset = AVURLAsset(url: clip.sourceURL)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }

        do {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            reader.timeRange = clip.assetRange
            guard reader.startReading() else { return nil }

            var peak: Float = 0
            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount >= MemoryLayout<Float>.size else { continue }
                var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                _ = samples.withUnsafeMutableBytes { destination in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: destination.baseAddress!)
                }
                for sample in samples { peak = max(peak, abs(sample)) }
            }
            guard reader.status == .completed else { return nil }
            // -80 dB is a useful floor for silent or near-silent footage.
            return max(-80, 20 * log10(max(Double(peak), 0.000_000_01)))
        } catch {
            return nil
        }
    }
}

struct RenderedTimeline {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
}

/// Builds a fixed-size output canvas for both preview and export. Every source
/// is aspect-fit on black, avoiding the distortion caused by stretching clips
/// between horizontal and vertical formats.
enum TimelineCompositionService {
    /// Reuses an already-rendered composition when only gain changes. This
    /// avoids replacing the AVPlayer item (and flashing a blank preview).
    static func liveAudioMix(clips: [VideoClip], musicClips: [MusicClip], composition: AVComposition) -> AVAudioMix? {
        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        var parameters: [AVMutableAudioMixInputParameters] = []
        let videoParameters = AVMutableAudioMixInputParameters(track: tracks[0])
        var cursor = CMTime.zero
        for clip in clips {
            videoParameters.setVolume(Float(clip.volume), at: cursor)
            cursor = cursor + clip.assetRange.duration
        }
        parameters.append(videoParameters)
        for (music, track) in zip(musicClips, tracks.dropFirst()) {
            let musicParameters = AVMutableAudioMixInputParameters(track: track)
            let start = CMTime(seconds: music.timelineStart, preferredTimescale: 600)
            let available = max(0, composition.duration.seconds - music.timelineStart)
            applyMusicGain(music, to: musicParameters, at: start, duration: min(music.duration, available))
            parameters.append(musicParameters)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    static func make(clips: [VideoClip], musicClips: [MusicClip] = [], outputFormat: VideoOutputFormat) async throws -> RenderedTimeline {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.coderInvalidValue)
        }
        let totalDuration = clips.reduce(CMTime.zero) { $0 + $1.assetRange.duration }
        // AVFoundation's default canvas is undefined wherever an opacity ramp
        // makes a source transparent (often green on recent macOS releases).
        // A real, opaque black video track is stable in both preview and export
        // and avoids the Core Animation compositor that was crashing Zack.
        let blackCanvasURL = try await makeBlackCanvas(
            size: outputFormat.dimensions,
            duration: totalDuration
        )
        let blackCanvasAsset = AVURLAsset(url: blackCanvasURL)
        guard let blackCanvasSource = try await blackCanvasAsset.loadTracks(withMediaType: .video).first,
              let blackCanvasTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try blackCanvasTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: totalDuration),
            of: blackCanvasSource,
            at: .zero
        )
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioParameters = audioTrack.map { AVMutableAudioMixInputParameters(track: $0) }
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for clip in clips {
            let asset = AVURLAsset(url: clip.sourceURL)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try videoTrack.insertTimeRange(clip.assetRange, of: sourceVideo, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: clip.assetRange.duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(
                try await aspectFitTransform(for: sourceVideo, in: outputFormat.dimensions),
                at: cursor
            )
            let clipDuration = clip.assetRange.duration.seconds
            let fadeIn = min(clip.fadeInDuration, clipDuration)
            let fadeOut = min(clip.fadeOutDuration, max(0, clipDuration - fadeIn))
            if fadeIn > 0 {
                layerInstruction.setOpacityRamp(
                    fromStartOpacity: 0,
                    toEndOpacity: 1,
                    timeRange: CMTimeRange(start: cursor, duration: CMTime(seconds: fadeIn, preferredTimescale: 600))
                )
            }
            if fadeOut > 0 {
                let fadeStart = cursor + CMTime(seconds: clipDuration - fadeOut, preferredTimescale: 600)
                layerInstruction.setOpacityRamp(
                    fromStartOpacity: 1,
                    toEndOpacity: 0,
                    timeRange: CMTimeRange(start: fadeStart, duration: CMTime(seconds: fadeOut, preferredTimescale: 600))
                )
            }
            let blackLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: blackCanvasTrack)
            instruction.layerInstructions = [layerInstruction, blackLayerInstruction]
            instructions.append(instruction)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(clip.assetRange, of: sourceAudio, at: cursor)
                audioParameters?.setVolume(Float(clip.volume), at: cursor)
            }
            cursor = cursor + clip.assetRange.duration
        }

        var musicParameters: [AVMutableAudioMixInputParameters] = []
        for music in musicClips {
            let asset = AVURLAsset(url: music.sourceURL)
            guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                  let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let start = CMTime(seconds: music.timelineStart, preferredTimescale: 600)
            let availableDuration = max(0, cursor.seconds - music.timelineStart)
            guard availableDuration > 0 else { continue }
            let playableRange = CMTimeRange(
                start: music.assetRange.start,
                duration: CMTime(seconds: min(music.duration, availableDuration), preferredTimescale: 600)
            )
            try? musicTrack.insertTimeRange(playableRange, of: sourceAudio, at: start)
            let parameters = AVMutableAudioMixInputParameters(track: musicTrack)
            applyMusicGain(music, to: parameters, at: start, duration: playableRange.duration.seconds)
            musicParameters.append(parameters)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputFormat.dimensions
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        let audioMix: AVAudioMix?
        if let audioParameters {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [audioParameters] + musicParameters
            audioMix = mix
        } else if !musicParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = musicParameters
            audioMix = mix
        } else {
            audioMix = nil
        }
        return RenderedTimeline(composition: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    /// Generates two opaque black frames spanning the requested duration. The
    /// file stays in the system temporary directory for the AVComposition to
    /// read while previewing/exporting, and is cleared by macOS automatically.
    private static func makeBlackCanvas(size: CGSize, duration: CMTime) async throws -> URL {
        guard duration > .zero else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zack-black-canvas-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let frameDuration = CMTime(value: 1, timescale: 30)
        let finalFrameTime = max(frameDuration, duration - frameDuration)
        guard adaptor.append(pixelBuffer, withPresentationTime: .zero),
              adaptor.append(pixelBuffer, withPresentationTime: finalFrameTime) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func applyMusicGain(_ music: MusicClip, to parameters: AVMutableAudioMixInputParameters, at start: CMTime, duration: Double) {
        guard duration > 0 else { return }
        let fadeIn = min(music.fadeInDuration, duration)
        let fadeOut = min(music.fadeOutDuration, max(0, duration - fadeIn))
        let target = Float(music.volume)
        if fadeIn > 0 {
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: target, timeRange: CMTimeRange(start: start, duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
        } else {
            parameters.setVolume(target, at: start)
        }
        if fadeOut > 0 {
            let fadeStart = start + CMTime(seconds: duration - fadeOut, preferredTimescale: 600)
            parameters.setVolumeRamp(fromStartVolume: target, toEndVolume: 0, timeRange: CMTimeRange(start: fadeStart, duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
        }
    }

    private static func aspectFitTransform(for track: AVAssetTrack, in canvas: CGSize) async throws -> CGAffineTransform {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(transformedBounds.width), height: abs(transformedBounds.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { throw CocoaError(.fileReadCorruptFile) }

        let scale = min(canvas.width / orientedSize.width, canvas.height / orientedSize.height)
        let fittedSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let centering = CGPoint(
            x: (canvas.width - fittedSize.width) / 2,
            y: (canvas.height - fittedSize.height) / 2
        )

        // Normalize the track's preferred orientation to its own origin, then
        // scale and center it on the requested black output canvas.
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -transformedBounds.minX, y: -transformedBounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centering.x, y: centering.y))
    }
}

final class VideoExportService: @unchecked Sendable {
    func export(clips: [VideoClip], musicClips: [MusicClip] = [], outputFormat: VideoOutputFormat, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let timeline = try await TimelineCompositionService.make(clips: clips, musicClips: musicClips, outputFormat: outputFormat)
        let preset = AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: timeline.composition, presetName: preset) else { throw CocoaError(.coderInvalidValue) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        session.outputURL = destination; session.outputFileType = .mp4; session.videoComposition = timeline.videoComposition; session.audioMix = timeline.audioMix; session.shouldOptimizeForNetworkUse = true
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
            "--vad",
            "--vad-model", try NativeWhisperRuntime.vadModelURL().path,
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
        let subtitles = cleanedSubtitles(try parseSRT(contents))
        guard !subtitles.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try renderSRT(subtitles).write(to: destination, atomically: true, encoding: .utf8)
        return subtitles
    }

    /// Some Whisper outputs include a literal blank-audio marker as a caption.
    /// Keep it out of both the editor and the persisted SRT while preserving
    /// any real text that might appear alongside the marker.
    private func cleanedSubtitles(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.compactMap { cue in
            let text = cue.text
                .replacingOccurrences(
                    of: #"\[\s*blank(?:\s+(?:text|audio))?\s*\]"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SubtitleCue(id: cue.id, startTime: cue.startTime, endTime: cue.endTime, text: text)
        }
    }

    private func renderSRT(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(srtTimestamp(cue.startTime)) --> \(srtTimestamp(cue.endTime))\n\(cue.text)"
        }
        .joined(separator: "\n\n") + "\n"
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

    private func srtTimestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let remainingSeconds = (milliseconds % 60_000) / 1_000
        let remainingMilliseconds = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, remainingSeconds, remainingMilliseconds)
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

    static func vadModelURL() throws -> URL {
        let bundleModel = Bundle.main.resourceURL?
            .appendingPathComponent("Whisper/ggml-silero-v6.2.0.bin")
        let developmentModel = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Whisper/ggml-silero-v6.2.0.bin")
        return try existingURL(bundleModel, fallback: developmentModel, name: "voice activity detection model")
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
