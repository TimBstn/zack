import SwiftUI
import AppKit

enum ZackBranding {
    static let icon: NSImage = {
        let bundledIcon = Bundle.main.url(forResource: "Zack", withExtension: "icns")
        let developmentIcon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Branding/Zack.icns")
        for url in [bundledIcon, developmentIcon] {
            if let url, let image = NSImage(contentsOf: url) { return image }
        }
        return NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Zack") ?? NSImage()
    }()
}

@main
struct ZackApp: App {
    @NSApplicationDelegateAdaptor(ZackAppDelegate.self) private var appDelegate
    @StateObject private var project = ProjectStore()
    @State private var showAbout = false
    @State private var showHelp = false
    @State private var showShortcuts = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(project)
                .frame(minWidth: 860, minHeight: 650)
                .background(WindowCloseGuard(project: project))
                .sheet(isPresented: $showAbout) { AboutView() }
                .sheet(isPresented: $showHelp) { HelpView() }
                .sheet(isPresented: $showShortcuts) { ShortcutsView() }
                .onAppear { appDelegate.project = project }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Zack") { showAbout = true }
            }
            CommandGroup(replacing: .help) {
                Button("Zack Help") { showHelp = true }.keyboardShortcut("?", modifiers: [.command, .shift])
                Button("Keyboard Shortcuts") { showShortcuts = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { project.newProject() }.keyboardShortcut("n")
                Button("Open Project…") { project.openProject() }.keyboardShortcut("o")
                Divider()
                Button("Import Videos…") { project.importVideos() }.keyboardShortcut("i")
                Button("Export Video…") { project.requestExport() }.keyboardShortcut("e")
                    .disabled(project.clips.isEmpty)
            }
            CommandGroup(after: .saveItem) {
                Button("Save Project…") { project.saveProject() }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { project.undo() }.keyboardShortcut("z").disabled(!project.canUndo)
                Button("Redo") { project.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!project.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy Clip") { project.copySelectedClip() }.keyboardShortcut("c")
                    .disabled(project.selectedClip == nil)
                Button("Paste Clip") { project.pasteClip() }.keyboardShortcut("v")
                    .disabled(!project.canPasteClip)
                Divider()
                Button("Duplicate Clip") { project.duplicateSelectedClip() }.keyboardShortcut("d")
                    .disabled(project.selectedClip == nil)
                Divider()
                Button("Delete Clip") { project.removeSelected() }.keyboardShortcut(.delete, modifiers: [])
                    .disabled(project.selectedClip == nil)
            }
        }
        Settings { PreferencesView().environmentObject(project) }
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let project: ProjectStore

    func makeCoordinator() -> Coordinator { Coordinator(project: project) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        installDelegate(for: view, coordinator: context.coordinator)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        installDelegate(for: view, coordinator: context.coordinator)
    }
    private func installDelegate(for view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { view.window?.delegate = coordinator }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let project: ProjectStore
        init(project: ProjectStore) { self.project = project }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard project.hasUnsavedChanges else { return true }
            let alert = NSAlert()
            alert.messageText = "Save changes before closing?"
            alert.informativeText = "Your recent video edits and subtitle changes haven’t been saved to a project file."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don’t Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return project.saveProject()
            case .alertSecondButtonReturn: return true
            default: return false
            }
        }
    }
}

@MainActor
final class ZackAppDelegate: NSObject, NSApplicationDelegate {
    weak var project: ProjectStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // A process launched by `swift run` can otherwise inherit Terminal's
        // inactive state. Defer one run-loop turn so SwiftUI has created its window.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            self?.project?.togglePlayback()
            return nil
        }
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: ZackBranding.icon).resizable().frame(width: 60, height: 60)
            Text("Zack").font(.title2.weight(.semibold))
            Text("A simpler way to make a cut.").foregroundStyle(.secondary)
            Text("Tired of overpriced, overcomplicated video editing software? Zack is the slim, easy-to-use solution: just the tools you need to shape and share your video.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
            Text("Version 0.2.0").font(.caption).foregroundStyle(.tertiary)
            Text("© 2026 Zack Studio").font(.caption).foregroundStyle(.tertiary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 4)
        }.frame(width: 360, height: 270)
    }
}

private struct PreferencesView: View {
    @EnvironmentObject private var project: ProjectStore
    @AppStorage(SubtitleTranscriptionSettings.maximumCharactersKey) private var maximumCharacters = 15
    @AppStorage(SubtitleTranscriptionSettings.splitOnWordBoundariesKey) private var splitOnWordBoundaries = true

