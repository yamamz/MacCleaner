import Foundation

/// Paths the user never wants MacSweep to scan or clean.
enum IgnoreList {
    static let key = "ignoredPaths"

    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func contains(_ url: URL, in list: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return list.contains { ignored in
            let base = URL(fileURLWithPath: ignored).standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }
    }
}
