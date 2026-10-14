import Foundation
import UniformTypeIdentifiers

/// The file types Musicbox can play.
///
/// Only formats that AVFoundation decodes natively on iOS are listed. Containers AVPlayer cannot
/// open on iOS 17 (Ogg / Opus, WMA, Matroska, raw ALAC, …) and DRM-protected files (.m4p) are
/// deliberately excluded so they never show up as broken tracks.
enum SupportedMedia {
    /// Lowercased audio file extensions (no leading dot).
    static let audioExtensions: Set<String> = [
        "mp3", "mp2",                   // MPEG audio layer III / II
        "m4a", "m4b", "m4r",            // MPEG-4 audio (AAC / ALAC), audiobooks, ringtones
        "aac", "adts",                  // raw AAC (ADTS)
        "wav", "wave",                  // PCM WAVE
        "aif", "aiff", "aifc",          // AIFF
        "caf",                          // Core Audio Format (also carries Opus on iOS)
        "flac",                         // Free Lossless Audio Codec
        "ac3", "eac3", "ec3",           // Dolby Digital / Dolby Digital Plus
        "amr",                          // Adaptive Multi-Rate voice recordings
    ]

    /// Lowercased video file extensions (no leading dot). These play as audio by default.
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "3g2"]

    /// Returns the media kind for a file extension (case-insensitive, leading dot tolerated),
    /// or nil if the extension is not playable.
    static func kind(forExtension ext: String) -> MediaKind? {
        var normalized = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix(".") { normalized.removeFirst() }
        guard !normalized.isEmpty else { return nil }
        if audioExtensions.contains(normalized) { return .audio }
        if videoExtensions.contains(normalized) { return .video }
        return nil
    }

    /// Content types offered by the "Import Files…" document picker.
    static var importableTypes: [UTType] { cachedImportableTypes }

    // MARK: - Private

    private static let cachedImportableTypes: [UTType] = {
        var result: [UTType] = []
        var seen = Set<String>()

        func append(_ type: UTType) {
            if seen.insert(type.identifier).inserted {
                result.append(type)
            }
        }

        let baseTypes: [UTType] = [
            .audio, .mp3, .mpeg4Audio, .wav, .aiff,
            .movie, .mpeg4Movie, .quickTimeMovie, .video,
        ]
        baseTypes.forEach(append)

        // Concrete types for every supported extension (flac, m4b, caf, ac3, amr, 3gp, …).
        // Dynamic (unregistered) types are useless to the document picker, so skip them.
        let extensions = audioExtensions.sorted() + videoExtensions.sorted()
        extensions
            .compactMap { UTType(filenameExtension: $0) }
            .filter { !$0.isDynamic }
            .forEach(append)

        return result
    }()
}
