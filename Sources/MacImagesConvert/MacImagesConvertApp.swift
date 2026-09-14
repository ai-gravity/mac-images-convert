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
        WindowGroup("Mac images convert") { ContentView().environmentObject(queue).frame(minWidth: 760, minHeight: 580) }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Add Images…") { queue.chooseFiles() }.keyboardShortcut("o")
                }
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { Task { await UpdateChecker.checkAndPresent() } }
                }
            }
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
        var outputInspection: ImageInspection?
        var isWatched = false
    }
    @Published var jobs: [Job] = []
    @Published var destination: URL?
    @Published var options = ConversionOptions()
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var watcher = WatchFolderMonitor()
    @Published var setup = ConversionSetup()
    @Published var message: String?
    var validationMessage: String? {
        do { _ = try setup.resolved(from: options); return nil }
        catch { return error.localizedDescription }
    }
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
            jobs.append(Job(url: url, inspection: inspected, state: inspected == nil ? .skipped("Unreadable") : .ready, isWatched: !includeExisting))
        }
    }
    func retryFailures() { for index in jobs.indices { if case .failed = jobs[index].state { jobs[index].state = .ready } } }
    func cancel() { cancellationFlag.cancel(); isPaused = false }
    func start() {
        guard !isRunning else { return }
        guard let destination else { chooseDestination(); return }
        let resolved: ConversionOptions
        do { resolved = try setup.resolved(from: options) }
        catch { message = error.localizedDescription; return }
        cancellationFlag = CancellationFlag(); let cancellationFlag = cancellationFlag; isRunning = true
        message = nil
        Task {
            // Deliberately serial: it bounds memory while decoding large camera images.
            while !cancellationFlag.isCancelled, let index = jobs.indices.first(where: { if case .ready = jobs[$0].state { true } else { false } }) {
                while isPaused && !cancellationFlag.isCancelled { try? await Task.sleep(for: .milliseconds(150)) }
                if cancellationFlag.isCancelled { break }
                let source = jobs[index].url; jobs[index].state = .converting
                var jobOptions = resolved
                if jobs[index].isWatched { jobOptions.moveOriginalToTrash = false }
                let options = jobOptions
                let result = await Task.detached(priority: .userInitiated) { () -> Result<ConversionResult, Error> in
                    Result { try ImageConverter.convert(source, destination: destination, options: options, shouldCancel: { cancellationFlag.isCancelled }) }
                }.value
                switch result {
                case .success(let success):
                    if let output = success.output {
                        jobs[index].state = .completed(output)
                        jobs[index].outputInspection = try? ImageConverter.inspect(output)
                    }
                case .failure(let error):
                    if error as? ConversionError == .cancelled { jobs[index].state = .ready }
                    else { jobs[index].state = .failed(error.localizedDescription) }
                }
            }
            isRunning = false
        }
    }
    func convertAgain() {
        guard !isRunning else { return }
        for index in jobs.indices where FileManager.default.fileExists(atPath: jobs[index].url.path) {
            jobs[index].state = .ready; jobs[index].outputInspection = nil
        }
    }
    func clearFinished() { jobs.removeAll { if case .ready = $0.state { false } else if case .converting = $0.state { false } else { true } } }
    func startWatchFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Watch Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        watcher.start(folder: folder, excluding: destination) { [weak self] urls in Task { @MainActor in self?.enqueue(urls, includeExisting: false) } }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var queue: ConversionQueue

    var body: some View {
        Form {
            Section("Watch folder") {
                if let folder = queue.watcher.folder {
                    Text(folder.path)
                    Button("Stop watching", role: .destructive) { queue.watcher.stop() }
                } else {
                    Text("While this app is open, add stable new files from a selected folder.").foregroundStyle(.secondary)
                    Button("Choose watch folder…") { queue.startWatchFolder() }
                }
                Text("Existing files are ignored when a watch starts. Output folders are excluded, and watched jobs never move originals to Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Button("Check for Updates…") { Task { await UpdateChecker.checkAndPresent() } }
                Text("Checks the public GitHub Releases page. No account or GitHub token is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 440)
    }
}
