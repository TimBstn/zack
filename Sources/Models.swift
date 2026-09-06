import Foundation
import AVFoundation

struct VideoClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var sourceURL: URL
    var name: String
    var sourceDuration: Double
    var trimStart: Double = 0
    var trimEnd: Double
    /// A per-clip gain multiplier. One is the original recording level.
    var volume: Double = 1
    /// Black fades at the beginning and end of this timeline clip.
    var fadeInDuration: Double = 0
    var fadeOutDuration: Double = 0

    var duration: Double { max(0, trimEnd - trimStart) }
    var assetRange: CMTimeRange { CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600)) }
}

struct MusicClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var sourceURL: URL
    var name: String
    var sourceDuration: Double
    var trimStart: Double = 0
    var trimEnd: Double
    /// Position on the finished-video timeline, in seconds.
    var timelineStart: Double = 0
    var volume: Double = 0.35
    var fadeInDuration: Double = 0
    var fadeOutDuration: Double = 0

    var duration: Double { max(0, trimEnd - trimStart) }
    var assetRange: CMTimeRange { CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600)) }
}

struct SubtitleCue: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var startTime: Double
    var endTime: Double
    var text: String
}

struct SubtitleLayout: Codable, Equatable {
    /// Offsets are relative to the preview frame, keeping a layout stable when
    /// the editor window is resized.
    var horizontalOffset: Double = 0
    /// Zero is the vertical center of the video. The default keeps captions in
    /// the lower third while preserving a balanced up/down control.
    var verticalOffset: Double = 0.34
    var scale: Double = 1

}

enum VideoOutputFormat: String, Codable, CaseIterable, Identifiable {
    case youtube
    case instagram

    var id: Self { self }

    var name: String {
        switch self {
        case .youtube: "YouTube Video"
        case .instagram: "Shorts & Reels"
        }
    }

    var dimensions: CGSize {
        switch self {
        case .youtube: CGSize(width: 1_920, height: 1_080)
        case .instagram: CGSize(width: 1_080, height: 1_920)
        }
    }

    var aspectRatio: CGFloat { dimensions.width / dimensions.height }
    var detail: String { "\(Int(dimensions.width)) × \(Int(dimensions.height))" }
}

/// Deliberately small, familiar caption looks. Keeping these as presets makes
/// captions fast to style while retaining a consistent, readable result.
enum SubtitleStyle: String, Codable, CaseIterable, Identifiable {
    case classic
    case creator
    case outline
    case zack
    case comic
    case sticker
    case chalk
    case cinema
    case neon
    case arcade

    var id: Self { self }

    var name: String {
        switch self {
        case .classic: "Classic"
        case .creator: "Creator"
        case .zack: "Zack"
        case .comic: "Comic"
        case .sticker: "Sticker"
        case .chalk: "Chalk"
        case .cinema: "Cinema"
        case .neon: "Neon"
        case .outline: "Outline"
        case .arcade: "Arcade"
        }
    }

    var detail: String {
        switch self {
        case .classic: "White on a dark caption bar"
        case .creator: "Montserrat: bold and clean for creators"
        case .zack: "Bungee: Zack orange, red depth, and high-energy impact"
        case .comic: "Bangers: comic-book punch with a red offset shadow"
        case .sticker: "Luckiest Guy: a bright, tilted sticker treatment"
        case .chalk: "Rock Salt: handwritten chalk on a blackboard"
        case .cinema: "DM Serif Display: cream text in a film-title card"
        case .neon: "Monoton: glowing neon signage"
        case .outline: "White headline type with a strong dark keyline"
        case .arcade: "Press Start 2P: pixel arcade energy"
        }
    }
}

struct ZackProject: Codable {
    var clips: [VideoClip]
    var musicClips: [MusicClip]
    var subtitles: [SubtitleCue]
    var subtitleStyle: SubtitleStyle
    var subtitleLayout: SubtitleLayout
    var outputFormat: VideoOutputFormat

    init(clips: [VideoClip] = [], musicClips: [MusicClip] = [], subtitles: [SubtitleCue] = [], subtitleStyle: SubtitleStyle = .classic, subtitleLayout: SubtitleLayout = SubtitleLayout(), outputFormat: VideoOutputFormat = .youtube) {
        self.clips = clips
        self.musicClips = musicClips
        self.subtitles = subtitles
        self.subtitleStyle = subtitleStyle
        self.subtitleLayout = subtitleLayout
        self.outputFormat = outputFormat
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
