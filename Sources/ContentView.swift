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
                    Image(nsImage: ZackBranding.icon).resizable().frame(width: 20, height: 20)
                    Text("Zack").fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .primaryAction) { Button { project.importVideos() } label: { Label("Import", systemImage: "plus") }.help("Import videos") }
            ToolbarItem(placement: .primaryAction) { Button { project.isAudioEditorVisible.toggle() } label: { Label(project.isAudioEditorVisible ? "Hide audio" : "Adjust audio", systemImage: "speaker.wave.2") }.disabled(project.selectedClip == nil).help("Show or hide clip audio controls") }
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
                if project.isAudioEditorVisible, project.selectedClip != nil {
                    AudioEditor().frame(width: 270).frame(maxHeight: .infinity)
                }
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
                    GeometryReader { geometry in
                        SubtitleOverlay(text: subtitle.text, style: project.subtitleStyle)
                            .scaleEffect(project.subtitleLayout.scale)
                            .position(
                                x: geometry.size.width / 2 + CGFloat(project.subtitleLayout.horizontalOffset) * geometry.size.width,
                                y: geometry.size.height / 2 + CGFloat(project.subtitleLayout.verticalOffset) * geometry.size.height
                            )
                    }
                }
            }.aspectRatio(project.outputFormat.aspectRatio, contentMode: .fit).shadow(color: .black.opacity(0.12), radius: 14, y: 6)
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
        .onChange(of: project.clips) { _, _ in load() }
        .onChange(of: project.outputFormat) { _, _ in load() }
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
            player.volume = Float(clip.volume)
            player.seek(to: CMTime(seconds: clip.trimStart, preferredTimescale: 600))
            return
        }

        let clips = project.clips
        let outputFormat = project.outputFormat
        guard !clips.isEmpty else { player.replaceCurrentItem(with: nil); return }
        time = 0
        player.replaceCurrentItem(with: nil)
        Task {
            do {
                let timeline = try await TimelineCompositionService.make(clips: clips, outputFormat: outputFormat)
                guard loadToken == token else { return }
                let item = AVPlayerItem(asset: timeline.composition)
                item.videoComposition = timeline.videoComposition
                item.audioMix = timeline.audioMix
                player.replaceCurrentItem(with: item)
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

private struct AudioEditor: View {
    @EnvironmentObject private var project: ProjectStore
    private let levelAnalyzer = AudioLevelAnalysisService()
    @State private var sourcePeakDecibels: Double?
    @State private var isAnalyzingLevel = false

    private var selectedClip: VideoClip? { project.selectedClip }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio").font(.headline)
                    Text(selectedClip?.name ?? "No clip selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { project.isAudioEditorVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Hide audio controls")
            }
            .padding(12)
            Divider().padding(.horizontal, 12)

            if let clip = selectedClip {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 16) {
                        VolumeMeter(outputPeakDecibels: outputPeakDecibels(for: clip))
                            .frame(width: 42, height: 170)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Output peak").font(.subheadline.weight(.semibold))
                            Text(outputPeakLabel(for: clip))
                                .font(.title2.weight(.bold).monospacedDigit())
                                .foregroundStyle(outputColor(for: clip))
                            Text(outputDescription(for: clip))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(spacing: 5) {
                        HStack {
                            Text("Clip gain").font(.caption.weight(.medium))
                            Spacer()
                            Text("\(Int((clip.volume * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { selectedClip?.volume ?? 1 },
                            set: { project.updateClipVolume(id: clip.id, volume: $0) }
                        ), in: 0...2)
                        .tint(.orange)
                        HStack {
                            Text("Mute").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("Original 100%").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("200%").font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("Reset to original") { project.updateClipVolume(id: clip.id, volume: 1) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Text("Green is the usual range")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                        Text("Zack measures the loudest sample in this trimmed clip, then applies its gain. Keep the resulting peak below the -1 dB safe ceiling; yellow and red can distort.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
            Spacer()
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .task(id: analysisID) {
            guard let clip = selectedClip else {
                sourcePeakDecibels = nil
                return
            }
            isAnalyzingLevel = true
            sourcePeakDecibels = await levelAnalyzer.peakDecibels(for: clip)
            isAnalyzingLevel = false
        }
    }

    private var analysisID: String {
        guard let clip = selectedClip else { return "none" }
        return "\(clip.id.uuidString)-\(clip.trimStart)-\(clip.trimEnd)"
    }

    private func outputPeakDecibels(for clip: VideoClip) -> Double? {
        guard let sourcePeakDecibels else { return nil }
        guard clip.volume > 0 else { return -80 }
        return min(12, sourcePeakDecibels + 20 * log10(clip.volume))
    }

    private func outputColor(for clip: VideoClip) -> Color {
        guard let outputPeak = outputPeakDecibels(for: clip) else { return .secondary }
        switch outputPeak {
        case ..<(-24): return .secondary
        case ..<(-3): return .green
        case ..<(-1): return .yellow
        default: return .red
        }
    }

    private func outputPeakLabel(for clip: VideoClip) -> String {
        if isAnalyzingLevel { return "Checking…" }
        guard let peak = outputPeakDecibels(for: clip) else { return "No audio" }
        if peak <= -79 { return "Muted" }
        return String(format: "%.1f dB", peak)
    }

    private func outputDescription(for clip: VideoClip) -> String {
        if isAnalyzingLevel { return "Measuring this clip’s audio" }
        guard let outputPeak = outputPeakDecibels(for: clip) else { return "This clip has no readable audio track" }
        switch outputPeak {
        case ..<(-24): return "Very quiet output"
        case ..<(-3): return "Healthy output range"
        case ..<(-1): return "Close to the safe ceiling"
        default: return "May clip or distort"
        }
    }
}

private struct VolumeMeter: View {
    let outputPeakDecibels: Double?
    private let segmentCount = 14

    var body: some View {
        VStack(spacing: 3) {
            ForEach(Array((0..<segmentCount).reversed()), id: \.self) { index in
                let threshold = Double(index + 1) / Double(segmentCount)
                RoundedRectangle(cornerRadius: 2)
                    .fill(fillFraction >= threshold ? color(for: index) : Color.primary.opacity(0.10))
                    .frame(height: 9)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .frame(height: 1)
                .padding(.bottom, 6 + 6 * 3 + 9 * 6)
        }
        .accessibilityLabel(accessibilityDescription)
    }

    private var fillFraction: Double {
        guard let outputPeakDecibels else { return 0 }
        // Map -48 dB through 0 dB (the digital clipping point) to the meter.
        return min(max((outputPeakDecibels + 48) / 48, 0), 1)
    }

    private var accessibilityDescription: String {
        guard let outputPeakDecibels else { return "Audio output meter is unavailable" }
        return String(format: "Audio output peak is %.1f decibels", outputPeakDecibels)
    }

    private func color(for index: Int) -> Color {
        switch index {
        case 0...7: .green
        case 8...10: .yellow
        default: .red
        }
    }
}

private struct InlineSubtitleEditor: View {
    @EnvironmentObject private var project: ProjectStore
    @FocusState.Binding var focusedField: SubtitleField?
    @State private var isStylePickerVisible = false
    @State private var isCueEditorVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Subtitles").font(.headline)
                    Text("Edits update the full-video preview immediately.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { project.isSubtitleEditorVisible = false; project.isSubtitleLayoutEditorVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Hide subtitle editor")
            }
            .padding(12)
            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isStylePickerVisible.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("Caption style").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(project.subtitleStyle.name).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: isStylePickerVisible ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show caption style options")

                if isStylePickerVisible {
                    SubtitleStylePicker()
                }
            }
            .padding(12)
            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    project.isSubtitleLayoutEditorVisible.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("Caption layout").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(project.isSubtitleLayoutEditorVisible ? "Editing" : "Size & position")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: project.isSubtitleLayoutEditorVisible ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if project.isSubtitleLayoutEditorVisible {
                    SubtitleLayoutEditor()
                }
            }
            .padding(12)
            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isCueEditorVisible.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("Caption text & timing").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(project.subtitles.count) cues").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: isCueEditorVisible ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isCueEditorVisible {
                    List {
                        ForEach(project.subtitles) { cue in
                            SubtitleEditorRow(cue: cue, focusedField: $focusedField)
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 320)
                }
            }
            .padding(12)
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SubtitleStylePicker: View {
    @EnvironmentObject private var project: ProjectStore
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(SubtitleStyle.allCases) { style in
                        Button {
                            project.updateSubtitleStyle(style)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                SubtitleStyleSwatch(style: style)
                                    .frame(height: 46)
                                Text(style.name).font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                            .background(
                                project.subtitleStyle == style ? Color.orange.opacity(0.16) : Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(project.subtitleStyle == style ? Color.orange : Color.primary.opacity(0.10), lineWidth: project.subtitleStyle == style ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(style.detail)
                        .accessibilityLabel("Use \(style.name) caption style")
                    }
                }
            }
            .frame(maxHeight: 270)
        }
    }
}

private struct SubtitleStyleSwatch: View {
    let style: SubtitleStyle

    var body: some View {
        ZStack {
            swatchCanvas
            SubtitleOverlay(text: sampleText, style: style, compact: true)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var swatchCanvas: some View {
        switch style {
        case .classic, .creator, .cinema, .outline:
            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.85))
        case .zack:
            RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [.black, .orange.opacity(0.72), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .comic:
            RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [.blue.opacity(0.92), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .sticker:
            RoundedRectangle(cornerRadius: 5).fill(.yellow.opacity(0.92))
        case .chalk:
            RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.08, green: 0.22, blue: 0.16))
        case .neon:
            RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [.indigo, .purple.opacity(0.85), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .arcade:
            RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [.black, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var sampleText: String {
        switch style {
        case .classic: "Just like this"
        case .creator: "CREATE MORE"
        case .zack: "ZACK"
        case .comic: "POW!"
        case .sticker: "WOW"
        case .chalk: "make a mark"
        case .cinema: "THE BIG IDEA"
        case .neon: "NO LIMITS"
        case .outline: "SAY IT LOUD"
        case .arcade: "LEVEL UP"
        }
    }
}

private struct SubtitleOverlay: View {
    let text: String
    let style: SubtitleStyle
    var compact = false

    private var size: CGFloat { compact ? 12 : 22 }

    var body: some View {
        switch style {
        case .classic:
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 6 : 14)
                .padding(.vertical, compact ? 3 : 8)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: compact ? 4 : 7))
        case .creator:
            Text(text)
                .font(.custom("Montserrat-Bold", size: size))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.88), radius: compact ? 1.5 : 3, x: 0, y: compact ? 1 : 2)
        case .zack:
            ZStack {
                Text(text.uppercased())
                    .font(.custom("Bungee-Regular", size: compact ? size + 2 : size + 7))
                    .foregroundStyle(.red.opacity(0.92))
                    .offset(x: compact ? 2 : 4, y: compact ? 2 : 4)
                Text(text.uppercased())
                    .font(.custom("Bungee-Regular", size: compact ? size + 2 : size + 7))
                    .foregroundStyle(.orange)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, compact ? 6 : 15)
            .padding(.vertical, compact ? 3 : 8)
            .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: compact ? 4 : 8))
            .overlay(RoundedRectangle(cornerRadius: compact ? 4 : 8).stroke(.orange, lineWidth: compact ? 1 : 2))
            .shadow(color: .orange.opacity(0.62), radius: compact ? 2 : 5)
        case .comic:
            ZStack {
                Text(text)
                    .font(.custom("Bangers-Regular", size: compact ? size + 4 : size + 10))
                    .foregroundStyle(.red)
                    .offset(x: compact ? 2 : 4, y: compact ? 2 : 4)
                Text(text)
                    .font(.custom("Bangers-Regular", size: compact ? size + 4 : size + 10))
                    .foregroundStyle(.yellow)
            }
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.85), radius: compact ? 1 : 3)
        case .sticker:
            Text(text)
                .font(.custom("LuckiestGuy-Regular", size: compact ? size + 1 : size + 5))
                .multilineTextAlignment(.center)
                .foregroundStyle(.purple)
                .padding(.horizontal, compact ? 7 : 17)
                .padding(.vertical, compact ? 4 : 10)
                .background(.white, in: RoundedRectangle(cornerRadius: compact ? 7 : 15))
                .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 15).stroke(.yellow, lineWidth: compact ? 2 : 5))
                .rotationEffect(.degrees(compact ? -3 : -4))
                .shadow(color: .black.opacity(0.60), radius: compact ? 1 : 3, x: compact ? 1 : 3, y: compact ? 2 : 5)
        case .chalk:
            Text(text)
                .font(.custom("RockSalt-Regular", size: compact ? size - 1 : size - 2))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, compact ? 6 : 14)
                .padding(.vertical, compact ? 3 : 8)
                .background(Color(red: 0.06, green: 0.20, blue: 0.14).opacity(0.94), in: RoundedRectangle(cornerRadius: compact ? 4 : 7))
                .overlay(RoundedRectangle(cornerRadius: compact ? 4 : 7).stroke(.white.opacity(0.20), lineWidth: 1))
        case .cinema:
            Text(text)
                .font(.custom("DMSerifDisplay-Regular", size: compact ? size + 1 : size + 4))
                .multilineTextAlignment(.center)
                .tracking(compact ? 0.5 : 1.5)
                .foregroundStyle(Color(red: 0.96, green: 0.80, blue: 0.42))
                .padding(.horizontal, compact ? 7 : 18)
                .padding(.vertical, compact ? 4 : 10)
                .background(.black.opacity(0.94), in: Rectangle())
                .overlay(Rectangle().stroke(Color(red: 0.96, green: 0.80, blue: 0.42).opacity(0.7), lineWidth: 1))
        case .neon:
            Text(text)
                .font(.custom("Monoton-Regular", size: compact ? size - 1 : size + 1))
                .multilineTextAlignment(.center)
                .foregroundStyle(.pink)
                .shadow(color: .cyan.opacity(0.95), radius: compact ? 2 : 6)
                .shadow(color: .pink.opacity(0.80), radius: compact ? 3 : 10)
        case .outline:
            Text(text)
                .font(.custom("Montserrat-Black", size: size))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0, x: compact ? 1 : 2, y: 0)
                .shadow(color: .black, radius: 0, x: compact ? -1 : -2, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: compact ? 1 : 2)
                .shadow(color: .black, radius: 0, x: 0, y: compact ? -1 : -2)
        case .arcade:
            Text(text)
                .font(.custom("PressStart2P-Regular", size: compact ? size - 4 : size - 7))
                .multilineTextAlignment(.center)
                .foregroundStyle(.green)
                .padding(.horizontal, compact ? 6 : 14)
                .padding(.vertical, compact ? 5 : 11)
                .background(.black.opacity(0.92), in: Rectangle())
                .overlay(Rectangle().stroke(Color(red: 1, green: 0, blue: 1), lineWidth: compact ? 1 : 3))
                .shadow(color: .cyan.opacity(0.85), radius: 0, x: compact ? 1 : 3, y: compact ? 1 : 3)
        }
    }
}

