import AVFoundation
import Foundation

struct ArtworkResult {
    let data: Data
    let width: Int
    let height: Int
    let source: String
    let trackName: String?
    let artistName: String?
    let albumName: String?
}

/// Finds the highest-resolution cover art for a track.
///
/// Sources, best first:
///   1. iTunes Search API - its artwork URL can be asked for any size and Apple
///      returns the largest it has (we ask for 10000x10000 and get the source
///      resolution back, e.g. 4000x4000).
///   2. MusicBrainz + Cover Art Archive - the original front cover, which can be
///      even larger than iTunes' copy.
/// The larger of the two wins.
final class ArtworkFetcher {
    static let maxImageBytes = 25 * 1024 * 1024
    static let maxJSONBytes = 2 * 1024 * 1024

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 90
        // MusicBrainz requires a User-Agent header.
        config.httpAdditionalHeaders = [
            "User-Agent": "TrackLivery/1.0 (https://github.com/Alexis1537/track-livery)"
        ]
        session = URLSession(configuration: config)
    }

    /// Best first (an online result is used only when it really matches the track):
    ///   1. cover art already inside the file (kept as it is),
    ///   2. the official cover in the "artwork" folder Beatport puts beside its downloads,
    ///   3. online, but only a result whose artist AND title match the track.
    func fetch(artist: String, title: String, file: URL? = nil, album: String? = nil) -> ArtworkResult? {
        if let file = file {
            if let r = embedded(file) { return r }
            if let r = artworkFolder(beside: file, artist: artist, album: album) { return r }
        }
        guard Prefs.onlineArtwork else { return nil }
        var candidates: [ArtworkResult] = []
        if let r = fetchITunes(artist: artist, title: title) { candidates.append(r) }
        if let r = fetchCoverArtArchive(artist: artist, title: title) { candidates.append(r) }
        return candidates.max(by: {
            $0.width.multipliedReportingOverflow(by: $0.height).partialValue
                < $1.width.multipliedReportingOverflow(by: $1.height).partialValue
        })
    }

    // MARK: - matching

    /// Lower case, no accents, letters and digits only, single spaces.
    static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// The title without "(Extended Mix)", "[Original Mix]", "feat. ..." etc.
    static func titleCore(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let r = s.range(of: #"\s+(feat\.?|ft\.?|featuring)\s.*$"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        return norm(s)
    }

    /// Each credited artist: "Tom Novy, MONK3YS & X feat. Y" -> [tom novy, monk3ys, x, y].
    static func artists(_ a: String) -> [String] {
        let parts = a.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring|vs\.?|x|and)\s+"#, with: ",",
                                           options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: CharacterSet(charactersIn: ",&/"))
        return parts.map { norm($0) }.filter { $0.count >= 2 }
    }

    static func artistMatches(_ ours: String, _ theirs: String) -> Bool {
        let a = artists(ours), t = norm(theirs)
        guard !a.isEmpty, !t.isEmpty else { return false }
        return a.contains { t.contains($0) }
    }

    static func titleMatches(_ ours: String, _ theirs: String) -> Bool {
        let a = titleCore(ours), b = titleCore(theirs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    // MARK: - quick checks for the track list's plan

    func hasEmbeddedArt(_ file: URL) -> Bool { embedded(file) != nil }
    func hasFolderArt(_ file: URL, artist: String, album: String?) -> Bool {
        artworkFolder(beside: file, artist: artist, album: album) != nil
    }

    // MARK: - art already in the file

    private func embedded(_ file: URL) -> ArtworkResult? {
        let asset = AVURLAsset(url: file)
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) where item.commonKey == .commonKeyArtwork {
                if let d = item.dataValue, d.count <= Self.maxImageBytes, let size = Self.imageSize(d) {
                    return ArtworkResult(data: d, width: size.0, height: size.1, source: "in the file",
                                         trackName: nil, artistName: nil, albumName: nil)
                }
            }
        }
        return nil
    }

    // MARK: - Beatport's artwork folder ("<Artist> - <Release>.jpg" beside the downloads)

    private func artworkFolder(beside file: URL, artist: String, album: String?) -> ArtworkResult? {
        let dir = file.deletingLastPathComponent().appendingPathComponent("artwork", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let wanted = album.map { Self.titleCore($0.components(separatedBy: ":").first ?? $0) } ?? ""
        var best: (score: Int, url: URL)?
        for name in names where ["jpg", "jpeg", "png"].contains((name as NSString).pathExtension.lowercased()) {
            let base = (name as NSString).deletingPathExtension
            let parts = base.components(separatedBy: " - ")
            let release = Self.titleCore(parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : base)
            let who = parts.count > 1 ? parts[0] : ""
            var score = 0
            if !wanted.isEmpty && !release.isEmpty && (release == wanted || wanted.hasPrefix(release) || release.hasPrefix(wanted)) { score += 2 }
            if !who.isEmpty && (Self.artistMatches(artist, who) || Self.artistMatches(who, artist)) { score += 1 }
            if score >= 2, score > (best?.score ?? 0) { best = (score, dir.appendingPathComponent(name)) }
        }
        guard let url = best?.url, (0...Self.maxImageBytes).contains(Self.localFileSize(url)),
              let d = try? Data(contentsOf: url), let size = Self.imageSize(d) else { return nil }
        return ArtworkResult(data: d, width: size.0, height: size.1, source: "artwork folder",
                             trackName: nil, artistName: nil, albumName: nil)
    }

    // MARK: - iTunes Search API

    private func fetchITunes(artist: String, title: String) -> ArtworkResult? {
        let term = "\(Self.artists(artist).first ?? artist) \(Self.titleCore(title))".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty,
              let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=10"),
              let data = syncData(url, limit: Self.maxJSONBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty
        else { return nil }

        // only a result whose artist AND title match
        let matching = results.filter {
            Self.artistMatches(artist, $0["artistName"] as? String ?? "") && Self.titleMatches(title, $0["trackName"] as? String ?? "")
        }
        guard let best = matching.first else { return nil }
        guard let artURLString = (best["artworkUrl100"] as? String)
                ?? (best["artworkUrl60"] as? String)
                ?? (best["artworkUrl30"] as? String) else { return nil }

        // Ask for a huge size: Apple serves the largest image it actually has.
        let big = artURLString.replacingOccurrences(
            of: #"\d+x\d+bb\.(jpg|jpeg|png)"#,
            with: "10000x10000bb.$1",
            options: .regularExpression)
        var artData: Data?
        if let bigURL = URL(string: big), Self.isAppleArtwork(bigURL),
           let d = syncData(bigURL, limit: Self.maxImageBytes), Self.imageSize(d) != nil {
            artData = d
        } else if let url = URL(string: artURLString), Self.isAppleArtwork(url),
                  let d = syncData(url, limit: Self.maxImageBytes), Self.imageSize(d) != nil {
            artData = d
        }
        guard let artData = artData, let size = Self.imageSize(artData) else { return nil }

        return ArtworkResult(
            data: artData, width: size.0, height: size.1, source: "iTunes",
            trackName: best["trackName"] as? String,
            artistName: best["artistName"] as? String,
            albumName: best["collectionName"] as? String)
    }

    // MARK: - MusicBrainz + Cover Art Archive

    private func fetchCoverArtArchive(artist: String, title: String) -> ArtworkResult? {
        var query = "recording:\"\(Self.titleCore(title))\""
        if let first = Self.artists(artist).first { query += " AND artist:\"\(first)\"" }
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "inc", value: "releasegroups"),
        ]
        guard let url = comps.url,
              let data = syncData(url, limit: Self.maxJSONBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = json["recordings"] as? [[String: Any]]
        else { return nil }

        var groupIDs: [String] = []
        for rec in recordings {
            // only recordings whose credited artist and title really match
            let credit = (rec["artist-credit"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
            guard Self.artistMatches(artist, credit), Self.titleMatches(title, rec["title"] as? String ?? "") else { continue }
            if let groups = rec["release-groups"] as? [[String: Any]] {
                for g in groups where groupIDs.count < 3 {
                    if let id = g["id"] as? String, !groupIDs.contains(id) {
                        groupIDs.append(id)
                    }
                }
            }
        }
        for id in groupIDs {
            // "front" is the original full-resolution image; "front-1200" a safe fallback.
            for endpoint in ["front", "front-1200"] {
                guard let url = URL(string: "https://coverartarchive.org/release-group/\(id)/\(endpoint)"),
                      let d = syncData(url, limit: Self.maxImageBytes), let size = Self.imageSize(d) else { continue }
                return ArtworkResult(data: d, width: size.0, height: size.1,
                                     source: "Cover Art Archive",
                                     trackName: nil, artistName: nil, albumName: nil)
            }
        }
        return nil
    }

    // MARK: - helpers

    /// Downloads at most `limit` bytes, over HTTPS only.
    private func syncData(_ url: URL, limit: Int) -> Data? {
        guard url.scheme == "https" else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = session.dataTask(with: url) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            guard http.url?.scheme == "https" else { return }
            guard http.expectedContentLength <= Int64(limit) else { return }
            guard let data = data, data.count <= limit else { return }
            result = data
        }
        task.resume()
        semaphore.wait()
        return result
    }

    /// Apple's artwork hosts: img.mzstatic.com, a1.mzstatic.com, ...
    static func isAppleArtwork(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".mzstatic.com") || host.hasSuffix(".apple.com")
    }

    /// -1 when the size cannot be read, so a missing file is not treated as small.
    static func localFileSize(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return -1 }
        return size.intValue
    }

    /// Reads pixel dimensions straight from the image bytes (PNG IHDR / JPEG SOF),
    /// trusting nothing: a damaged or hostile file gives nil, never a crash.
    static func imageSize(_ data: Data) -> (Int, Int)? {
        let bytes = [UInt8](data.prefix(524_288))
        guard bytes.count > 24 else { return nil }
        func sane(_ w: Int, _ h: Int) -> (Int, Int)? {
            guard (1...20000).contains(w), (1...20000).contains(h) else { return nil }
            return (w, h)
        }
        if bytes[0] == 0x89, bytes[1] == 0x50 { // PNG
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard bytes.count >= 16,
                  Array(bytes[0..<8]) == signature,
                  bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 // "IHDR"
            else { return nil }
            let w = (Int(bytes[16]) << 24) | (Int(bytes[17]) << 16) | (Int(bytes[18]) << 8) | Int(bytes[19])
            let h = (Int(bytes[20]) << 24) | (Int(bytes[21]) << 16) | (Int(bytes[22]) << 8) | Int(bytes[23])
            return sane(w, h)
        }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { // JPEG: scan markers for SOF
            var i = 2
            while i + 1 < bytes.count {
                guard bytes[i] == 0xFF else { i += 1; continue }
                let marker = bytes[i + 1]
                if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                    guard i + 8 < bytes.count else { return nil }
                    let h = (Int(bytes[i + 5]) << 8) | Int(bytes[i + 6])
                    let w = (Int(bytes[i + 7]) << 8) | Int(bytes[i + 8])
                    return sane(w, h)
                }
                if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                    i += 2
                    continue
                }
                guard i + 3 < bytes.count else { return nil }
                let len = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
                if len < 2 { return nil }
                i += 2 + len
            }
        }
        return nil
    }
}
