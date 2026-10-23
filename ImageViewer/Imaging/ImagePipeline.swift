import CoreGraphics
import Foundation

/// Memory-bounded LRU cache of decoded images with in-flight de-duplication.
/// Lets navigation show already-decoded neighbors instantly and prefetch ahead of the user.
nonisolated final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    struct Key: Hashable, Sendable {
        let url: URL
        let page: Int
        let hdr: Bool
    }

    private let lock = NSLock()
    private var cache: [Key: DecodedImage] = [:]
    private var order: [Key] = []
    private var totalCost = 0
    private var inFlight: [Key: Task<DecodedImage, Error>] = [:]
    private let costLimit: Int = {
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        return min(max(physical / 6, 512 << 20), 4 << 30)
    }()

    func cached(_ url: URL, page: Int, hdr: Bool) -> DecodedImage? {
        let key = Key(url: url, page: page, hdr: hdr)
        return lock.withLock {
            guard let hit = cache[key] else { return nil }
            touchLocked(key)
            return hit
        }
    }

    func isCachedOrLoading(_ url: URL, page: Int, hdr: Bool) -> Bool {
        let key = Key(url: url, page: page, hdr: hdr)
        return lock.withLock { cache[key] != nil || inFlight[key] != nil }
    }

    func image(for url: URL, page: Int, hdr: Bool, priority: TaskPriority = .userInitiated) async throws -> DecodedImage {
        let key = Key(url: url, page: page, hdr: hdr)
        let (hit, task): (DecodedImage?, Task<DecodedImage, Error>?) = lock.withLock {
            if let hit = cache[key] {
                touchLocked(key)
                return (hit, nil)
            }
            if let existing = inFlight[key] { return (nil, existing) }
            let t = Task.detached(priority: priority) { () throws -> DecodedImage in
                try ImageDecoder.decode(url: url, page: page, allowHDR: hdr)
            }
            inFlight[key] = t
            return (nil, t)
        }
        if let hit { return hit }
        guard let task else { throw ImageDecodeError.unreadable }
        do {
            let image = try await task.value
            lock.withLock {
                inFlight[key] = nil
                insertLocked(image, for: key)
            }
            return image
        } catch {
            lock.withLock { inFlight[key] = nil }
            throw error
        }
    }

    func prefetch(_ urls: [URL], hdr: Bool) {
        for url in urls where !isCachedOrLoading(url, page: 0, hdr: hdr) {
            Task.detached(priority: .utility) {
                _ = try? await self.image(for: url, page: 0, hdr: hdr, priority: .utility)
            }
        }
    }

    func invalidate(_ url: URL) {
        lock.withLock {
            for key in cache.keys where key.url == url {
                if let img = cache.removeValue(forKey: key) { totalCost -= img.cost }
                order.removeAll { $0 == key }
            }
        }
    }

    func removeAll() {
        lock.withLock {
            cache.removeAll()
            order.removeAll()
            totalCost = 0
        }
    }

    private func touchLocked(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    private func insertLocked(_ image: DecodedImage, for key: Key) {
        if cache[key] != nil {
            touchLocked(key)
            return
        }
        cache[key] = image
        order.append(key)
        totalCost += image.cost
        while totalCost > costLimit, order.count > 1, let oldest = order.first, oldest != key {
            order.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) { totalCost -= evicted.cost }
        }
    }
}

/// LIFO concurrency limiter: the most recently requested work (what's on screen now) runs first.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) {
        available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeLast().resume()
        }
    }
}

nonisolated final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    enum Tier: Int, Sendable {
        case small = 160
        case large = 512
    }

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let limiter = AsyncLimiter(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

    init() {
        cache.totalCostLimit = 512 << 20
    }

    private func key(_ url: URL, _ tier: Tier) -> NSString {
        "\(tier.rawValue)|\(url.standardizedFileURL.path)" as NSString   // (one form for every spelling of a path)
    }

    func cached(_ url: URL, tier: Tier) -> CGImage? {
        cache.object(forKey: key(url, tier))?.image
    }

    /// Best available cached thumbnail, preferring the larger tier.
    func bestCached(_ url: URL) -> CGImage? {
        cached(url, tier: .large) ?? cached(url, tier: .small)
    }

    func thumbnail(for url: URL, tier: Tier) async -> CGImage? {
        if let hit = cached(url, tier: tier) { return hit }
        await limiter.acquire()
        if Task.isCancelled {
            await limiter.release()
            return nil
        }
        if let hit = cached(url, tier: tier) {
            await limiter.release()
            return hit
        }
        let size = tier.rawValue
        let image = await Task.detached(priority: .userInitiated) {
            ImageDecoder.thumbnail(url: url, maxPixelSize: size)
        }.value
        await limiter.release()
        if let image {
            cache.setObject(Box(image), forKey: key(url, tier), cost: image.bytesPerRow * image.height)
        }
        return image
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: key(url, .small))
        cache.removeObject(forKey: key(url, .large))
    }

    /// Thumbnails for a file this app just made, from the picture it made (reading a big file back, an
    /// upscaled animation or photo, takes a while and queues behind the folder's other thumbnails).
    func seed(_ image: CGImage, for url: URL) {
        for tier in [Tier.small, .large] {
            let thumb = VisionServices.downscaledSync(image, maxDimension: tier.rawValue)
            cache.setObject(Box(thumb), forKey: key(url, tier), cost: thumb.bytesPerRow * thumb.height)
        }
    }
}