/// The caption can be laid out directly on the video when Caption layout is
/// expanded. Its coordinates stay proportional to the player, so they remain
/// correct across window sizes and are stored with the project.
private struct SubtitleLayoutEditor: View {
    @EnvironmentObject private var project: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Adjust the sliders while watching the live preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
            layoutSlider("Size", value: Binding(
                get: { project.subtitleLayout.scale },
                set: { project.updateSubtitleLayout(scale: $0) }
            ), range: 0.55...2.1, valueLabel: "\(Int(project.subtitleLayout.scale * 100))%")
            layoutSlider("Left / right", value: Binding(
                get: { project.subtitleLayout.horizontalOffset },
                set: { project.updateSubtitleLayout(horizontalOffset: $0) }
            ), range: -0.42...0.42, valueLabel: "\(Int(project.subtitleLayout.horizontalOffset * 100))%")
            layoutSlider("Up / down", value: Binding(
                get: { project.subtitleLayout.verticalOffset },
                set: { project.updateSubtitleLayout(verticalOffset: $0) }
            ), range: -0.45...0.45, valueLabel: "\(Int(project.subtitleLayout.verticalOffset * 100))%")
            Button("Reset layout") { project.resetSubtitleLayout() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func layoutSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueLabel: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text(valueLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).tint(.orange)
        }
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
    @State private var draggedClipID: UUID?
    @State private var insertion: TimelineInsertion?

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
                        ClipTile(
                            clip: clip,
                            index: index,
                            showInsertionBefore: insertion?.targetID == clip.id && insertion?.placeAfter == false,
                            showInsertionAfter: insertion?.targetID == clip.id && insertion?.placeAfter == true
                        )
                        .onDrag {
                            draggedClipID = clip.id
                            return NSItemProvider(object: clip.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: ClipDropDelegate(
                            target: clip,
                            targetWidth: ClipTile.displayWidth(for: clip),
                            project: project,
                            draggedClipID: $draggedClipID,
                            insertion: $insertion
                        ))
                    }
                    Button { project.importVideos() } label: { Image(systemName: "plus").font(.title3).frame(width: 48, height: 122).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).help("Import more clips")
                }.padding(.vertical, 3)
            }
        }.padding(.vertical, 14)
    }
}

