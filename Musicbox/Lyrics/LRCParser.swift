import Foundation

/// Parses time-synced lyrics: LRC text (incl. enhanced / word-level LRC) and ID3v2 `SYLT` frames.
/// Pure, synchronous and thread-safe — call it off the main actor. Never traps on malformed input.
enum LRCParser {
    struct Result: Sendable {
        var lines: [LyricLine]
        var offset: TimeInterval
        var title: String?
        var artist: String?
    }

    // MARK: - LRC

    /// Parses LRC text. Supports: [mm:ss], [mm:ss.x], [mm:ss.xx], [mm:ss.xxx], [m:ss:xx] (colon
    /// centiseconds), [hh:mm:ss.xx], multiple stamps per line ([00:12.00][01:30.00]text), metadata
    /// tags ([ar:], [ti:], [al:], [by:], [length:], [offset:±ms] → `offset` in SECONDS, positive
    /// offset = lyrics appear earlier per LRC spec, so convert: effectiveTime = time - offset/1000),
    /// enhanced/word-level tags (<mm:ss.xx> inside text are stripped), BOM, CRLF, stray whitespace.
    /// Lines are sorted by time, ids re-assigned 0..<n; identical consecutive empty gaps collapsed.
    /// Returns nil if the text contains no time-stamped lines.
    static func parse(_ text: String) -> Result? {
        var entries: [TimedEntry] = []
        var offsetMilliseconds: Double = 0
        var title: String?
        var artist: String?

        for line in logicalLines(of: text, keepingEmpty: false) {
            let tags = leadingTags(of: line)
            for tag in tags.metadata {
                switch tag.key {
                case "ti":
                    if title == nil, !tag.value.isEmpty { title = tag.value }
                case "ar":
                    if artist == nil, !tag.value.isEmpty { artist = tag.value }
                case "offset":
                    if let value = offsetValue(tag.value) { offsetMilliseconds = value }
                default:
                    break
                }
            }
            guard !tags.stamps.isEmpty else { continue }
            let body = cleanLyricText(tags.remainder)
            for stamp in tags.stamps {
                entries.append(TimedEntry(time: stamp, text: body, order: entries.count))
            }
        }

        // A file made only of empty stamps (or only metadata) has no lyrics to show.
        guard entries.contains(where: { !$0.text.isEmpty }) else { return nil }

        let offset = offsetMilliseconds / 1000
        if offset != 0 {
            entries = entries.map { entry in
                TimedEntry(time: max(0, entry.time - offset), text: entry.text, order: entry.order)
            }
        }
        let lines = finalizedLines(from: entries)
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return Result(lines: lines, offset: offset, title: title, artist: artist)
    }

    /// True if the text looks like LRC (≥ 2 lines starting with a time stamp).
    static func looksLikeLRC(_ text: String) -> Bool {
        var stampedLines = 0
        for line in logicalLines(of: text, keepingEmpty: false) {
            let trimmed = line.drop(while: \.isWhitespace)
            guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { continue }
            let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            if timestamp(inner) != nil {
                stampedLines += 1
                if stampedLines >= 2 { return true }
            }
        }
        return false
    }

    /// Plain text from LRC (timestamps & metadata tags removed, gaps as blank lines).
    static func plainText(fromLRC text: String) -> String {
        if let result = parse(text) {
            return joinedPlainText(result.lines.map(\.text))
        }
        // Not parseable as synced lyrics: clean it line by line, keeping the author's blank lines.
        var output: [String] = []
        for line in logicalLines(of: text, keepingEmpty: true) {
            let tags = leadingTags(of: line)
            let body = cleanLyricText(tags.remainder)
            if body.isEmpty, tags.stamps.isEmpty, !tags.metadata.isEmpty { continue }   // pure metadata line
            output.append(body)
        }
        return joinedPlainText(output)
    }

    // MARK: - SYLT

