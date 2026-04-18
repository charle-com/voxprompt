import Foundation

// Logger fichier, désactivé par défaut.
// Activer pour debug : `launchctl setenv VOXPROMPT_DEBUG 1` ou lancer l'app depuis
// un terminal avec `VOXPROMPT_DEBUG=1 open -a VoxPrompt`.
// Les logs vont dans ~/Library/Logs/VoxPrompt/voxprompt.log (perms 0600, user-only).
enum VPLog {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["VOXPROMPT_DEBUG"] != nil
    }()

    static let logURL: URL? = {
        guard isEnabled else { return nil }
        let fm = FileManager.default
        guard let libs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = libs.appendingPathComponent("Logs/VoxPrompt", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("voxprompt.log")
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        return file
    }()

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        guard isEnabled, let url = logURL else { return }
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}
