import Foundation
import MacImagesConvertCore

@MainActor
final class WatchFolderMonitor: NSObject, ObservableObject {
    @Published private(set) var folder: URL?
    private var timer: Timer?
    private var output: URL?
    private var known = Set<URL>()
    private var sizes = [URL: Int]()
    private var onReady: (([URL]) -> Void)?
    func start(folder: URL, excluding output: URL?, onReady: @escaping ([URL]) -> Void) {
        stop(); self.folder = folder; self.output = output; self.onReady = onReady
        known = Set(files(in: folder, excluding: output))
        let newTimer = Timer(timeInterval: 2, target: self, selector: #selector(scan), userInfo: nil, repeats: true)
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil; folder = nil; output = nil; known.removeAll(); sizes.removeAll(); onReady = nil }
    @objc private func scan() {
        guard let folder else { return }
        var ready: [URL] = []
        for file in files(in: folder, excluding: output) where !known.contains(file) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if sizes[file] == size { ready.append(file); known.insert(file); sizes.removeValue(forKey: file) } else { sizes[file] = size }
        }
        if !ready.isEmpty { onReady?(ready) }
    }
    private func files(in folder: URL, excluding output: URL?) -> [URL] {
        let outputPath = output?.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return (enumerator?.allObjects as? [URL] ?? []).filter { url in ImageConverter.acceptedExtensions.contains(url.pathExtension.lowercased()) && (outputPath == nil || !url.standardizedFileURL.path.hasPrefix(outputPath! + "/")) }
    }
}
