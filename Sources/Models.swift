import Foundation
import AVFoundation

struct VideoClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var sourceURL: URL
    var name: String
    var sourceDuration: Double
    var trimStart: Double = 0
    var trimEnd: Double

    var duration: Double { max(0, trimEnd - trimStart) }
    var assetRange: CMTimeRange { CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600)) }
}

struct SubtitleCue: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var startTime: Double
    var endTime: Double
    var text: String
}

struct ZackProject: Codable {
    var clips: [VideoClip]
    var subtitles: [SubtitleCue]

    init(clips: [VideoClip] = [], subtitles: [SubtitleCue] = []) {
        self.clips = clips
        self.subtitles = subtitles
    }

    private enum CodingKeys: String, CodingKey { case clips, subtitles }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clips = try values.decodeIfPresent([VideoClip].self, forKey: .clips) ?? []
        subtitles = try values.decodeIfPresent([SubtitleCue].self, forKey: .subtitles) ?? []
    }
}

enum ExportState: Equatable {
    case idle, exporting(Double), success(URL), failure(String)
}

enum SubtitleState: Equatable {
    case idle, rendering, transcribing, success(URL), failure(String)
}

extension Double {
    var timeLabel: String {
        let total = max(0, Int(self.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var editableTimeLabel: String {
        let milliseconds = max(0, Int((self * 1_000).rounded()))
        let minutes = milliseconds / 60_000
        let seconds = Double(milliseconds % 60_000) / 1_000
        return String(format: "%d:%05.2f", minutes, seconds)
    }

    static func subtitleTime(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count else { return nil }
        switch values.count {
        case 1: return values[0]
        case 2: return values[0] * 60 + values[1]
        default: return values[0] * 3_600 + values[1] * 60 + values[2]
        }
    }
}
