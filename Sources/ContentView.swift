import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var project: ProjectStore
    @State private var isDropTarget = false

    var body: some View {
        Group {
            if project.clips.isEmpty { EmptyState(isTargeted: $isDropTarget) }
            else { EditorView() }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.movie, .mpeg4Movie, .quickTimeMovie], isTargeted: $isDropTarget) { providers in
            let ids = providers.map { provider in provider.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { project.add(urls: [url]) } } }; return true }; return ids.contains(true)
        }
        .alert("Something needs attention", isPresented: Binding(get: { project.errorMessage != nil }, set: { if !$0 { project.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(project.errorMessage ?? "") }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                    Text("Zack").fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .primaryAction) { Button { project.importVideos() } label: { Label("Import", systemImage: "plus") }.help("Import videos") }
            ToolbarItem(placement: .primaryAction) { Button { project.requestSubtitles() } label: { Label("Generate subtitles", systemImage: "captions.bubble") }.disabled(project.clips.isEmpty || project.isGeneratingSubtitles).help("Transcribe the full video with Whisper") }
            ToolbarItem(placement: .primaryAction) { Button { project.isSubtitleEditorVisible.toggle() } label: { Label(project.isSubtitleEditorVisible ? "Hide subtitles" : "Edit subtitles", systemImage: "text.bubble") }.disabled(project.subtitles.isEmpty).help("Show or hide the subtitle editor") }
            ToolbarItem(placement: .primaryAction) { Button { project.requestExport() } label: { Label("Export video", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent).tint(.orange).disabled(project.clips.isEmpty) }
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var project: ProjectStore
    @Binding var isTargeted: Bool
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(isTargeted ? Color.orange.opacity(0.12) : Color.primary.opacity(0.035))
                RoundedRectangle(cornerRadius: 24).strokeBorder(isTargeted ? Color.orange : Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [8, 7]))
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 42)).foregroundStyle(.orange)
                    Text("Create your video").font(.system(size: 25, weight: .semibold))
                    Text("Drop video clips here, choose them from your Mac, or open an existing project.").foregroundStyle(.secondary)
                    Button("Import videos") { project.importVideos() }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.large).padding(.top, 4)
                    Button("Open existing project…") { project.openProject() }
                        .buttonStyle(.bordered)
                    Text("MP4, MOV, and M4V").font(.caption).foregroundStyle(.tertiary)
                }
            }.frame(width: 520, height: 295)
            Spacer()
            Text("Everything stays on your Mac.").font(.caption).foregroundStyle(.tertiary).padding(.bottom, 30)
        }.padding()
    }
}

