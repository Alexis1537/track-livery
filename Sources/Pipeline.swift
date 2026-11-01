import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// One step of the conversion pipeline, sent to the UI (or the console) as it happens.
enum PipelineEvent {
    case recognized(artist: String, title: String)
    case converting(progress: Double) // 0...1, from the converter
    /// A compressed file (MP3, AAC) keeps its format: no conversion, tags only.
    case keptFormat(name: String)
    case artwork(data: Data, width: Int, height: Int, source: String,
                 trackName: String, artistName: String, albumName: String?)
    case tagging
    case importing
    case done(outputFile: URL, replacedStaleCopy: Bool, keptExisting: Bool)
    case failed(message: String)
}

protocol PipelineDelegate: AnyObject {
    func pipelineEvent(_ event: PipelineEvent)
}

/// Runs the whole job for one dropped WAV:
///   WAV/AIFF/FLAC --(AudioToolbox)--> ALAC --(AVFoundation: cover art + chosen genre)--> tagged m4a --(Music)--> library
final class PipelineRunner {
    weak var delegate: PipelineDelegate?
    /// GUI mode delivers events on the main queue; CLI mode delivers them directly.
    var onMainQueue = true
    /// CLI testing can skip the final import into Music.
    var importToMusic = true
    /// The genre written into the file (chosen in the window; Dance by default).
    var genre = "Dance"

    private func emit(_ event: PipelineEvent) {
        if onMainQueue {
            DispatchQueue.main.async { self.delegate?.pipelineEvent(event) }
        } else {
            delegate?.pipelineEvent(event)
        }
    }

