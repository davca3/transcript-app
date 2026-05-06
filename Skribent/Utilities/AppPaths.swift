import Foundation

enum AppPaths {
    static var appSupport: URL {
        resolved(.applicationSupportDirectory).appendingPathComponent("Skribent", isDirectory: true)
    }

    static var documents: URL { resolved(.documentDirectory) }
    static var caches: URL { resolved(.cachesDirectory) }

    private static func resolved(_ dir: FileManager.SearchPathDirectory) -> URL {
        if let url = FileManager.default.urls(for: dir, in: .userDomainMask).first { return url }
        // Sandboxed macOS always returns ≥1 URL; this branch is only ever hit by dev tooling
        // running outside an app context. Fallback keeps the code crash-free.
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