private struct EditorView: View {
    @EnvironmentObject private var project: ProjectStore
    @FocusState private var focusedSubtitleField: SubtitleField?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                PreviewPane().frame(maxWidth: .infinity, maxHeight: .infinity)
                if project.isSubtitleEditorVisible, !project.subtitles.isEmpty {
                    InlineSubtitleEditor(focusedField: $focusedSubtitleField).frame(width: 330).frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 12)
            Divider().padding(.top, 16)
            TimelineView().frame(height: 206).padding(.horizontal, 25)
            Footer().padding(.horizontal, 30).padding(.vertical, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A click away from a subtitle field leaves the panel open, but
            // returns keyboard commands such as Space to the editor.
            focusedSubtitleField = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

private struct PreviewPane: View {
    @EnvironmentObject private var project: ProjectStore

    private enum PreviewMode: String, CaseIterable, Identifiable {
        case fullVideo = "Full Video"
        case selected = "Selected"

        var id: Self { self }
    }

    @State private var mode: PreviewMode = .fullVideo
    @State private var player = AVPlayer()
    @State private var time: Double = 0
    @State private var playing = false
    @State private var timer: Timer?
    @State private var loadToken = UUID()

    private var selectedClip: VideoClip? { project.selectedClip }
    private var duration: Double {
        mode == .selected ? (selectedClip?.duration ?? 0) : project.clips.reduce(0) { $0 + $1.duration }
    }
    private var sliderRange: ClosedRange<Double> {
        if mode == .selected, let clip = selectedClip { return 0...clip.sourceDuration }
        return 0...duration
    }

    var body: some View {
        VStack(spacing: 11) {
            Picker("", selection: $mode) {
                ForEach(PreviewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(.orange)
            .frame(width: 220)
            .accessibilityLabel("Video preview mode")

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.9))
                if selectedClip != nil { PlayerSurface(player: player).clipShape(RoundedRectangle(cornerRadius: 12)) } else { Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.4)) }
                if mode == .fullVideo, let subtitle = project.subtitle(at: time) {
                    VStack {
                        Spacer()
                        Text(subtitle.text)
                            .font(.system(size: 22, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                            .padding(.horizontal, 32)
                            .padding(.bottom, 28)
                    }
                }
            }.aspectRatio(16/8.6, contentMode: .fit).shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            if duration > 0 {
                HStack(spacing: 12) {
                    Button { toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 17) }.buttonStyle(.plain)
                    if mode == .selected, let clip = selectedClip {
                        VideoTrimControl(clip: clip, time: $time) { seek(to: $0) }
                    } else {
                        Slider(value: $time, in: sliderRange, onEditingChanged: { if !$0 { seek(to: time) } }).tint(.orange)
                    }
                    Text(time.timeLabel).monospacedDigit().foregroundStyle(.secondary)
                    Text("/ \(sliderRange.upperBound.timeLabel)").monospacedDigit().foregroundStyle(.tertiary)
                }.font(.caption).padding(.horizontal, 4)
            }
        }
        .onChange(of: mode) { _, _ in load() }
        .onChange(of: project.selectedID) { _, _ in if mode == .selected { load() } }
        .onChange(of: project.clips) { _, _ in if mode == .fullVideo { load() } }
        .onChange(of: project.playbackToggleCount) { _, _ in toggle() }
        .onAppear { load() }
        .onDisappear { stop() }
    }
    private func load() {
        stop()
        let token = UUID()
        loadToken = token

        if mode == .selected {
            guard let clip = selectedClip else { player.replaceCurrentItem(with: nil); return }
            time = clip.trimStart
            player.replaceCurrentItem(with: AVPlayerItem(url: clip.sourceURL))
            player.seek(to: CMTime(seconds: clip.trimStart, preferredTimescale: 600))
            return
        }

        let clips = project.clips
        guard !clips.isEmpty else { player.replaceCurrentItem(with: nil); return }
        time = 0
        player.replaceCurrentItem(with: nil)
        Task {
            do {
                let composition = try await VideoPreviewCompositionService.make(clips: clips)
                guard loadToken == token else { return }
                player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            } catch {
                guard loadToken == token else { return }
                project.errorMessage = "The full video preview couldn’t be created. Check that all clips are still available."
            }
        }
    }
    private func stop() { timer?.invalidate(); timer = nil; player.pause(); playing = false }
    private func seek(to seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    private func toggle() {
        if playing { stop(); return }
        if mode == .selected, let clip = selectedClip, time < clip.trimStart || time >= clip.trimEnd {
            seek(to: clip.trimStart)
        }
        player.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [self] _ in
            Task { @MainActor in
                time = player.currentTime().seconds
                let endTime = mode == .selected ? (selectedClip?.trimEnd ?? sliderRange.upperBound) : sliderRange.upperBound
                if time >= endTime { stop() }
            }
        }
    }
}

