import Foundation

/// The session and device tokens, in a file only this macOS user can read (mode 0600).
/// Deliberately not the keychain: ad-hoc builds change signature on every rebuild,
/// and the keychain then asks for the login keychain password.
enum TokenStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tech.joeljacob.workholic", isDirectory: true)
            .appendingPathComponent("tokens.json")
    }

    static func get(_ name: String) -> String? {
        load()[name]
    }

    static func set(_ name: String, _ value: String) {
        var tokens = load()
        tokens[name] = value
        save(tokens)
    }

    static func delete(_ name: String) {
        var tokens = load()
        guard tokens.removeValue(forKey: name) != nil else { return }
        save(tokens)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func save(_ tokens: [String: String]) {
        let manager = FileManager.default
        if tokens.isEmpty {
            try? manager.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create the file as 0600 first and write in place, so the tokens are never readable by others.
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? data.write(to: url)
    }
}