    /// Decodes an ID3v2 SYLT frame payload (encoding byte, 3-byte language, timestamp format
    /// (2 = milliseconds; 1 = MPEG frames → unsupported → nil), content type, null-terminated
    /// descriptor, then repeated [null-terminated text in the frame encoding][UInt32 big-endian time]).
    /// Handles ISO-8859-1, UTF-16 with BOM, UTF-16BE, UTF-8. Returns nil when unusable.
    static func parseSYLT(_ data: Data) -> [LyricLine]? {
        var bytes = [UInt8](data)
        stripFrameHeaderIfPresent(&bytes)
        guard bytes.count >= 5 else { return nil }

        var candidates: [SYLTCandidate] = []

        // 1) Complete payload: encoding, language, timestamp format, content type, descriptor, items.
        if bytes.count >= 6, bytes[0] <= 3, isLanguageCode(bytes[1], bytes[2], bytes[3]),
           bytes[4] == 1 || bytes[4] == 2, bytes[5] <= 8 {
            // Timestamps in MPEG frames need the stream's frame rate; other content types aren't lyrics.
            guard bytes[4] == 2, acceptedContentTypes.contains(bytes[5]) else { return nil }
            let declared = SYLTEncoding(rawValue: bytes[0]) ?? .latin1
            // Fall back to other layouts only if the declared encoding doesn't fit the bytes.
            let alternatives = SYLTEncoding.guessOrder.filter { encoding in
                encoding != declared && !(encoding.isSingleByte && declared.isSingleByte)
            }
            for encoding in [declared] + alternatives {
                if let itemsStart = endOfTerminatedString(in: bytes, from: 6, encoding: encoding)?.next {
                    candidates.append(SYLTCandidate(encoding: encoding, itemsStart: itemsStart,
                                                    bonus: encoding == declared ? 0.5 : 0))
                }
            }
        }

        // 2) Payload whose encoding byte was consumed by the container: language first.
        if bytes.count >= 5, isLanguageCode(bytes[0], bytes[1], bytes[2]),
           bytes[3] == 1 || bytes[3] == 2, bytes[4] <= 8 {
            guard bytes[3] == 2, acceptedContentTypes.contains(bytes[4]) else { return nil }
            for encoding in SYLTEncoding.guessOrder {
                if let itemsStart = endOfTerminatedString(in: bytes, from: 5, encoding: encoding)?.next {
                    candidates.append(SYLTCandidate(encoding: encoding, itemsStart: itemsStart, bonus: 0.25))
                }
            }
        }

        // 3) Only the sync items (header fields exposed separately by the container).
        for encoding in SYLTEncoding.guessOrder {
            candidates.append(SYLTCandidate(encoding: encoding, itemsStart: 0, bonus: 0))
        }

        var best: (items: [SYLTItem], score: Double)?
        for candidate in candidates {
            guard let items = syncItems(in: bytes, from: candidate.itemsStart, encoding: candidate.encoding),
                  !items.isEmpty, let plausibility = plausibility(of: items), plausibility > 0 else { continue }
            let score = plausibility + candidate.bonus
            if score > (best?.score ?? -Double.infinity) {
                best = (items, score)
            }
        }
        guard let items = best?.items else { return nil }

        let lines = finalizedLines(from: lineEntries(fromSyncItems: items))
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return lines
    }

    // MARK: - LRC internals

    private struct TimedEntry {
        let time: TimeInterval
        let text: String
        let order: Int
    }

    private struct LeadingTags {
        var stamps: [TimeInterval] = []
        var metadata: [(key: String, value: String)] = []
        var remainder: Substring
    }

