import CoreServices
import Foundation

/// Watches a folder for new music downloads. Uses macOS's FSEvents (no polling). Files already there
/// when watching starts are never imported. A file is handed over only once it
/// has finished downloading: its size must stay the same across two checks two
/// seconds apart, and browser placeholders (.download, .crdownload, .part) are
/// skipped. Beatport's "artwork" folders, app bundles, hidden files, the
/// backup folder and files the app itself wrote are ignored.
final class FolderWatcher {
    var onNewFiles: (([URL]) -> Void)?
    private(set) var folder: URL?
    private var stream: FSEventStreamRef?
    private var known = Set<String>()
    private var pending: [String: Int64] = [:]   // path -> size at last check
    private var ignored = Set<String>()
    private var scanScheduled = false
    private var includeSubfolders = true
    private var skipFolder: String?
    private let queue = DispatchQueue(label: "tracklivery.watcher")

    /// When the app last looked at the folder (kept between launches), so music
    /// that arrived while the app was closed is offered at the next start.
    private static let lastLookKey = "watchLastLook"
    private static func rememberLook() { UserDefaults.standard.set(Date(), forKey: lastLookKey) }

    /// Starts (or restarts) watching. Files added to the folder before the app last
    /// looked count as seen; on the very first run, everything already there does.
    func start(folder: URL, subfolders: Bool, skip: URL?) {
        stop()
        self.folder = folder
        includeSubfolders = subfolders
        skipFolder = skip?.standardizedFileURL.path
        let lastLook = UserDefaults.standard.object(forKey: Self.lastLookKey) as? Date
        queue.sync {
            pending = [:]
            known = []
            for url in audioFiles() {
                let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
                    ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                if let lastLook = lastLook, let added = added, added > lastLook {
                    continue // arrived while the app was closed: picked up by the first scan below
                }
                known.insert(url.path)
            }
            Self.rememberLook()
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        queue.async { [weak self] in self?.scan() } // offer what arrived while closed
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        folder = nil
    }

    /// Files the app writes or moves itself are never treated as new downloads.
    func ignore(_ url: URL) {
        queue.async { self.ignored.insert(url.standardizedFileURL.path); self.known.insert(url.standardizedFileURL.path) }
    }

    private func changed() {
        guard !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.scanScheduled = false
            self?.scan()
        }
    }

    private func scan() {
        guard folder != nil else { return }
        defer { Self.rememberLook() }
        var ready: [URL] = []
        for url in audioFiles() {
            let path = url.path
            guard !known.contains(path), !ignored.contains(path) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? -1
            guard size > 0 else { continue }
            if let last = pending[path], last == size {
                pending[path] = nil
                known.insert(path)
                ready.append(url)
            } else {
                pending[path] = size // still downloading, or seen for the first time
            }
        }
        if !pending.isEmpty {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scan() }
        }
        if !ready.isEmpty {
            let files = ready.sorted { $0.lastPathComponent < $1.lastPathComponent }
            DispatchQueue.main.async { self.onNewFiles?(files) }
        }
    }

    private func audioFiles() -> [URL] {
        guard let folder = folder else { return [] }
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: options) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            let name = url.lastPathComponent.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let p = url.standardizedFileURL.path
                if name == "artwork" || ["download", "crdownload", "part", "app"].contains(url.pathExtension.lowercased())
                    || (skipFolder != nil && (p == skipFolder || p.hasPrefix(skipFolder! + "/"))) {
                    e.skipDescendants()
                }
                continue
            }
            if Converter.accepts(url) { out.append(url.standardizedFileURL) }
        }
        return out
    }
}
