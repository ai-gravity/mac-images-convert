import AppKit
import Foundation
import MacImagesConvertCore
import SwiftUI
import UniformTypeIdentifiers

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

@main
struct MacImagesConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var queue = ConversionQueue()

    var body: some Scene {
        WindowGroup("Mac images convert") { ContentView().environmentObject(queue).frame(minWidth: 900, minHeight: 620) }
            .commands { CommandGroup(replacing: .newItem) { Button("Add Images…") { queue.chooseFiles() }.keyboardShortcut("o") } }
        Settings { SettingsView().environmentObject(queue) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.servicesProvider = FinderServiceProvider.shared }
}

@MainActor final class FinderServiceProvider: NSObject {
    static let shared = FinderServiceProvider()
    @objc func openFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        NotificationCenter.default.post(name: .finderFilesReceived, object: urls)
    }
}

extension Notification.Name { static let finderFilesReceived = Notification.Name("MacImagesConvert.finderFilesReceived") }

@MainActor
final class ConversionQueue: ObservableObject {
    struct Job: Identifiable {
        enum State: Equatable { case ready, converting, completed(URL), failed(String), skipped(String) }
        let id = UUID(); let url: URL; var inspection: ImageInspection?; var state: State = .ready
    }
    @Published var jobs: [Job] = []
    @Published var destination: URL?
    @Published var options = ConversionOptions()
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var watcher = WatchFolderMonitor()
    @Published var customWidth = 1600
    @Published var customHeight = 1200
    @Published var customCap = 2.0
    @Published var customCapUnit = "MB"
    @Published var sizeCapPreset = "2.0 MB"
    private var cancellationFlag = CancellationFlag()

    init() {
        NotificationCenter.default.addObserver(forName: .finderFilesReceived, object: nil, queue: .main) { [weak self] note in
            let receivedURLs = note.object as? [URL] ?? []
            Task { @MainActor [receivedURLs] in self?.enqueue(receivedURLs) }
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    var readyCount: Int { jobs.filter { if case .ready = $0.state { true } else { false } }.count }
    var completedCount: Int { jobs.filter { if case .completed = $0.state { true } else { false } }.count }
    var progress: Double { jobs.isEmpty ? 0 : Double(completedCount + jobs.filter { if case .failed = $0.state { true } else { false } }.count) / Double(jobs.count) }

    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Choose Destination"
        if panel.runModal() == .OK { destination = panel.url }
    }
    func enqueue(_ urls: [URL], includeExisting: Bool = true) {
        var incoming: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                incoming += (enumerator?.allObjects as? [URL] ?? []).filter { ImageConverter.acceptedExtensions.contains($0.pathExtension.lowercased()) }
            } else if ImageConverter.acceptedExtensions.contains(url.pathExtension.lowercased()) { incoming.append(url) }
        }
        for url in incoming where !jobs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            let inspected = try? ImageConverter.inspect(url)
            jobs.append(Job(url: url, inspection: inspected, state: inspected == nil ? .skipped("Unreadable") : .ready))
        }
    }
    func retryFailures() { for index in jobs.indices { if case .failed = jobs[index].state { jobs[index].state = .ready } } }
    func cancel() { cancellationFlag.cancel(); isPaused = false }
    func start() {
        guard let destination, !isRunning else { return }
        cancellationFlag = CancellationFlag(); let cancellationFlag = cancellationFlag; isRunning = true
        let options = options
        Task {
            // Deliberately serial: it bounds memory while decoding large camera images.
            while !cancellationFlag.isCancelled, let index = jobs.indices.first(where: { if case .ready = jobs[$0].state { true } else { false } }) {
                while isPaused && !cancellationFlag.isCancelled { try? await Task.sleep(for: .milliseconds(150)) }
                if cancellationFlag.isCancelled { break }
                let source = jobs[index].url; jobs[index].state = .converting
                let result = await Task.detached(priority: .userInitiated) { () -> Result<ConversionResult, Error> in
                    Result { try ImageConverter.convert(source, destination: destination, options: options, shouldCancel: { cancellationFlag.isCancelled }) }
                }.value
                if cancellationFlag.isCancelled { jobs[index].state = .ready; break }
                switch result {
                case .success(let success): jobs[index].state = .completed(success.output!)
                case .failure(let error): jobs[index].state = .failed(error.localizedDescription)
                }
            }
            isRunning = false
        }
    }
    func clearFinished() { jobs.removeAll { if case .ready = $0.state { false } else if case .converting = $0.state { false } else { true } } }
    func startWatchFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Watch Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        watcher.start(folder: folder, excluding: destination) { [weak self] urls in Task { @MainActor in self?.enqueue(urls, includeExisting: false) } }
    }
}