/// A timeline-style trim control for the selected source video. The full source
/// remains visible, while the orange handles define the portion that will play.
private struct VideoTrimControl: View {
    @EnvironmentObject private var project: ProjectStore
    let clip: VideoClip
    @Binding var time: Double
    let onSeek: (Double) -> Void
    @State private var startAtDrag: Double?
    @State private var endAtDrag: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let sourceDuration = max(clip.sourceDuration, 0.1)
            let startX = width * clip.trimStart / sourceDuration
            let endX = width * clip.trimEnd / sourceDuration
            let playheadX = width * min(max(time, 0), clip.sourceDuration) / sourceDuration

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13)).frame(height: 7)
                Capsule().fill(Color.orange.opacity(0.38)).frame(width: max(0, endX - startX), height: 7).offset(x: startX)
                Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: 20).offset(x: playheadX - 1)
                trimHandle(at: startX, isStart: true, width: width, sourceDuration: sourceDuration)
                trimHandle(at: endX, isStart: false, width: width, sourceDuration: sourceDuration)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                onSeek(min(max(0, Double(location.x / width) * sourceDuration), clip.sourceDuration))
            }
        }
        .frame(height: 28)
        .accessibilityLabel("Video trim range")
    }

    @ViewBuilder
    private func trimHandle(at position: CGFloat, isStart: Bool, width: CGFloat, sourceDuration: Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.orange)
            .frame(width: 7, height: 26)
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
            .offset(x: min(max(-10, position - 10), width - 10))
            .highPriorityGesture(DragGesture().onChanged { value in
                let delta = Double(value.translation.width / width) * sourceDuration
                if isStart {
                    if startAtDrag == nil { startAtDrag = clip.trimStart; project.snapshot() }
                    project.updateTrim(id: clip.id, start: (startAtDrag ?? clip.trimStart) + delta)
                } else {
                    if endAtDrag == nil { endAtDrag = clip.trimEnd; project.snapshot() }
                    project.updateTrim(id: clip.id, end: (endAtDrag ?? clip.trimEnd) + delta)
                }
            }.onEnded { _ in
                if isStart { startAtDrag = nil } else { endAtDrag = nil }
            })
            .help(isStart ? "Drag to set clip start" : "Drag to set clip end")
    }
}

private enum SubtitleField: Hashable {
    case start(UUID), end(UUID), text(UUID)
}

private struct InlineSubtitleEditor: View {
    @EnvironmentObject private var project: ProjectStore
    @FocusState.Binding var focusedField: SubtitleField?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Subtitles").font(.headline)
                    Text("Edits update the full-video preview immediately.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { project.isSubtitleEditorVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Hide subtitle editor")
            }
            .padding(12)
            Divider().padding(.horizontal, 12)
            List {
                ForEach(project.subtitles) { cue in
                    SubtitleEditorRow(cue: cue, focusedField: $focusedField)
                }
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SubtitleEditorRow: View {
    @EnvironmentObject private var project: ProjectStore
    let cue: SubtitleCue
    @FocusState.Binding var focusedField: SubtitleField?
    @State private var startText: String
    @State private var endText: String

    init(cue: SubtitleCue, focusedField: FocusState<SubtitleField?>.Binding) {
        self.cue = cue
        _focusedField = focusedField
        _startText = State(initialValue: cue.startTime.editableTimeLabel)
        _endText = State(initialValue: cue.endTime.editableTimeLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                TextField("Start", text: $startText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .focused($focusedField, equals: .start(cue.id))
                Text("–").foregroundStyle(.secondary)
                TextField("End", text: $endText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .focused($focusedField, equals: .end(cue.id))
            }
            .font(.caption.monospacedDigit())
            TextField("Subtitle", text: Binding(
                get: { project.subtitles.first(where: { $0.id == cue.id })?.text ?? "" },
                set: { project.updateSubtitle(id: cue.id, text: $0) }
            ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .focused($focusedField, equals: .text(cue.id))
        }
        .padding(.vertical, 3)
        .onSubmit(applyTiming)
        .onChange(of: focusedField) { oldValue, newValue in
            let wasEditingTiming = oldValue == .start(cue.id) || oldValue == .end(cue.id)
            if wasEditingTiming && oldValue != newValue {
                applyTiming()
            }
        }
    }

    private func applyTiming() {
        guard let start = Double.subtitleTime(from: startText),
              let end = Double.subtitleTime(from: endText),
              project.updateSubtitleTiming(id: cue.id, start: start, end: end) else {
            if let currentCue = project.subtitles.first(where: { $0.id == cue.id }) {
                startText = currentCue.startTime.editableTimeLabel
                endText = currentCue.endTime.editableTimeLabel
            }
            return
        }
        startText = start.editableTimeLabel
        endText = end.editableTimeLabel
    }
}

/// A minimal AppKit player surface. Using AVPlayerLayer directly avoids SwiftUI's
/// AVPlayerView bridge, which is unstable in the current macOS 26 runtime.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

private final class PlayerLayerView: NSView {
    private let videoLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = videoLayer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = videoLayer
    }

    var playerLayer: AVPlayerLayer { videoLayer }
    override func layout() { super.layout(); playerLayer.videoGravity = .resizeAspect }
}

private struct TimelineView: View {
    @EnvironmentObject private var project: ProjectStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timeline").font(.headline)
                Text("\(project.clips.count) \(project.clips.count == 1 ? "clip" : "clips")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let clip = project.selectedClip { Text("Selected: \(clip.name) · \(clip.duration.timeLabel)").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(project.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipTile(clip: clip, index: index)
                            .onDrag { NSItemProvider(object: clip.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: ClipDropDelegate(target: clip, project: project))
                    }
                    Button { project.importVideos() } label: { Image(systemName: "plus").font(.title3).frame(width: 48, height: 122).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).help("Import more clips")
                }.padding(.vertical, 3)
            }
        }.padding(.vertical, 14)
    }
}