    /// Splits text into lines on any newline (LF, CRLF, CR, U+2028…), dropping BOMs and NULs.
    private static func logicalLines(of text: String, keepingEmpty: Bool) -> [Substring] {
        var cleaned = text
        if cleaned.contains("\u{FEFF}") {
            cleaned = cleaned.replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        if cleaned.contains("\u{0}") {
            cleaned = cleaned.replacingOccurrences(of: "\u{0}", with: "")
        }
        return cleaned.split(omittingEmptySubsequences: !keepingEmpty, whereSeparator: \.isNewline)
    }

    /// Reads the run of `[...]` tags at the start of a line: time stamps, then (only when the line has
    /// no stamps) metadata tags like `[ar:Artist]`. Stops at the first tag that is neither.
    private static func leadingTags(of line: Substring) -> LeadingTags {
        var tags = LeadingTags(remainder: line.drop(while: \.isWhitespace))
        while tags.remainder.first == "[" {
            let rest = tags.remainder
            guard let close = rest.firstIndex(of: "]") else { break }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            var tagEnd = close
            if let stamp = timestamp(inner) {
                tags.stamps.append(stamp)
            } else if tags.stamps.isEmpty, let tag = metadataTag(inner) {
                let afterTag = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
                if !afterTag.isEmpty, afterTag.first != "[", let lastClose = rest.lastIndex(of: "]"), lastClose > close,
                   let widened = metadataTag(rest[rest.index(after: rest.startIndex)..<lastClose]) {
                    // A value that itself contains brackets: "[ti:Song [Live] Version]".
                    tags.metadata.append(widened)
                    tagEnd = lastClose
                } else {
                    tags.metadata.append(tag)
                }
            } else {
                break
            }
            tags.remainder = rest[rest.index(after: tagEnd)...].drop(while: \.isWhitespace)
        }
        return tags
    }

    /// `key:value` metadata tag (`ar`, `ti`, `al`, `by`, `length`, `offset`, `#`, …). Key is lowercased.
    private static func metadataTag(_ inner: Substring) -> (key: String, value: String)? {
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let key = inner[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= 16, let first = key.unicodeScalars.first,
              first == "#" || (first.isASCII && CharacterSet.letters.contains(first)) else { return nil }
        let allowed = key.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "#" || scalar == "_" || scalar == "-")
        }
        guard allowed else { return nil }
        let value = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (key.lowercased(), value)
    }

    /// `[offset:+500]` value in milliseconds. Ignores garbage and absurd values (> 10 minutes).
    private static func offsetValue(_ raw: String) -> Double? {
        var text = raw.filter { !$0.isWhitespace }
        if text.hasPrefix("+") { text.removeFirst() }
        guard let value = Double(text), value.isFinite, abs(value) <= 600_000 else { return nil }
        return value
    }

