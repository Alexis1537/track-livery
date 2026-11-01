import AVFoundation
import AudioToolbox
import Foundation

/// Tags already inside the downloaded file, carried over into the converted
/// one. Beatport's WAVs keep album, year and track number
/// in the RIFF "LIST/INFO" chunk, which Apple's frameworks do not read, so WAV
/// gets a small reader; AIFF, FLAC, MP3 and M4A use AudioToolbox's info dictionary.
struct SourceTags {
    var title: String?
    var artist: String?
    var album: String?
    var year: String?
    var track: Int?
    var comment: String?
    var bpm: Int?
    var genre: String?

    static func read(_ url: URL) -> SourceTags {
        var t = SourceTags()
        if url.pathExtension.lowercased() == "wav" { t = riffInfo(url) }
        let d = infoDictionary(url)
        func s(_ k: String) -> String? {
            guard let v = d[k] else { return nil }
            let str = "\(v)".trimmingCharacters(in: .whitespacesAndNewlines)
            return str.isEmpty ? nil : str
        }
        t.title = t.title ?? s("title")
        t.artist = t.artist ?? s("artist")
        t.album = t.album ?? s("album")
        t.year = t.year ?? s("year") ?? s("recorded date")
        t.track = t.track ?? s("track number").flatMap { Int($0.split(separator: "/").first ?? "") }
        t.comment = t.comment ?? s("comments")
        t.genre = t.genre ?? s("genre")
        t.bpm = t.bpm ?? bpm(s("tempo"))
        // AIFF keeps ID3 and FLAC keeps Vorbis comments: AVFoundation reads both in full
        // (AudioToolbox misses the year, BPM and comment in some of them).
        let av = avTags(url)
        t.album = t.album ?? av["album"]
        t.year = t.year ?? av["year"]
        t.track = t.track ?? av["track"].flatMap { Int($0.split(separator: "/").first ?? "") }
        t.comment = t.comment ?? av["comment"]
        t.genre = t.genre ?? av["genre"]
        t.bpm = t.bpm ?? bpm(av["bpm"])
        if let y = t.year, y.count > 4, let four = y.range(of: #"\d{4}"#, options: .regularExpression) { t.year = String(y[four]) }
        return t
    }

    /// A BPM read from a tag, usable only when it is a real number in range:
    /// "nan", "inf", "1e300" and "0" give nil instead of a nonsense tempo.
    static func bpm(_ s: String?) -> Int? {
        guard let s = s, let value = Double(s), value.isFinite, value >= 1, value <= 999 else { return nil }
        return Int(value.rounded())
    }

    private static func avTags(_ url: URL) -> [String: String] {
        let keys: [String: String] = [
            "id3/TALB": "album", "id3/TDRC": "year", "id3/TYER": "year", "id3/TRCK": "track", "id3/TBPM": "bpm", "id3/COMM": "comment", "id3/TCON": "genre", "vorb/GENRE": "genre",
            "vorb/ALBUM": "album", "vorb/DATE": "year", "vorb/YEAR": "year", "vorb/TRACKNUMBER": "track", "vorb/BPM": "bpm",
            "vorb/COMMENT": "comment", "vorb/DESCRIPTION": "comment"]
        var out: [String: String] = [:]
        let asset = AVURLAsset(url: url)
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                guard let id = item.identifier?.rawValue, let key = keys[id], out[key] == nil else { continue }
                if let v = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { out[key] = v }
            }
        }
        return out
    }

    private static func infoDictionary(_ url: URL) -> [String: Any] {
        var af: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &af) == noErr, let f = af else { return [:] }
        defer { AudioFileClose(f) }
        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(f, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
              let d = dict?.takeRetainedValue() as? [String: Any] else { return [:] }
        return d
    }

    /// Reads the RIFF LIST/INFO chunk of a WAV (INAM title, IART artist, IPRD
    /// album, ICRD date, IPRT/ITRK track, ICMT comment). Reads only the chunk
    /// headers and the INFO chunk itself, never the audio.
    private static func riffInfo(_ url: URL) -> SourceTags {
        var t = SourceTags()
        guard let h = try? FileHandle(forReadingFrom: url) else { return t }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 12), head.count == 12,
              head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("WAVE".utf8) else { return t }
        var offset: UInt64 = 12
        for _ in 0..<64 {
            try? h.seek(toOffset: offset)
            guard let ch = try? h.read(upToCount: 8), ch.count == 8 else { break }
            let id = String(data: ch.prefix(4), encoding: .ascii) ?? ""
            let size = UInt64(ch[ch.startIndex + 4]) | UInt64(ch[ch.startIndex + 5]) << 8
                | UInt64(ch[ch.startIndex + 6]) << 16 | UInt64(ch[ch.startIndex + 7]) << 24
            if id == "LIST", size >= 4, size < 1_000_000, let body = try? h.read(upToCount: Int(size)),
               body.prefix(4) == Data("INFO".utf8) {
                var p = body.startIndex + 4
                while p + 8 <= body.endIndex {
                    let key = String(data: body[p..<p + 4], encoding: .ascii) ?? ""
                    let n = Int(body[p + 4]) | Int(body[p + 5]) << 8 | Int(body[p + 6]) << 16 | Int(body[p + 7]) << 24
                    guard n >= 0, p + 8 + n <= body.endIndex else { break }
                    let raw = body[p + 8..<p + 8 + n]
                    let value = (String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
                    if !value.isEmpty {
                        switch key {
                        case "INAM": t.title = value
                        case "IART": t.artist = value
                        case "IPRD": t.album = value
                        case "ICRD": t.year = value
                        case "IPRT", "ITRK": t.track = Int(value.split(separator: "/").first ?? "")
                        case "ICMT": t.comment = value
                        case "IGNR": t.genre = value
                        default: break
                        }
                    }
                    p += 8 + n + (n & 1)
                }
            }
            offset += 8 + size + (size & 1)
        }
        return t
    }
}