private struct TimelineInsertion: Equatable {
    let targetID: UUID
    let placeAfter: Bool
}

private struct ClipTile: View {
    @EnvironmentObject private var project: ProjectStore
    let clip: VideoClip
    let index: Int
    let showInsertionBefore: Bool
    let showInsertionAfter: Bool
    private var isSelected: Bool { project.selectedID == clip.id }
    static func displayWidth(for clip: VideoClip) -> CGFloat { CGFloat(max(152, min(275, clip.duration * 12 + 120))) }
    private var width: CGFloat { Self.displayWidth(for: clip) }
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
            }
            .frame(width: width, height: 91)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.orange : .clear, lineWidth: 3))
            .overlay(alignment: .leading) {
                if showInsertionBefore { insertionMarker }
            }
            .overlay(alignment: .trailing) {
                if showInsertionAfter { insertionMarker }
            }
            Text("\(clip.trimStart.timeLabel) — \(clip.trimEnd.timeLabel)").font(.caption2).monospacedDigit().foregroundStyle(isSelected ? .orange : .secondary)
        }.contentShape(Rectangle()).onTapGesture { project.select(clip.id) }
    }

    private var insertionMarker: some View {
        Capsule()
            .fill(Color.orange)
            .frame(width: 5, height: 106)
            .shadow(color: .orange.opacity(0.75), radius: 5)
            .offset(x: showInsertionBefore ? -5 : 5)
    }
}

private struct ClipDropDelegate: DropDelegate {
    let target: VideoClip
    let targetWidth: CGFloat
    let project: ProjectStore
    @Binding var draggedClipID: UUID?
    @Binding var insertion: TimelineInsertion?

    func dropEntered(info: DropInfo) { updateInsertion(for: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertion(for: info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if insertion?.targetID == target.id { insertion = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        guard let sourceID = draggedClipID else { return false }
        let placeAfter = insertion?.targetID == target.id ? insertion?.placeAfter ?? false : info.location.x > targetWidth / 2
        insertion = nil
        draggedClipID = nil
        Task { @MainActor in
            guard let from = project.clips.firstIndex(where: { $0.id == sourceID }),
                  let to = project.clips.firstIndex(where: { $0.id == target.id }),
                  from != to else { return }
            let destination = placeAfter ? to + 1 : to
            guard destination != from else { return }
            project.move(from: IndexSet(integer: from), to: destination)
        }
        return true
    }

    private func updateInsertion(for info: DropInfo) {
        guard let sourceID = draggedClipID, sourceID != target.id else {
            insertion = nil
            return
        }
        insertion = TimelineInsertion(targetID: target.id, placeAfter: info.location.x > targetWidth / 2)
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
