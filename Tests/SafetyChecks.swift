import Foundation

@main
struct SafetyChecks {
    static func main() {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

        // A file that only starts like a PNG must be refused, not read.
        var truncated = [UInt8](repeating: 0, count: 25)
        truncated[0] = 0x89
        truncated[1] = 0x50
        precondition(ArtworkFetcher.imageSize(Data(truncated)) == nil, "truncated PNG accepted")

        // A real PNG header still reports its size.
        var header = pngSignature
        header += [0x00, 0x00, 0x00, 0x0D]
        header += Array("IHDR".utf8)
        header += [0x00, 0x00, 0x0B, 0xB8]   // width 3000
        header += [0x00, 0x00, 0x0B, 0xB8]   // height 3000
        header += [0x08, 0x06, 0x00, 0x00, 0x00]
        if let size = ArtworkFetcher.imageSize(Data(header)) {
            precondition(size == (3000, 3000), "PNG size wrong: \(size)")
        } else {
            preconditionFailure("valid PNG header refused")
        }

        // An impossible width (4294967295) must be refused.
        var huge = header
        huge[16] = 0xFF
        huge[17] = 0xFF
        huge[18] = 0xFF
        huge[19] = 0xFF
        precondition(ArtworkFetcher.imageSize(Data(huge)) == nil, "impossible PNG width accepted")

        // A JPEG with a bad segment length must be refused without crashing.
        var jpeg = [UInt8](repeating: 0, count: 30)
        jpeg[0] = 0xFF
        jpeg[1] = 0xD8
        jpeg[2] = 0xFF
        jpeg[3] = 0xC0
        jpeg[4] = 0x00
        jpeg[5] = 0x01
        precondition(ArtworkFetcher.imageSize(Data(jpeg)) == nil, "bad JPEG accepted")

        // BPM values that are not real numbers in range give nil.
        precondition(SourceTags.bpm("nan") == nil, "bpm(nan) accepted")
        precondition(SourceTags.bpm("inf") == nil, "bpm(inf) accepted")
        precondition(SourceTags.bpm("1e300") == nil, "bpm(1e300) accepted")
        precondition(SourceTags.bpm("0") == nil, "bpm(0) accepted")
        precondition(SourceTags.bpm("124.6") == 125, "bpm(124.6) wrong")

        // A remix never takes the original's cover, nor the original a remix's.
        precondition(!ArtworkFetcher.titleMatches("Roses (Imanbek Remix Extended)", "Roses"), "remix took original cover")
        precondition(ArtworkFetcher.titleMatches("Roses (Imanbek Remix Extended)", "Roses (Imanbek Remix)"), "remix cover refused")
        precondition(!ArtworkFetcher.titleMatches("Roses", "Roses (Imanbek Remix)"), "original took remix cover")
        precondition(ArtworkFetcher.titleMatches("Roses (Extended Mix)", "Roses"), "extended mix refused original cover")
        precondition(ArtworkFetcher.titleMatches("Cherry Moon (Radio Edit)", "Cherry Moon"), "radio edit refused original cover")

        print("SAFETY CHECKS PASSED")
    }
}
