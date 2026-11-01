import AudioToolbox
import Foundation

/// Converts WAV, AIFF or FLAC to Apple Lossless (.m4a) with macOS's own
/// AudioToolbox: the same Apple encoder XLD uses, so no XLD is needed
/// (research: docs/research-engine-and-updates.md, 1 Nov 2026; tested
/// bit-identical against the source and against XLD's output).
enum Converter {
    /// File extensions the app accepts.
    static let extensions: Set<String> = ["wav", "aif", "aiff", "flac", "mp3", "m4a"]
    /// Already-compressed files: kept as they are, tags and art only.
    static let compressed: Set<String> = ["mp3", "m4a"]

    static func accepts(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    static func isCompressed(_ url: URL) -> Bool { compressed.contains(url.pathExtension.lowercased()) }
    /// "MP3", "AAC" or "Apple Lossless" (an .m4a can hold either of the last two).
    static func formatName(_ url: URL) -> String {
        if url.pathExtension.lowercased() == "mp3" { return "MP3" }
        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &ref) == noErr, let f = ref else { return "AAC" }
        defer { ExtAudioFileDispose(f) }
        var d = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &size, &d)
        return d.mFormatID == kAudioFormatAppleLossless ? "Apple Lossless" : "AAC"
    }

    enum Failure: Error, CustomStringConvertible {
        case open(OSStatus), floatAudio, create(OSStatus), io(OSStatus)
        var description: String {
            switch self {
            case .open: return "Couldn’t read the file. Is it really a WAV, AIFF or FLAC?"
            case .floatAudio: return "This file holds 32-bit floating-point audio, which Apple Lossless can’t store."
            case .create(let s): return "Couldn’t create the Apple Lossless file (error \(s))."
            case .io(let s): return "The conversion stopped part-way (error \(s))."
            }
        }
    }

    /// Converts `input` to `output` (.m4a, Apple Lossless). `progress` gets 0...1.
    static func convert(_ input: URL, to output: URL, progress: (Double) -> Void) -> Result<Void, Failure> {
        var inRef: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(input as CFURL, &inRef)
        guard status == noErr, let inFile = inRef else { return .failure(.open(status)) }
        defer { ExtAudioFileDispose(inFile) }

        var src = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(inFile, kExtAudioFileProperty_FileDataFormat, &size, &src)
        guard status == noErr, src.mChannelsPerFrame > 0 else { return .failure(.open(status)) }
        if src.mFormatID == kAudioFormatLinearPCM && (src.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
            return .failure(.floatAudio)
        }

        // PCM (WAV/AIFF) states its bit depth; FLAC keeps it in the source bit depth
        // property. Without it a FLAC comes out labelled 32-bit and up to 3x larger.
        var bits = Int(src.mBitsPerChannel)
        if bits == 0 {
            var af: AudioFileID?
            var s = UInt32(MemoryLayout<AudioFileID?>.size)
            if ExtAudioFileGetProperty(inFile, kExtAudioFileProperty_AudioFile, &s, &af) == noErr, let af = af {
                var sbd: Int32 = 0
                var s4 = UInt32(MemoryLayout<Int32>.size)
                if AudioFileGetProperty(af, kAudioFilePropertySourceBitDepth, &s4, &sbd) == noErr { bits = Int(abs(sbd)) }
            }
        }

        var alac = AudioStreamBasicDescription()
        alac.mFormatID = kAudioFormatAppleLossless
        alac.mFormatFlags = [16: 1, 20: 2, 24: 3][bits] ?? 4   // same mapping as XLD
        alac.mSampleRate = src.mSampleRate
        alac.mChannelsPerFrame = src.mChannelsPerFrame

        try? FileManager.default.removeItem(at: output)
        var outRef: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(output as CFURL, kAudioFileM4AType, &alac, nil,
                                           AudioFileFlags.eraseFile.rawValue, &outRef)
        guard status == noErr, let outFile = outRef else { return .failure(.create(status)) }
        var closed = false
        defer { if !closed { ExtAudioFileDispose(outFile) } }

        // Packed signed 32-bit integer PCM on both sides: no rounding anywhere.
        let channels = src.mChannelsPerFrame
        var client = AudioStreamBasicDescription(
            mSampleRate: src.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileSetProperty(inFile, kExtAudioFileProperty_ClientDataFormat, size, &client)
        guard status == noErr else { return .failure(.io(status)) }
        status = ExtAudioFileSetProperty(outFile, kExtAudioFileProperty_ClientDataFormat, size, &client)
        guard status == noErr else { return .failure(.io(status)) }

        var totalFrames: Int64 = 0
        var s8 = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(inFile, kExtAudioFileProperty_FileLengthFrames, &s8, &totalFrames)

        let framesPerRead: UInt32 = 32768
        let byteCount = Int(framesPerRead * client.mBytesPerFrame)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { buffer.deallocate() }

        var done: Int64 = 0
        var lastReported = -1
        progress(0)
        while true {
            var frames = framesPerRead
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(byteCount), mData: buffer))
            status = ExtAudioFileRead(inFile, &frames, &list)
            guard status == noErr else { return .failure(.io(status)) }
            if frames == 0 { break }
            status = ExtAudioFileWrite(outFile, frames, &list)
            guard status == noErr else { return .failure(.io(status)) }
            done += Int64(frames)
            if totalFrames > 0 {
                let pct = Int(Double(done) / Double(totalFrames) * 100)
                if pct != lastReported { lastReported = pct; progress(min(1, Double(pct) / 100)) }
            }
        }
        status = ExtAudioFileDispose(outFile)
        closed = true
        guard status == noErr else { return .failure(.io(status)) }
        progress(1)
        return .success(())
    }
}
