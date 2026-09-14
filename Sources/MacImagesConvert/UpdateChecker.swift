import AppKit
import Foundation

enum UpdateChecker {
    private static let releasesURL = URL(string: "https://api.github.com/repos/ai-gravity/mac-images-convert/releases?per_page=20")!

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, assets
        }
    }

    @MainActor
    static func checkAndPresent() async {
        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Mac-images-convert", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw UpdateError.unavailable
            }
            let releases = try JSONDecoder().decode([Release].self, from: data)
                .filter { !$0.draft }
                .sorted { isNewer($0.tagName, than: $1.tagName) }
            guard let latest = releases.first else { throw UpdateError.unavailable }

            let currentText = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            if isNewer(latest.tagName, than: currentText) {
                let alert = NSAlert()
                alert.messageText = "Mac images convert \(displayVersion(latest.tagName)) is available"
                alert.informativeText = "You have version \(currentText). Download the new DMG, quit this app, then drag the new version into Applications and choose Replace."
                alert.addButton(withTitle: "Download Update")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    let download = latest.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browserDownloadURL ?? latest.htmlURL
                    NSWorkspace.shared.open(download)
                }
            } else {
                let alert = NSAlert()
                alert.messageText = "You’re up to date"
                alert.informativeText = "Mac images convert \(currentText) is the newest available version."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = "Check your internet connection and try again. You can also download releases directly from GitHub."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open GitHub Releases")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://github.com/ai-gravity/mac-images-convert/releases")!)
            }
        }
    }

    private static func version(_ text: String) -> [Int] {
        let core = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        return core.split(separator: "-").first?.split(separator: ".").map { Int($0) ?? 0 } ?? []
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = version(candidate)
        let right = version(current)
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func displayVersion(_ text: String) -> String {
        text.hasPrefix("v") ? String(text.dropFirst()) : text
    }

    private enum UpdateError: Error { case unavailable }
}