    /// Parses the inside of a time tag: mm:ss, mm:ss.f…, m:ss:ff, hh:mm:ss.f…, hh:mm:ss:ff.
    /// Fractions of any length are decimal (".5" = 0.5 s, ".05" = 0.05 s, ".005" = 0.005 s);
    /// "," is accepted as a decimal separator. Negative stamps clamp to 0.
    private static func timestamp<S: StringProtocol>(_ raw: S) -> TimeInterval? {
        var bytes = Array(raw.utf8)
        while let last = bytes.last, last == 0x20 || last == 0x09 { bytes.removeLast() }
        while let first = bytes.first, first == 0x20 || first == 0x09 { bytes.removeFirst() }
        guard !bytes.isEmpty, bytes.count <= 24 else { return nil }

        var negative = false
        if bytes[0] == UInt8(ascii: "-") {
            negative = true
            bytes.removeFirst()
        } else if bytes[0] == UInt8(ascii: "+") {
            bytes.removeFirst()
        }

        var fields = bytes.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
        guard fields.count >= 2, fields.count <= 4 else { return nil }

        var fraction: ArraySlice<UInt8>?
        let lastField = fields[fields.count - 1]
        if let separator = lastField.firstIndex(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ",") }) {
            guard fields.count <= 3 else { return nil }
            fraction = lastField[lastField.index(after: separator)...]
            fields[fields.count - 1] = lastField[..<separator]
        } else if fields.count >= 3 {
            fraction = fields.removeLast()   // colon-separated hundredths: [m:ss:xx] / [hh:mm:ss:xx]
        }

        let hoursField: ArraySlice<UInt8>? = fields.count == 3 ? fields[0] : nil
        let minutesField = fields[fields.count - 2]
        let secondsField = fields[fields.count - 1]

        guard let minutes = integer(minutesField, maxDigits: 4),
              let seconds = integer(secondsField, maxDigits: 2) else { return nil }
        var total = Double(minutes) * 60 + Double(seconds)
        if let hoursField {
            guard let hours = integer(hoursField, maxDigits: 3), minutes < 60 else { return nil }
            total += Double(hours) * 3600
        }
        if let fraction, !fraction.isEmpty {
            guard fraction.count <= 9, let value = integer(fraction, maxDigits: 9) else { return nil }
            total += Double(value) / pow(10, Double(fraction.count))
        }
        guard total.isFinite else { return nil }
        return negative ? 0 : total
    }

    private static func integer(_ digits: ArraySlice<UInt8>, maxDigits: Int) -> Int? {
        guard !digits.isEmpty, digits.count <= maxDigits else { return nil }
        var value = 0
        for byte in digits {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    /// Removes enhanced/word-level stamps (`<mm:ss.xx>` and inline `[mm:ss.xx]`) and collapses whitespace.
    private static func cleanLyricText(_ text: Substring) -> String {
        var stripped = ""
        if text.contains(where: { $0 == "<" || $0 == "[" }) {
            stripped.reserveCapacity(text.utf8.count)
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character == "<" || character == "[" {
                    let closer: Character = character == "<" ? ">" : "]"
                    var probe = text.index(after: index)
                    var steps = 0
                    var closeIndex: Substring.Index?
                    while probe < text.endIndex, steps <= 26 {
                        let candidate = text[probe]
                        if candidate == closer { closeIndex = probe; break }
                        if candidate == character { break }
                        probe = text.index(after: probe)
                        steps += 1
                    }
                    if let closeIndex, timestamp(text[text.index(after: index)..<closeIndex]) != nil {
                        index = text.index(after: closeIndex)
                        continue
                    }
                }
                stripped.append(character)
                index = text.index(after: index)
            }
        } else {
            stripped = String(text)
        }
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Stable time sort, drops exact duplicates and redundant gaps, assigns ids 0..<n.
    private static func finalizedLines(from entries: [TimedEntry]) -> [LyricLine] {
        let sorted = entries.sorted { lhs, rhs in
            lhs.time != rhs.time ? lhs.time < rhs.time : lhs.order < rhs.order
        }
        var kept: [TimedEntry] = []
        kept.reserveCapacity(sorted.count)
        for entry in sorted {
            // A gap immediately replaced by a line at the same instant would never be visible.
            if let last = kept.last, last.text.isEmpty, !entry.text.isEmpty, abs(entry.time - last.time) < 0.001 {
                kept.removeLast()
            }
            if let last = kept.last {
                if entry.text.isEmpty && last.text.isEmpty { continue }                               // consecutive gaps
                if entry.text == last.text && abs(entry.time - last.time) < 0.001 { continue }        // duplicate stamp
            }
            kept.append(entry)
        }
        return kept.enumerated().map { index, entry in
            LyricLine(id: index, time: entry.time, text: entry.text)
        }
    }

    /// Joins lines as plain text: collapses runs of blank lines, trims blank lines at both ends.
    private static func joinedPlainText(_ lines: [String]) -> String {
        var output: [String] = []
        for line in lines {
            if line.isEmpty {
                if let last = output.last, !last.isEmpty { output.append("") }
            } else {
                output.append(line)
            }
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    // MARK: - SYLT internals

    private enum SYLTEncoding: UInt8 {
        case latin1 = 0, utf16WithBOM = 1, utf16BigEndian = 2, utf8 = 3

        /// Encodings to try when the payload doesn't say (single-byte first: most common).
        static let guessOrder: [SYLTEncoding] = [.utf8, .utf16WithBOM, .utf16BigEndian]

        var isSingleByte: Bool { self == .latin1 || self == .utf8 }
    }

    private struct SYLTCandidate {
        let encoding: SYLTEncoding
        let itemsStart: Int
        let bonus: Double
    }

    private struct SYLTItem {
        let text: String
        let milliseconds: UInt32
    }

    /// 0 = other, 1 = lyrics, 2 = text transcription. Chords, events, URLs etc. aren't lyrics.
    private static let acceptedContentTypes: Set<UInt8> = [0, 1, 2]

    /// Drops a leading "SYLT" (ID3v2.3/2.4) or "SLT" (ID3v2.2) frame header if the container kept it,
    /// honouring the v2.4 data-length-indicator and unsynchronisation flags.
    private static func stripFrameHeaderIfPresent(_ bytes: inout [UInt8]) {
        if bytes.count >= 10, bytes[0] == 0x53, bytes[1] == 0x59, bytes[2] == 0x4C, bytes[3] == 0x54 {
            let formatFlags = bytes[9]
            var headerLength = 10
            if formatFlags & 0x01 != 0, bytes.count >= 14 { headerLength += 4 }   // data length indicator
            bytes.removeFirst(headerLength)
            if formatFlags & 0x02 != 0 { bytes = removingUnsynchronisation(bytes) }
        } else if bytes.count >= 6, bytes[0] == 0x53, bytes[1] == 0x4C, bytes[2] == 0x54 {
            bytes.removeFirst(6)
        }
    }

    /// Reverses ID3 unsynchronisation ($FF $00 → $FF).
    private static func removingUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            output.append(bytes[index])
            if bytes[index] == 0xFF, index + 1 < bytes.count, bytes[index + 1] == 0x00 {
                index += 2
            } else {
                index += 1
            }
        }
        return output
    }

    /// ISO-639-2 code ("eng"), "XXX", or zero/space filler.
    private static func isLanguageCode(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Bool {
        func isLetter(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }
        if isLetter(a) && isLetter(b) && isLetter(c) { return true }
        return (a == 0 && b == 0 && c == 0) || (a == 0x20 && b == 0x20 && c == 0x20)
    }

    /// Finds the terminator of a string starting at `start`: $00 for single-byte encodings, an
    /// aligned $00 00 for UTF-16. Returns the text byte range end and the index after the terminator.
    private static func endOfTerminatedString(
        in bytes: [UInt8], from start: Int, encoding: SYLTEncoding
    ) -> (textEnd: Int, next: Int)? {
        guard start >= 0, start <= bytes.count else { return nil }
        if encoding.isSingleByte {
            var index = start
            while index < bytes.count {
                if bytes[index] == 0 { return (index, index + 1) }
                index += 1
            }
            return nil
        }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 { return (index, index + 2) }
            index += 2
        }
        return nil
    }

    /// Reads [text][UInt32 BE time] pairs until the end of the payload. Nil if the structure breaks.
    private static func syncItems(in bytes: [UInt8], from start: Int, encoding: SYLTEncoding) -> [SYLTItem]? {
        var items: [SYLTItem] = []
        var index = start
        var utf16BigEndian = encoding == .utf16BigEndian ? true : guessUTF16BigEndian(bytes, from: start)
        while index < bytes.count {
            if bytes[index] == 0, bytes[index...].allSatisfy({ $0 == 0 }) { break }   // trailing padding
            guard let (textEnd, next) = endOfTerminatedString(in: bytes, from: index, encoding: encoding),
                  next + 4 <= bytes.count else { return nil }
            let text = decodeString(bytes[index..<textEnd], encoding: encoding, bigEndian: &utf16BigEndian)
            let milliseconds = UInt32(bytes[next]) << 24 | UInt32(bytes[next + 1]) << 16
                | UInt32(bytes[next + 2]) << 8 | UInt32(bytes[next + 3])
            items.append(SYLTItem(text: text, milliseconds: milliseconds))
            index = next + 4
        }
        return items
    }

    /// Endianness for UTF-16 text without a BOM, judged from where the zero bytes of ASCII text sit.
    private static func guessUTF16BigEndian(_ bytes: [UInt8], from start: Int) -> Bool {
        var zerosAtEven = 0
        var zerosAtOdd = 0
        var index = start
        let limit = min(bytes.count, start + 64)
        while index < limit {
            if bytes[index] == 0 {
                if (index - start) % 2 == 0 { zerosAtEven += 1 } else { zerosAtOdd += 1 }
            }
            index += 1
        }
        return zerosAtEven > zerosAtOdd
    }

    private static func decodeString(
        _ slice: ArraySlice<UInt8>, encoding: SYLTEncoding, bigEndian: inout Bool
    ) -> String {
        switch encoding {
        case .latin1:
            // Many taggers write UTF-8 while declaring Latin-1; valid multi-byte UTF-8 is a safe tell.
            if slice.contains(where: { $0 >= 0x80 }), let utf8 = String(bytes: slice, encoding: .utf8) {
                return utf8
            }
            return latin1String(slice)
        case .utf8:
            return String(bytes: slice, encoding: .utf8) ?? latin1String(slice)
        case .utf16WithBOM, .utf16BigEndian:
            var body = slice
            if body.count >= 2 {
                let first = body[body.startIndex]
                let second = body[body.startIndex + 1]
                if first == 0xFF && second == 0xFE {
                    bigEndian = false
                    body = body.dropFirst(2)
                } else if first == 0xFE && second == 0xFF {
                    bigEndian = true
                    body = body.dropFirst(2)
                }
            }
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2)
            var index = body.startIndex
            while index + 1 < body.endIndex {
                let high = bigEndian ? body[index] : body[index + 1]
                let low = bigEndian ? body[index + 1] : body[index]
                units.append(UInt16(high) << 8 | UInt16(low))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
    }

    private static func latin1String(_ slice: ArraySlice<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in slice { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }

    /// How believable a decoding is: ordered times and clean text score higher (max 1; a decoding
    /// with half its items garbled scores ≤ 0 and is rejected).
    /// Nil when a time is beyond 24 h, which only a wrong decoding produces.
    private static func plausibility(of items: [SYLTItem]) -> Double? {
        let maxMilliseconds: UInt32 = 24 * 60 * 60 * 1000
        guard items.allSatisfy({ $0.milliseconds <= maxMilliseconds }) else { return nil }
        var ordered = 0
        for index in items.indices.dropFirst() where items[index].milliseconds >= items[index - 1].milliseconds {
            ordered += 1
        }
        let orderedRatio = items.count > 1 ? Double(ordered) / Double(items.count - 1) : 1
        let garbled = items.filter { item in
            item.text.unicodeScalars.contains { scalar in
                scalar == "\u{FFFD}" || (scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t")
                    || (scalar.value >= 0x7F && scalar.value < 0xA0)
            }
        }.count
        return orderedRatio - 2 * Double(garbled) / Double(items.count)
    }

    /// Turns sync items into line entries. Items are usually whole lines; when the writer used
    /// syllable items with line feeds marking new lines (per the ID3 spec), syllables are joined.
    private static func lineEntries(fromSyncItems items: [SYLTItem]) -> [TimedEntry] {
        let texts = items.map { item in
            item.text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\u{0}", with: "")
        }
        let startsWithBreak = texts.map { $0.first?.isNewline ?? false }
        let endsWithBreak = texts.map { $0.last?.isNewline ?? false }
        let usesLineMarkers = startsWithBreak.dropFirst().contains(true) || endsWithBreak.dropLast().contains(true)

        func entry(_ text: String, _ milliseconds: UInt32, _ order: Int) -> TimedEntry {
            TimedEntry(time: Double(milliseconds) / 1000,
                       text: text.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                       order: order)
        }

        guard usesLineMarkers else {
            return items.indices.map { entry(texts[$0], items[$0].milliseconds, $0) }
        }

        var entries: [TimedEntry] = []
        var currentText = ""
        var currentStart: UInt32?
        var breakPending = true
        for index in items.indices {
            if startsWithBreak[index] || breakPending, let start = currentStart {
                entries.append(entry(currentText, start, entries.count))
                currentStart = nil
            }
            if currentStart == nil {
                currentStart = items[index].milliseconds
                currentText = ""
            }
            currentText += texts[index]
            breakPending = endsWithBreak[index]
        }
        if let start = currentStart {
            entries.append(entry(currentText, start, entries.count))
        }
        return entries
    }
}
