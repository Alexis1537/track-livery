import AVFoundation
import Foundation

/// Writes the tags into the converted file with Apple's AVFoundation, copying
/// the audio unchanged (passthrough), so ffmpeg is no longer needed:
///   - the genre chosen in the window (Dance by default)
///   - the cover art is embedded as iTunes cover art (not a video track, which
///     made Music open a black player window in earlier versions)
///   - title / artist / album, plus year, track number, comment and BPM
///     carried over from the downloaded file
enum Tagger {
    static func tag(alacURL: URL, artwork: ArtworkResult?, source: SourceTags = SourceTags(), genre: String = "Dance",
                    artist: String, title: String, workDir: URL) -> URL? {
        let out = workDir.appendingPathComponent("tagged.m4a")
        try? FileManager.default.removeItem(at: out)

        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, _ type: String? = nil) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            if let type = type { m.dataType = type }
            return m
        }
        var meta = [item(.iTunesMetadataSongName, title as NSString),
                    item(.iTunesMetadataUserGenre, genre as NSString)]
        if !artist.isEmpty { meta.append(item(.iTunesMetadataArtist, artist as NSString)) }
        // the album named in the download beats the iTunes guess ("You Know" vs "You Know - Single")
        if let album = source.album ?? artwork?.albumName, !album.isEmpty { meta.append(item(.iTunesMetadataAlbum, album as NSString)) }
        if let year = source.year { meta.append(item(.iTunesMetadataReleaseDate, year as NSString)) }
        if let comment = source.comment { meta.append(item(.iTunesMetadataUserComment, comment as NSString)) }
        if let bpm = source.bpm, bpm > 0, bpm < 1000 {
            meta.append(item(.iTunesMetadataBeatsPerMin, NSNumber(value: Int16(bpm)), kCMMetadataBaseDataType_SInt16 as String))
        }
        if let track = source.track, track > 0, track < 65536 {
            // 'trkn' atom: 2 reserved bytes, track (UInt16), total (UInt16), 2 reserved bytes
            let bytes: [UInt8] = [0, 0, UInt8(track >> 8), UInt8(track & 0xFF), 0, 0, 0, 0]
            meta.append(item(.iTunesMetadataTrackNumber, Data(bytes) as NSData, kCMMetadataBaseDataType_RawData as String))
        }
        if let art = artwork {
            let isPNG = art.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            meta.append(item(.iTunesMetadataCoverArt, art.data as NSData,
                             (isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String))
        }

        guard let export = AVAssetExportSession(asset: AVURLAsset(url: alacURL),
                                                presetName: AVAssetExportPresetPassthrough) else { return nil }
        export.outputURL = out
        export.outputFileType = .m4a
        export.metadata = meta
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        done.wait()
        guard export.status == .completed, FileManager.default.fileExists(atPath: out.path) else { return nil }
        return out
    }
}