struct ContentView: View {
    @EnvironmentObject private var queue: ConversionQueue
    @State private var showTrashWarning = false
    var body: some View {
        NavigationSplitView {
            List { Label("Conversion", systemImage: "arrow.triangle.2.circlepath") }.navigationTitle("Mac images convert")
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                HStack(alignment: .top, spacing: 20) { files; settings }.padding(20)
                Divider(); footer.padding(16)
            }
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add images", systemImage: "plus") { queue.chooseFiles() } } }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            Task { @MainActor in queue.enqueue([url]) }
                        }
                    }
                }
                return true
            }
            .alert("Move originals to Trash?", isPresented: $showTrashWarning) { Button("Keep enabled", role: .destructive) { queue.options.moveOriginalToTrash = true }; Button("Cancel", role: .cancel) { queue.options.moveOriginalToTrash = false } } message: { Text("Original files leave their folders only after a converted copy is saved and checked. Emptying Trash deletes them permanently; synced folders may sync the removal.") }
        }
    }
    private var header: some View { HStack { VStack(alignment: .leading) { Text("Convert images locally").font(.title2.weight(.semibold)); Text("HEIC, JPEG, PNG, and static WebP. Nothing is uploaded.").foregroundStyle(.secondary) }; Spacer(); if queue.isRunning { ProgressView(value: queue.progress).frame(width: 160); Text("\(Int(queue.progress * 100))%") } }.padding(20) }
    private var files: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Images").font(.headline); Spacer(); Button("Add files…") { queue.chooseFiles() }; Button("Clear finished") { queue.clearFinished() }.disabled(queue.isRunning) }
            if queue.jobs.isEmpty {
                ContentUnavailableView("Drop images or folders here", systemImage: "photo.on.rectangle.angled", description: Text("Folders are scanned for supported image files."))
            } else {
                List(queue.jobs) { job in
                    HStack {
                        Image(systemName: symbol(for: job.state)).foregroundStyle(color(for: job.state))
                        VStack(alignment: .leading) {
                            Text(job.url.lastPathComponent)
                            if let info = job.inspection {
                                let frames = info.frameCount == 1 ? "one frame" : "\(info.frameCount) frames"
                                Text("\(info.bytesText) · \(info.dimensionsText) · \(frames)").font(.caption).foregroundStyle(.secondary)
                            }
                            if case .failed(let message) = job.state { Text(message).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer(); Text(status(for: job.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(minHeight: 300)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var settings: some View { Form { Section("Output") { Picker("Format", selection: $queue.options.format) { ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) } }; Picker("Dimensions", selection: Binding(get: { queue.options.dimensions.label }, set: { chooseDimension($0) })) { Text("Original (recommended)").tag("Original"); Text("75%").tag("75%"); Text("50%").tag("50%"); Text("25%").tag("25%"); Text("2048px long edge (recommended web)").tag("2048px long edge"); Text("Custom").tag("Custom") }; if case .custom = queue.options.dimensions { HStack { TextField("Width", value: $queue.customWidth, format: .number).frame(width: 80); Text("×"); TextField("Height", value: $queue.customHeight, format: .number).frame(width: 80); Button("Apply") { queue.options.dimensions = .custom(width: queue.customWidth, height: queue.customHeight) } } }; if queue.options.format == .jpeg { Picker("JPEG quality", selection: $queue.options.jpegQuality) { ForEach(JPEGQuality.allCases) { Text($0.rawValue + ($0 == .high ? " (recommended)" : "")).tag($0) } } } }
            Section("Size cap per image") { Toggle("Set a maximum file size", isOn: Binding(get: { queue.options.sizeCap != nil }, set: { enabled in queue.options.sizeCap = enabled ? SizeCap(bytes: 2_000_000) : nil; if enabled { queue.sizeCapPreset = "2.0 MB" } })); if queue.options.sizeCap != nil { Picker("Preset", selection: Binding(get: { queue.sizeCapPreset }, set: { queue.sizeCapPreset = $0; chooseCap($0) })) { Text("500 KB").tag("500 KB"); Text("1 MB").tag("1.0 MB"); Text("2 MB (recommended)").tag("2.0 MB"); Text("5 MB").tag("5.0 MB"); Text("Custom").tag("Custom") }; if queue.sizeCapPreset == "Custom" { HStack { TextField("Size", value: $queue.customCap, format: .number); Picker("Unit", selection: $queue.customCapUnit) { Text("KB").tag("KB"); Text("MB").tag("MB") }; Button("Apply") { queue.options.sizeCap = SizeCap(bytes: Int(queue.customCap * (queue.customCapUnit == "MB" ? 1_000_000 : 1_000))) } } }; Toggle("Allow smaller dimensions to meet the cap", isOn: Binding(get: { queue.options.sizeCap?.allowDownsizing ?? true }, set: { queue.options.sizeCap?.allowDownsizing = $0 })) } }
            Section("Privacy") { Toggle("Hide where photos were taken", isOn: $queue.options.removeLocation); Text("Removes embedded GPS locations. It cannot hide landmarks or addresses visible in the photo.").font(.caption).foregroundStyle(.secondary) }
            Section("Originals") { Toggle("Move originals to Trash after conversion", isOn: Binding(get: { queue.options.moveOriginalToTrash }, set: { if $0 { showTrashWarning = true } else { queue.options.moveOriginalToTrash = false } })).tint(.orange) }
        }.frame(width: 370).formStyle(.grouped) }
    private var footer: some View { HStack { VStack(alignment: .leading) { Text(queue.destination.map { "Destination: \($0.lastPathComponent)" } ?? "Choose a destination folder to begin").font(.subheadline); if let destination = queue.destination { Text(destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }; Spacer(); Button(queue.destination == nil ? "Choose destination…" : "Change destination…") { queue.chooseDestination() }; if queue.isRunning { Button(queue.isPaused ? "Resume" : "Pause") { queue.isPaused.toggle() }; Button("Cancel", role: .destructive) { queue.cancel() } } else { Button("Convert \(queue.readyCount) image\(queue.readyCount == 1 ? "" : "s")") { queue.start() }.buttonStyle(.borderedProminent).disabled(queue.destination == nil || queue.readyCount == 0) } } }
    private func chooseDimension(_ value: String) { switch value { case "Original": queue.options.dimensions = .original; case "75%": queue.options.dimensions = .percentage(0.75); case "50%": queue.options.dimensions = .percentage(0.5); case "25%": queue.options.dimensions = .percentage(0.25); case "2048px long edge": queue.options.dimensions = .longEdge(2048); default: queue.options.dimensions = .custom(width: queue.customWidth, height: queue.customHeight) } }
    private func chooseCap(_ value: String) { switch value { case "500 KB": queue.options.sizeCap = SizeCap(bytes: 500_000); case "1.0 MB": queue.options.sizeCap = SizeCap(bytes: 1_000_000); case "2.0 MB": queue.options.sizeCap = SizeCap(bytes: 2_000_000); case "5.0 MB": queue.options.sizeCap = SizeCap(bytes: 5_000_000); default: queue.options.sizeCap = SizeCap(bytes: Int(queue.customCap * 1_000_000)) } }
    private func status(for state: ConversionQueue.Job.State) -> String { switch state { case .ready: "Ready"; case .converting: "Converting"; case .completed: "Done"; case .failed: "Failed"; case .skipped: "Skipped" } }
    private func symbol(for state: ConversionQueue.Job.State) -> String { switch state { case .ready: "photo"; case .converting: "arrow.triangle.2.circlepath"; case .completed: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"; case .skipped: "xmark.circle" } }
    private func color(for state: ConversionQueue.Job.State) -> Color { switch state { case .completed: .green; case .failed: .red; case .skipped: .secondary; default: .blue } }
}

struct SettingsView: View { @EnvironmentObject private var queue: ConversionQueue; var body: some View { Form { Section("Watch folder") { if let folder = queue.watcher.folder { Text(folder.path); Button("Stop watching", role: .destructive) { queue.watcher.stop() } } else { Text("While this app is open, add stable new files from a selected folder.").foregroundStyle(.secondary); Button("Choose watch folder…") { queue.startWatchFolder() } }; Text("Existing files are ignored when a watch starts. Output folders are excluded, and watched jobs never move originals to Trash.").font(.caption).foregroundStyle(.secondary) } }.padding(20).frame(width: 440) } }