private struct ClipTile: View {
    @EnvironmentObject private var project: ProjectStore
    let clip: VideoClip
    let index: Int
    private var isSelected: Bool { project.selectedID == clip.id }
    private var width: CGFloat { CGFloat(max(152, min(275, clip.duration * 12 + 120))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(hue: Double((index * 47) % 360) / 360, saturation: 0.35, brightness: 0.42), Color.black.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(alignment: .top) {
                    Text("\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.85)).padding(7)
                    Spacer(); Image(systemName: "film").foregroundStyle(.white.opacity(0.55)).padding(7)
                }
                HStack {
                    Text(clip.name)
                        .lineLimit(1)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 22)
                }
                .padding(.leading, 15)
                .padding(.trailing, 10)
                .padding(.bottom, 8)
            }.frame(width: width, height: 91).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.orange : .clear, lineWidth: 3))
            Text("\(clip.trimStart.timeLabel) — \(clip.trimEnd.timeLabel)").font(.caption2).monospacedDigit().foregroundStyle(isSelected ? .orange : .secondary)
        }.contentShape(Rectangle()).onTapGesture { project.select(clip.id) }
    }
}

private struct ClipDropDelegate: DropDelegate {
    let target: VideoClip
    let project: ProjectStore
    func dropEntered(info: DropInfo) { }
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let idString = item as? String, let sourceID = UUID(uuidString: idString), let from = project.clips.firstIndex(where: { $0.id == sourceID }), let to = project.clips.firstIndex(where: { $0.id == target.id }), from != to else { return }
            DispatchQueue.main.async { project.move(from: IndexSet(integer: from), to: to > from ? to + 1 : to) }
        }
        return true
    }
}

private struct Footer: View {
    @EnvironmentObject private var project: ProjectStore
    var body: some View {
        HStack {
            if project.isImporting { ProgressView().controlSize(.small); Text("Reading your clips…").font(.caption).foregroundStyle(.secondary) }
            else { Text("\(project.clips.reduce(0) { $0 + $1.duration }.timeLabel) total").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            switch project.exportState {
            case .idle: Text("Ready to make something.").font(.caption).foregroundStyle(.tertiary)
            case .exporting(let p): ProgressView(value: p).frame(width: 160); Text("Exporting \(Int(p * 100))%") .font(.caption).monospacedDigit()
            case .success(let url): Label("Exported successfully", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption); Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link); Button("Done") { project.exportState = .idle }.buttonStyle(.link)
            case .failure(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption); Button("Dismiss") { project.exportState = .idle }.buttonStyle(.link)
            }
            switch project.subtitleState {
            case .idle:
                EmptyView()
            case .rendering:
                ProgressView().controlSize(.small)
                Text("Rendering full video for subtitles…").font(.caption).foregroundStyle(.secondary)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing full video with Whisper…").font(.caption).foregroundStyle(.secondary)
            case .success(let url):
                Label("Subtitles ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Button("Show SRT") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                Button("Dismiss") { project.subtitleState = .idle }.buttonStyle(.link)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                Button("Dismiss") { project.subtitleState = .idle }.buttonStyle(.link)
            }
        }
    }
}