    func run(fileURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.execute(fileURL: fileURL)
        }
    }

    private func execute(fileURL: URL) {
        let fm = FileManager.default
        guard Converter.accepts(fileURL) else {
            emit(.failed(message: "“\(fileURL.lastPathComponent)” is not a WAV, AIFF, FLAC, MP3 or AAC file."))
            return
        }
        let parsed = Self.parseFileName(fileURL.lastPathComponent)
        var source = SourceTags.read(fileURL)   // tags already in the download, carried over
        // the file's own tags beat the file name: Beatport turns ' into _ in file names
        // ("Barry Can_t Swim"), but its tags keep the real spelling
        let artist = source.artist ?? parsed.artist.replacingOccurrences(of: "_", with: "'")
        let rawTitle = source.title ?? parsed.title.replacingOccurrences(of: "_", with: "'")
        // tidy ALL CAPS / all lowercase titles and albums (never artist names)
        let title = Prefs.tidyCaps ? TitleCase.tidy(rawTitle) : rawTitle
        if Prefs.tidyCaps, let a = source.album { source.album = TitleCase.tidy(a) }
        emit(.recognized(artist: artist, title: title))

        // Fresh temp directory for this run.
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("track-livery-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }   // on every exit, success or not

        // Look up the cover art in parallel with the conversion.
        let artworkBox = ArtworkBox()
        DispatchQueue.global(qos: .utility).async {
            artworkBox.result = ArtworkFetcher().fetch(artist: artist, title: title, file: fileURL, album: source.album)
        }

        // 1. Convert WAV / AIFF / FLAC -> Apple Lossless with macOS's own encoder.
        //    MP3 and AAC are already compressed: they keep their format and audio
        //    untouched, and only get tags and art.
        let lossy = Converter.isCompressed(fileURL)
        var alacURL = fileURL
        if lossy {
            emit(.keptFormat(name: Converter.formatName(fileURL)))
        } else {
            emit(.converting(progress: 0))
            alacURL = workDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".m4a")
            if case .failure(let failure) = Converter.convert(fileURL, to: alacURL, progress: { self.emit(.converting(progress: $0)) }) {
                emit(.failed(message: failure.description))
                return
            }
            emit(.converting(progress: 1))
        }

        // 2. Cover art (waits for the parallel lookup to finish).
        let art = artworkBox.wait()
        if let art = art {
            emit(.artwork(data: art.data, width: art.width, height: art.height, source: art.source,
                          trackName: art.trackName ?? title,
                          artistName: art.artistName ?? artist,
                          albumName: art.albumName))
        }

        // 3. Tag the file: the chosen genre, cover art, and title/artist/album metadata.
        emit(.tagging)
        let taggedFile: URL?
        if fileURL.pathExtension.lowercased() == "mp3" {
            let out = workDir.appendingPathComponent("tagged.mp3")
            taggedFile = ID3Writer.write(source: fileURL, destination: out, title: title, artist: artist,
                                         album: source.album ?? tidyAlbum(art?.albumName), genre: genre, art: art?.data) ? out : nil
        } else {
            if source.album == nil { source.album = tidyAlbum(art?.albumName) }
            taggedFile = Tagger.tag(alacURL: alacURL, artwork: art, source: source, genre: genre, artist: artist, title: title, workDir: workDir)
        }
        guard let tagged = taggedFile else {
            emit(.failed(message: "Couldn’t write the tags and cover art into the file."))
            return
        }

        // Keep the finished file next to the original download, so the library
        // never points at a file in a temp directory.
        let finalURL = Self.uniqueDestination(for: tagged, beside: fileURL)
        do {
            try fm.moveItem(at: tagged, to: finalURL)
        } catch {
            emit(.failed(message: "Could not save the converted file: \(error.localizedDescription)"))
            return
        }

        // 4. Import into the Music (iTunes) library.
        var replaced = false, kept = false
        if importToMusic {
            emit(.importing)
            let result = MusicImporter.importFile(finalURL, name: title, artist: artist)
            if let error = result.error {
                emit(.failed(message: error))
                return
            }
            replaced = result.replaced
            kept = result.keptExisting
        }

        emit(.done(outputFile: finalURL, replacedStaleCopy: replaced, keptExisting: kept))
    }

    private func tidyAlbum(_ a: String?) -> String? {
        guard let a = a else { return nil }
        return Prefs.tidyCaps ? TitleCase.tidy(a) : a
    }

    static func parseArtist(_ url: URL) -> String {
        parseFileName(url.lastPathComponent).artist.replacingOccurrences(of: "_", with: "'")
    }

    /// Beatport names downloads "Artist - Title (Mix).wav", sometimes with a
    /// leading track number ("01 - Artist - Title.wav").
    static func parseFileName(_ fileName: String) -> (artist: String, title: String) {
        var base = (fileName as NSString).deletingPathExtension
        if let m = base.range(of: "^\\d{1,3}[\\s.-]+", options: .regularExpression) {
            base.removeSubrange(m)
        }
        if let dash = base.range(of: " - ") {
            let artist = base[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let title = base[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            return (artist, title)
        }
        return ("", base.trimmingCharacters(in: .whitespaces))
    }

    /// Picks a non-colliding "<name>.m4a" next to the original file.
    private static func uniqueDestination(for file: URL, beside original: URL) -> URL {
        let dir = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.isEmpty ? "m4a" : file.pathExtension
        var candidate = dir.appendingPathComponent(base + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Mutable box so an escaping closure can append to it.
final class DataBox {
    var data = Data()
}

/// Lets the pipeline wait for the parallel artwork lookup.
final class ArtworkBox {
    private let semaphore = DispatchSemaphore(value: 0)
    private var _result: ArtworkResult?
    var result: ArtworkResult? {
        get { _result }
        set { _result = newValue; semaphore.signal() }
    }
    func wait() -> ArtworkResult? {
        semaphore.wait()
        return _result
    }
}

/// Prints pipeline events to the terminal; used by `--cli` mode.
final class ConsolePipelineDelegate: PipelineDelegate {
    private let semaphore: DispatchSemaphore
    init(semaphore: DispatchSemaphore) { self.semaphore = semaphore }

    func pipelineEvent(_ event: PipelineEvent) {
        switch event {
        case .recognized(let artist, let title):
            let name = artist.isEmpty ? title : "\(artist) — \(title)"
            print("Recognized: \(name)")
        case .converting(let p):
            print("\rConverting to Apple Lossless… \(Int(p * 100))%", terminator: "")
            fflush(stdout)
        case .artwork(_, let w, let h, let source, let track, let artist, _):
            print("\rCover art found: \(artist) — \(track) (\(w)×\(h) px, \(source))")
        case .keptFormat(let name):
            print("Kept as \(name): no conversion needed")
        case .tagging:
            print("Tagging genre “Dance” and embedding cover art…")
        case .importing:
            print("Adding to your Music library…")
        case .done(let url, let replaced, let kept):
            print("\nDone: \(url.path)\(replaced ? " (replaced the old copy in the library)" : "")\(kept ? " (already in the library: kept your copy)" : "")")
            semaphore.signal()
        case .failed(let message):
            print("\nFailed: \(message)")
            semaphore.signal()
        }
    }
}
