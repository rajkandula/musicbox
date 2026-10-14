import Foundation
import UIKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// Disk + memory cache for track artwork.
///
/// Disk: one JPEG (≤ 600 px, q 0.85) per track in `AppPaths.artworkCache`, named by the SHA-256
/// of the track ID. Memory: `NSCache` of decoded, downsampled images keyed "trackID|maxPixel".
/// Decoding always goes through ImageIO thumbnails, never full-size `UIImage` decodes.
/// All members are thread-safe.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    /// Largest edge of the stored artwork file.
    private static let storedMaxPixel = 600
    private static let storedJPEGQuality: CGFloat = 0.85

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private let fileManager = FileManager.default

    // MARK: Lock-protected state
    private let lock = NSLock()
    /// Pixel sizes currently held in `memory` per track (so every size can be invalidated).
    private var cachedSizes: [String: Set<Int>] = [:]
    /// Bumped whenever a track's artwork changes; stale decodes are not inserted into memory.
    private var generations: [String: UInt64] = [:]
    /// Bumped by `removeAll()`.
    private var epoch: UInt64 = 0
    /// Coalesces concurrent async requests for the same key.
    private var inFlight: [String: InFlightDecode] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private struct Token: Equatable {
        let epoch: UInt64
        let generation: UInt64
    }

    private struct InFlightDecode {
        let token: Token
        let task: Task<UIImage?, Never>
    }

    init() {
        directory = AppPaths.artworkCache
        memory.countLimit = 600
        memory.totalCostLimit = 64 * 1024 * 1024
        memory.name = "Musicbox.ArtworkCache"

        // UIApplication.didReceiveMemoryWarningNotification (raw name avoids main-actor isolation).
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.purgeMemory()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    // MARK: - Public API

    /// Downsamples to max 600x600, writes JPEG (q 0.85) to AppPaths.artworkCache/<sha>.jpg.
    /// Thread-safe; may be called from any thread. Invalid image data is ignored.
    func store(_ data: Data, for trackID: String) {
        guard !data.isEmpty,
              let jpeg = autoreleasepool(invoking: { Self.makeStoredJPEG(from: data) }) else {
            return
        }
        let url = fileURL(for: trackID)
        do {
            try write(jpeg, to: url)
        } catch {
            return
        }
        invalidateMemory(for: trackID)
    }

    func remove(for trackID: String) {
        try? fileManager.removeItem(at: fileURL(for: trackID))
        invalidateMemory(for: trackID)
    }

    func hasArtwork(for trackID: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: trackID).path)
    }

    /// Fast synchronous lookup (NSCache → disk). Returns nil if none. Safe on main thread for small images.
    func image(for trackID: String) -> UIImage? {
        let pixelSize = Self.storedMaxPixel
        let key = Self.cacheKey(trackID: trackID, pixelSize: pixelSize)
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        let token = currentToken(for: trackID)
        guard let image = decodeImage(at: fileURL(for: trackID), maxPixel: pixelSize) else {
            return nil
        }
        insert(image, key: key, trackID: trackID, pixelSize: pixelSize, token: token)
        return image
    }

    /// Async, downsampled to `maxPixel` (e.g. 120 for rows, 600 for now playing), memory cached per size.
    /// Disk access and decoding happen off the calling actor.
    func image(for trackID: String, maxPixel: CGFloat) async -> UIImage? {
        let pixelSize = Self.normalizedPixelSize(maxPixel)
        let key = Self.cacheKey(trackID: trackID, pixelSize: pixelSize)
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }

        let url = fileURL(for: trackID)
        let task: Task<UIImage?, Never> = withLock {
            let token = tokenLocked(for: trackID)
            if let existing = inFlight[key], existing.token == token {
                return existing.task
            }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> UIImage? in
                guard let self else { return nil }
                let image = self.decodeImage(at: url, maxPixel: pixelSize)
                self.finishDecode(image, key: key, trackID: trackID, pixelSize: pixelSize, token: token)
                return image
            }
            inFlight[key] = InFlightDecode(token: token, task: task)
            return task
        }
        return await task.value
    }

    func removeAll() {
        withLock {
            epoch &+= 1
            generations.removeAll()
            cachedSizes.removeAll()
            inFlight.removeAll()
            memory.removeAllObjects()
        }
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: - Memory cache bookkeeping

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Must be called with `lock` held.
    private func tokenLocked(for trackID: String) -> Token {
        Token(epoch: epoch, generation: generations[trackID] ?? 0)
    }

    private func currentToken(for trackID: String) -> Token {
        withLock { tokenLocked(for: trackID) }
    }

    private func insert(_ image: UIImage, key: String, trackID: String, pixelSize: Int, token: Token) {
        withLock {
            // Artwork changed while decoding: drop the stale image.
            guard tokenLocked(for: trackID) == token else { return }
            cachedSizes[trackID, default: []].insert(pixelSize)
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
    }

    private func finishDecode(_ image: UIImage?, key: String, trackID: String, pixelSize: Int, token: Token) {
        withLock {
            if let entry = inFlight[key], entry.token == token {
                inFlight[key] = nil
            }
            guard let image, tokenLocked(for: trackID) == token else { return }
            cachedSizes[trackID, default: []].insert(pixelSize)
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
    }

    private func invalidateMemory(for trackID: String) {
        withLock {
            generations[trackID, default: 0] &+= 1
            let sizes = cachedSizes.removeValue(forKey: trackID) ?? []
            for size in sizes {
                memory.removeObject(forKey: Self.cacheKey(trackID: trackID, pixelSize: size) as NSString)
            }
            let prefix = trackID + "|"
            for key in inFlight.keys where key.hasPrefix(prefix) {
                inFlight[key] = nil
            }
        }
    }

    private func purgeMemory() {
        withLock {
            cachedSizes.removeAll()
            memory.removeAllObjects()
        }
    }

    // MARK: - Disk

    private func fileURL(for trackID: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: trackID), isDirectory: false)
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // The Caches directory may have been purged; recreate it and retry once.
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    private func decodeImage(at url: URL, maxPixel: Int) -> UIImage? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let cgImage = Self.thumbnail(from: source, maxPixel: maxPixel) else {
                return nil
            }
            return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        }
    }

    // MARK: - Helpers

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func makeStoredJPEG(from data: Data) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let cgImage = thumbnail(from: source, maxPixel: storedMaxPixel) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: storedJPEGQuality]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    private static func normalizedPixelSize(_ maxPixel: CGFloat) -> Int {
        guard maxPixel.isFinite, maxPixel > 0 else { return storedMaxPixel }
        // The stored file is never larger than `storedMaxPixel`, so bigger requests share its entry.
        return min(max(Int(maxPixel.rounded(.up)), 1), storedMaxPixel)
    }

    private static func cacheKey(trackID: String, pixelSize: Int) -> String {
        "\(trackID)|\(pixelSize)"
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func fileName(for trackID: String) -> String {
        let digest = SHA256.hash(data: Data(trackID.utf8))
        var characters: [UInt8] = []
        characters.reserveCapacity(SHA256.byteCount * 2 + 4)
        for byte in digest {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        characters.append(contentsOf: Array(".jpg".utf8))
        return String(decoding: characters, as: UTF8.self)
    }
}