    var body: some View {
        TabView {
            Form {
                Section("Format") {
                    Picker("Video output", selection: Binding(
                        get: { project.outputFormat },
                        set: { project.updateOutputFormat($0) }
                    )) {
                        ForEach(VideoOutputFormat.allCases) { format in
                            Text("\(format.name) (\(format.detail))").tag(format)
                        }
                    }
                }
                Section {
                    Text("YouTube Video is 1920 × 1080 (16:9). Shorts & Reels is 1080 × 1920 (9:16), suitable for YouTube Shorts and Instagram Reels. Zack fits footage inside the selected frame and adds black bars instead of stretching it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Video", systemImage: "rectangle.on.rectangle") }

            Form {
                Section("Caption layout") {
                    Stepper(value: $maximumCharacters, in: 5...80) {
                        LabeledContent("Maximum characters per caption", value: "\(maximumCharacters)")
                    }
                    Toggle("Keep words together", isOn: $splitOnWordBoundaries)
                }
                Section {
                    Text("The character limit includes spaces and punctuation. These settings affect newly generated subtitles; existing captions remain unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Transcription") {
                    LabeledContent("Language", value: "English")
                    Text("Zack currently includes an English Whisper model. No separate installation is required.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Subtitles", systemImage: "captions.bubble") }
        }
        .frame(width: 500, height: 340)
    }
}

private struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zack Help").font(.title2.weight(.semibold))
                    Text("A quick guide to making a clean cut.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HelpSection("Start a project") {
                        Text("Import videos with the + button, File → Import Videos, or Command-I. You can also drag MP4, MOV, and M4V files into the editor. To resume work, choose Open existing project… on the start screen or File → Open Project.")
                    }
                    HelpSection("Arrange your video") {
                        Text("Click a clip in the timeline to select it. Drag the whole clip tile left or right to reorder it. Use Command-C and Command-V to copy and paste a selected clip, or Command-D to duplicate it immediately after itself.")
                    }
                    HelpSection("Adjust audio") {
                        Text("Select a clip, then click the speaker button in the toolbar to open Audio controls. Use the volume slider to adjust that clip from mute to 200%; 100% preserves its original level. Zack measures the clip’s actual output peak after gain, so quiet and loud source videos read differently. Keep the output below the -1 dB safe ceiling; yellow and red can distort. Audio settings are saved with the project and included in the exported MP4.")
                    }
                    HelpSection("Preview and trim") {
                        Text("Selected previews one source clip. Full Video previews the entire ordered, trimmed timeline. In Selected mode, drag the orange left and right cutters below the player to set the start and end of that clip. Click the trim bar to move the playhead. Press Space to play or pause.")
                    }
                    HelpSection("Video output") {
                        Text("Choose Zack → Settings → Video to select YouTube Video (1920 × 1080, 16:9) for regular YouTube uploads, or Shorts & Reels (1080 × 1920, 9:16) for YouTube Shorts and Instagram Reels. The choice changes the preview and exported MP4. Zack preserves each clip’s aspect ratio and adds black bars rather than stretching footage.")
                    }
                    HelpSection("Subtitles") {
                        Text("Click the captions button in the toolbar to generate subtitles for the full timeline with Zack’s bundled native Whisper engine and voice activity detection. No Python, Conda, or separate setup is required. Zack removes blank-audio markers from generated captions. Choose Zack → Settings → Subtitles to set the maximum characters per caption and whether captions should split on word boundaries. Zack saves an SRT in ~/Movies/Zack Subtitles and opens the inline subtitle editor. Choose a Caption style to change the full-video preview; Zack bundles its caption fonts so the look is consistent on every Mac. Open Caption layout to adjust size and position with sliders while watching the live preview. The selected style and layout are saved with your project. Switch to Full Video to see captions over the preview, then edit their text or Start and End times in the panel beside the player. Times accept 0:03.00, 1:02.50, or plain seconds and apply when you press Return or leave the field.")
                    }
                    HelpSection("Save and export") {
                        Text("Choose File → Save Project (Command-S) to save clips, trim ranges, audio levels, timeline order, video output, and subtitle edits in a .zack project. The orange Export button renders the full timeline as an MP4. When closing an unsaved project, Zack asks whether to save your changes.")
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 620, height: 650)
    }
}

private struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                    Text("The fastest way to work in Zack.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding()
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow("Command-I", "Import videos")
                ShortcutRow("Command-O", "Open project")
                ShortcutRow("Command-S", "Save project")
                ShortcutRow("Command-E", "Export full video")
                ShortcutRow("Command-C / Command-V", "Copy / paste selected clip")
                ShortcutRow("Command-D", "Duplicate selected clip")
                ShortcutRow("Delete", "Remove selected clip")
                ShortcutRow("Command-Z / Shift-Command-Z", "Undo / redo")
                ShortcutRow("Space", "Play / pause preview")
            }
            .padding(22)
            Spacer()
        }
        .frame(width: 560, height: 430)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline).foregroundStyle(.orange)
            content.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    init(_ keys: String, _ action: String) { self.keys = keys; self.action = action }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(keys).font(.callout.monospaced()).frame(width: 245, alignment: .leading)
            Text(action).font(.callout).foregroundStyle(.secondary)
        }
    }
}
