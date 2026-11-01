import Foundation

/// Writes title, artist, album, genre and cover art into an MP3's ID3v2 tag
/// without touching the audio (compressed files keep their
/// format; only tags and art are added). Apple's frameworks cannot write MP3
/// tags, so this small writer follows the ID3v2.3 / v2.4 specification
/// (id3.org). Every other frame already in the file (BPM, key, label, ISRC,
/// comments...) is kept as it is.
enum ID3Writer {
    private static let replaced: Set<String> = ["TIT2", "TPE1", "TALB", "TCON", "APIC"]

    /// Writes `source` with the new tags to `destination`. Returns false on failure.
    static func write(source: URL, destination: URL, title: String, artist: String,
                      album: String?, genre: String, art: Data?) -> Bool {
        guard let file = try? Data(contentsOf: source) else { return false }
        var version: UInt8 = 3
        var keptFrames = Data()
        var audioStart = 0

        if file.count >= 10, file.prefix(3) == Data("ID3".utf8) {
            let major = file[3], flags = file[5]
            let tagSize = syncsafe(file, 6)
            let footer = (major == 4 && flags & 0x10 != 0) ? 10 : 0
            audioStart = min(file.count, 10 + tagSize + footer)
            // Frames can only be copied safely from a plain v2.3/v2.4 tag
            // (no whole-tag unsynchronisation, no extended header).
            if (major == 3 || major == 4) && flags & 0xC0 == 0 {
                version = major
                var p = 10
                let end = min(file.count, 10 + tagSize)
                while p + 10 <= end {
                    let id = String(data: file[p..<p + 4], encoding: .ascii) ?? ""
                    guard id.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) != nil else { break } // padding
                    let size = major == 4 ? syncsafe(file, p + 4) : bigEndian(file, p + 4)
                    guard size >= 0, p + 10 + size <= end else { break }
                    if !replaced.contains(id) { keptFrames.append(file[p..<p + 10 + size]) }
                    p += 10 + size
                }
            }
        }

        var frames = Data()
        frames.append(textFrame("TIT2", title, version))
        if !artist.isEmpty { frames.append(textFrame("TPE1", artist, version)) }
        if let album = album, !album.isEmpty { frames.append(textFrame("TALB", album, version)) }
        frames.append(textFrame("TCON", genre, version))
        if let art = art {
            let isPNG = art.starts(with: [0x89, 0x50, 0x4E, 0x47])
            var body = Data([0x00])                                    // ISO-8859-1 for the fields below
            body.append(Data((isPNG ? "image/png" : "image/jpeg").utf8)); body.append(0)
            body.append(0x03)                                          // picture type: front cover
            body.append(0)                                             // empty description
            body.append(art)
            frames.append(frame("APIC", body, version))
        }
        frames.append(keptFrames)
        frames.append(Data(count: 1024))                               // padding for later edits

        var out = Data("ID3".utf8)
        out.append(contentsOf: [version, 0, 0])
        out.append(syncsafeBytes(frames.count))
        out.append(frames)
        out.append(file[audioStart...])
        do { try out.write(to: destination, options: .atomic) } catch { return false }
        return true
    }

    private static func textFrame(_ id: String, _ text: String, _ version: UInt8) -> Data {
        var body = Data()
        if version == 4 {
            body.append(0x03)                                          // UTF-8
            body.append(Data(text.utf8))
        } else {
            body.append(0x01)                                          // UTF-16 with byte-order mark
            body.append(contentsOf: [0xFF, 0xFE])
            body.append(text.data(using: .utf16LittleEndian) ?? Data())
        }
        return frame(id, body, version)
    }

    private static func frame(_ id: String, _ body: Data, _ version: UInt8) -> Data {
        var f = Data(id.utf8)
        f.append(version == 4 ? syncsafeBytes(body.count) : bigEndianBytes(body.count))
        f.append(contentsOf: [0, 0])
        f.append(body)
        return f
    }

    private static func syncsafe(_ d: Data, _ i: Int) -> Int {
        guard i + 4 <= d.count else { return 0 }
        let b = d.startIndex + i
        return Int(d[b] & 0x7F) << 21 | Int(d[b + 1] & 0x7F) << 14 | Int(d[b + 2] & 0x7F) << 7 | Int(d[b + 3] & 0x7F)
    }

    private static func bigEndian(_ d: Data, _ i: Int) -> Int {
        guard i + 4 <= d.count else { return 0 }
        let b = d.startIndex + i
        return Int(d[b]) << 24 | Int(d[b + 1]) << 16 | Int(d[b + 2]) << 8 | Int(d[b + 3])
    }

    private static func syncsafeBytes(_ n: Int) -> Data {
        Data([UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
    }

    private static func bigEndianBytes(_ n: Int) -> Data {
        Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }
}
