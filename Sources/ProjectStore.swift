import SwiftUI
import AppKit

@MainActor
final class ProjectStore: ObservableObject {
    private static let clipPasteboardType = NSPasteboard.PasteboardType("com.zack.clip")

    @Published var clips: [VideoClip] = []
    @Published var selectedID: UUID?
    @Published var exportState: ExportState = .idle
    @Published var subtitleState: SubtitleState = .idle
    @Published var subtitles: [SubtitleCue] = []
    @Published var subtitleStyle: SubtitleStyle = .classic
    @Published var subtitleLayout = SubtitleLayout()
    @Published var outputFormat: VideoOutputFormat = .youtube
    @Published var playbackToggleCount = 0
    @Published var isSubtitleEditorVisible = false
    @Published var isSubtitleLayoutEditorVisible = false
    @Published var isAudioEditorVisible = false
    @Published private(set) var hasUnsavedChanges = false
    @Published var errorMessage: String?
    @Published var isImporting = false

    private var undoStack: [[VideoClip]] = []
    private var redoStack: [[VideoClip]] = []
    private let metadata = VideoMetadataService()
    private let exporter = VideoExportService()
    private let whisper = NativeWhisperSubtitleService()
    private var projectURL: URL?

    var selectedClip: VideoClip? { clips.first { $0.id == selectedID } }
    var selectedIndex: Int? { clips.firstIndex { $0.id == selectedID } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canPasteClip: Bool {
        guard let data = NSPasteboard.general.data(forType: Self.clipPasteboardType) else { return false }
        return (try? JSONDecoder().decode(VideoClip.self, from: data)) != nil
    }
    var isGeneratingSubtitles: Bool {
        subtitleState == .rendering || subtitleState == .transcribing
    }
    func subtitle(at time: Double) -> SubtitleCue? {
        subtitles.first { time >= $0.startTime && time <= $0.endTime }
    }
    func togglePlayback() { playbackToggleCount += 1 }
    func updateSubtitle(id: UUID, text: String) {
        guard let index = subtitles.firstIndex(where: { $0.id == id }) else { return }
        subtitles[index].text = text
        hasUnsavedChanges = true
    }
    func updateSubtitleTiming(id: UUID, start: Double, end: Double) -> Bool {
        guard let index = subtitles.firstIndex(where: { $0.id == id }),
              start >= 0,
              end > start + 0.05 else { return false }
        subtitles[index].startTime = start
        subtitles[index].endTime = end
        hasUnsavedChanges = true
        return true
    }

    func updateSubtitleStyle(_ style: SubtitleStyle) {
        guard subtitleStyle != style else { return }
        subtitleStyle = style
        hasUnsavedChanges = true
    }

    func updateSubtitleLayout(horizontalOffset: Double? = nil, verticalOffset: Double? = nil, scale: Double? = nil) {
        if let horizontalOffset { subtitleLayout.horizontalOffset = min(max(horizontalOffset, -0.42), 0.42) }
        if let verticalOffset { subtitleLayout.verticalOffset = min(max(verticalOffset, -0.45), 0.45) }
        if let scale { subtitleLayout.scale = min(max(scale, 0.55), 2.1) }
        hasUnsavedChanges = true
    }

    func resetSubtitleLayout() {
        subtitleLayout = SubtitleLayout()
        hasUnsavedChanges = true
    }

    func updateOutputFormat(_ format: VideoOutputFormat) {
        guard outputFormat != format else { return }
        outputFormat = format
        hasUnsavedChanges = true
    }

    func updateClipVolume(id: UUID, volume: Double) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].volume = min(max(volume, 0), 2)
        hasUnsavedChanges = true
    }

    func newProject() { clips = []; subtitles = []; subtitleStyle = .classic; subtitleLayout = SubtitleLayout(); outputFormat = .youtube; isSubtitleLayoutEditorVisible = false; isAudioEditorVisible = false; selectedID = nil; projectURL = nil; hasUnsavedChanges = false }
    func importVideos() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }
    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }; snapshot(); isImporting = true
        Task {
            var imported: [VideoClip] = []
            for url in urls {
                do { imported.append(try await metadata.clip(for: url)) }
                catch { errorMessage = "\(url.lastPathComponent) couldn’t be imported. Make sure it’s a playable video file." }
            }
            clips.append(contentsOf: imported); selectedID = imported.last?.id ?? selectedID; isImporting = false
        }
    }
    func select(_ id: UUID) { selectedID = id }
    func copySelectedClip() {
        guard let clip = selectedClip, let data = try? JSONEncoder().encode(clip) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.clipPasteboardType)
    }
    func pasteClip() {
        guard let data = NSPasteboard.general.data(forType: Self.clipPasteboardType),
              var copy = try? JSONDecoder().decode(VideoClip.self, from: data) else { return }
        copy.id = UUID()
        snapshot()
        let insertionIndex = (selectedIndex.map { $0 + 1 }) ?? clips.count
        clips.insert(copy, at: insertionIndex)
        selectedID = copy.id
    }
    func duplicateSelectedClip() {
        copySelectedClip()
        pasteClip()
    }
    func requestSubtitles() {
        guard !clips.isEmpty else { return }
        do {
            generateSubtitles(to: try nextSubtitleURL())
        } catch {
            subtitleState = .failure("A location for the subtitle file couldn’t be created. \(error.localizedDescription)")
        }
    }
    func generateSubtitles(to destination: URL) {
        guard !clips.isEmpty else { return }
        subtitleState = .rendering
        let timeline = clips
        let selectedOutputFormat = outputFormat
        let transcriptionSettings = SubtitleTranscriptionSettings.current
        let temporaryVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zack-Timeline-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        Task {
            do {
                _ = try await exporter.export(clips: timeline, outputFormat: selectedOutputFormat, to: temporaryVideo, progress: { _ in })
                defer { try? FileManager.default.removeItem(at: temporaryVideo) }
                subtitleState = .transcribing
                subtitles = try await whisper.transcribe(
                    video: temporaryVideo,
                    to: destination,
                    settings: transcriptionSettings
                )
                hasUnsavedChanges = true
                isSubtitleEditorVisible = true
                subtitleState = .success(destination)
            } catch {
                subtitleState = .failure("Subtitles couldn’t be generated. \(error.localizedDescription)")
            }
        }
    }
    private func nextSubtitleURL() throws -> URL {
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Zack Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stem = "Zack Subtitles \(formatter.string(from: Date()))"
        var number = 1
        var destination = directory.appendingPathComponent(stem).appendingPathExtension("srt")
        while FileManager.default.fileExists(atPath: destination.path) {
            number += 1
            destination = directory.appendingPathComponent("\(stem) \(number)").appendingPathExtension("srt")
        }
        return destination
    }
    func updateTrim(id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if let start { clips[index].trimStart = min(max(0, start), clips[index].trimEnd - 0.1) }
        if let end { clips[index].trimEnd = max(min(clips[index].sourceDuration, end), clips[index].trimStart + 0.1) }
    }
    func commitTrim() { snapshot() }
    func move(from: IndexSet, to: Int) { snapshot(); clips.move(fromOffsets: from, toOffset: to) }
    func removeSelected() { guard let id = selectedID, let i = clips.firstIndex(where: {$0.id == id}) else { return }; snapshot(); clips.remove(at: i); selectedID = clips.indices.contains(i) ? clips[i].id : clips.last?.id }
    func snapshot() { undoStack.append(clips); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = []; hasUnsavedChanges = true }
    func undo() { guard let old = undoStack.popLast() else { return }; redoStack.append(clips); clips = old; selectedID = clips.first?.id; hasUnsavedChanges = true }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(clips); clips = next; selectedID = clips.first?.id; hasUnsavedChanges = true }
    func requestExport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = outputFormat == .instagram ? "My Reel.mp4" : "My YouTube Video.mp4"
        if panel.runModal() == .OK, let url = panel.url { export(to: url) }
    }
    func export(to url: URL) {
        guard !clips.isEmpty else { return }; exportState = .exporting(0)
        let selectedOutputFormat = outputFormat
        Task {
            do { let output = try await exporter.export(clips: clips, outputFormat: selectedOutputFormat, to: url) { progress in Task { @MainActor in self.exportState = .exporting(progress) } }; exportState = .success(output) }
            catch { exportState = .failure("Your video couldn’t be exported. Check that the destination has free space and try again.") }
        }
    }
    @discardableResult
    func saveProject() -> Bool {
        if let projectURL { return writeProject(to: projectURL) }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Untitled.zack"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writeProject(to: url)
    }
    private func writeProject(to url: URL) -> Bool {
        do {
            try JSONEncoder().encode(ZackProject(clips: clips, subtitles: subtitles, subtitleStyle: subtitleStyle, subtitleLayout: subtitleLayout, outputFormat: outputFormat)).write(to: url)
            projectURL = url
            hasUnsavedChanges = false
            return true
        } catch {
            errorMessage = "Your project couldn’t be saved. \(error.localizedDescription)"
            return false
        }
    }
    func openProject() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "zack")!]; if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let project = try? JSONDecoder().decode(ZackProject.self, from: data) { clips = project.clips; subtitles = project.subtitles; subtitleStyle = project.subtitleStyle; subtitleLayout = project.subtitleLayout; outputFormat = project.outputFormat; isSubtitleLayoutEditorVisible = false; isAudioEditorVisible = false; selectedID = clips.first?.id; projectURL = url; hasUnsavedChanges = false } }
}
