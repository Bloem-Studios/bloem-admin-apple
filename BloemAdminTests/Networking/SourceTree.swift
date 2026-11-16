import Foundation

/// Reads the app's Swift sources for the tests that scan them. The simulator shares the Mac's
/// file system, so `#filePath` of a test file leads back to the checkout it was built from.
enum SourceTree {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Networking
        .deletingLastPathComponent()  // BloemAdminTests
        .deletingLastPathComponent()  // repository root

    struct File {
        /// Path relative to `BloemAdmin/`, for example `Networking/AuthAPI.swift`.
        let path: String
        let lines: [String]
    }

    static func appSources() throws -> [File] {
        try sources(in: "BloemAdmin")
    }

    /// The Swift sources of one top-level folder of the repository, such as `BloemAdminWidgets`.
    static func sources(in folder: String) throws -> [File] {
        let appRoot = root.appendingPathComponent(folder)
        guard let walker = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [File] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = String(url.path.dropFirst(appRoot.path.count + 1))
            files.append(File(path: relative, lines: text.components(separatedBy: "\n")))
        }
        return files.sorted { $0.path < $1.path }
    }
}
