import Foundation

/// Adds the finished file to the Music library (called "iTunes" on older macOS).
///
/// Only AppleScript is used: it imports without bringing any window forward.
/// (An earlier version fell back to `open -a Music <file>`, which pops the
/// Music window / mini player over whatever you were doing - removed.)
///
/// Music's `add` silently keeps an existing track when the file's name/artist
/// match one already in the library. If the library already has this title and
/// artist, nothing is added and nothing is ever removed: the existing track is
/// left alone and the caller is told so (never delete).
enum MusicImporter {
    /// Returns nil on success, otherwise a message explaining what to allow.
    /// `replaced` is always false (kept so callers and results still compile);
    /// `keptExisting` is true when the library already had this title and artist,
    /// which was left alone (the new file is still saved beside the WAV).
    static func importFile(_ file: URL, name: String, artist: String) -> (error: String?, replaced: Bool, keptExisting: Bool) {
        let appName: String
        if FileManager.default.fileExists(atPath: "/System/Applications/Music.app")
            || FileManager.default.fileExists(atPath: "/Applications/Music.app") {
            appName = "Music"
        } else {
            appName = "iTunes"
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let nm = esc(name), ar = esc(artist), path = esc(file.path)

        // Counts library tracks matching the file's name/artist, in its own
        // osascript session.
        func countMatching() -> Int? {
            let script = """
            tell application "\(appName)"
              return count of (every track of library playlist 1 whose name is "\(nm)" and artist is "\(ar)") as string
            end tell
            """
            return runOsascript(script).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        // Adds the file in its own osascript session.
        func addFile() -> Bool {
            let script = """
            tell application "\(appName)"
              add POSIX file "\(path)"
            end tell
            """
            return runOsascript(script) != nil
        }

        // Adds the file and returns how many new library tracks appeared (0 = Music
        // kept an existing duplicate instead). Music only makes a just-added track
        // visible once the `add` session has ended, so the count must be polled
        // from separate osascript calls — counting inside the same script as the
        // `add` always reads 0.
        func addDelta() -> Int? {
            guard let n1 = countMatching(), addFile() else { return nil }
            let deadline = Date().addingTimeInterval(10)
            var n2 = n1
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                guard let c = countMatching() else { return nil }
                n2 = c
                if n2 > n1 { break }
            }
            return n2 - n1
        }

        // Before adding: if the library already has this title and artist, add
        // nothing and touch nothing (Music would otherwise add a duplicate).
        var existing = countMatching()
        if existing == nil {
            Thread.sleep(forTimeInterval: 2) // the automation prompt may just have been answered
            existing = countMatching()
        }
        if let n = existing, n > 0 {
            return (nil, false, true)
        }

        // Add (with one retry in case the automation prompt was just answered).
        var delta = addDelta()
        if delta == nil {
            Thread.sleep(forTimeInterval: 2)
            delta = addDelta()
        }
        if (delta ?? 0) == 0 {
            return ("Music did not accept the file. Allow Track Livery to control \(appName) "
                + "in System Settings > Privacy & Security > Automation, then drop the file again.", false, false)
        }
        return (nil, false, false)
    }

    /// True when a track Music added in the last day points at this exact file
    /// (Music set not to copy files into its own folder). On any doubt, true:
    /// the caller keeps the file when this is true, so a wrong `true` only
    /// leaves a spare copy behind, while a wrong `false` would lose music.
    static func libraryUses(_ file: URL) -> Bool {
        if file.path.contains("\n") { return true }
        let app = FileManager.default.fileExists(atPath: "/System/Applications/Music.app")
            || FileManager.default.fileExists(atPath: "/Applications/Music.app") ? "Music" : "iTunes"
        let script = """
        set out to ""
        tell application "\(app)"
          repeat with t in (every file track of library playlist 1 whose date added > ((current date) - 1 * days))
            try
              set out to out & POSIX path of (location of t as alias) & linefeed
            on error
              return "ERROR"
            end try
          end repeat
        end tell
        return out
        """
        guard let reply = runOsascript(script) else { return true }
        let lines = reply.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        if lines.contains("ERROR") { return true }
        let target = file.resolvingSymlinksInPath().path
        return lines.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target }
    }

    private static func runOsascript(_ script: String) -> String? {
        final class Captured: @unchecked Sendable {
            var out = Data(), err = Data()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let box = Captured()
        let group = DispatchGroup()
        // Read both pipes while the process runs: a large reply would otherwise
        // fill the pipe and leave both sides waiting for ever.
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            box.out = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            box.err = err.fileHandleForReading.readDataToEndOfFile()
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.closeFile()
            err.fileHandleForReading.closeFile()
            return nil
        }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        // The pipes end when the process exits, so the reads finish now.
        _ = group.wait(timeout: .now() + 5)
        guard status == 0 else { return nil }
        return String(data: box.out, encoding: .utf8)
    }
}
