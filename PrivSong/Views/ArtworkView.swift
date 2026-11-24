import ImageIO
import SwiftUI
import UIKit

@MainActor
struct ArtworkView: View {
    let url: AuthenticatedURL?
    var cornerRadius: CGFloat = 8
    var showsPlaceholder = true
    @State private var image: UIImage?
    @State private var displayedURL: AuthenticatedURL?

    init(url: AuthenticatedURL?, cornerRadius: CGFloat = 8, showsPlaceholder: Bool = true) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.showsPlaceholder = showsPlaceholder

        let exactImage = url.flatMap { ArtworkLoader.shared.cachedImage(for: $0) }
        let cachedImage = exactImage ?? url.flatMap { ArtworkLoader.shared.cachedImage(for: $0, allowsFallback: true) }
        _image = State(initialValue: cachedImage)
        _displayedURL = State(initialValue: exactImage == nil ? nil : url)
    }

    var body: some View {
        // Color.clear takes the proposed size; the overlay fills it and the clip trims the
        // overflow. Same result as measuring with a GeometryReader, without one per artwork.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if showsPlaceholder {
                    placeholder
                }
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
            .task(id: url) {
                await loadImage(from: url)
            }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [.musicRed.opacity(0.9), .pink.opacity(0.65), .orange.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            }
    }

    @MainActor
    private func loadImage(from resource: AuthenticatedURL?) async {
        guard let resource else {
            image = nil
            displayedURL = nil
            return
        }

        if displayedURL == resource, image != nil {
            return
        }

        if let cached = ArtworkLoader.shared.cachedImage(for: resource) {
            withoutAnimation {
                image = cached
                displayedURL = resource
            }
            return
        }

        if displayedURL != resource {
            withoutAnimation {
                image = ArtworkLoader.shared.cachedImage(for: resource, allowsFallback: true)
                displayedURL = nil
            }
        }

        guard let loaded = await ArtworkLoader.shared.image(for: resource), !Task.isCancelled else { return }
        withoutAnimation {
            image = loaded
            displayedURL = resource
        }
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
}

enum ArtworkDecoder {
    static func image(from data: Data, url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                if let maxPixelSize = maxPixelSize(from: url),
                   let imageSource = CGImageSourceCreateWithData(data as CFData, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ]
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        return UIImage(cgImage: cgImage)
                    }
                }
                return UIImage(data: data)
            }
        }.value
    }

    private static func maxPixelSize(from url: URL) -> Int? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let sizeValues = components.queryItems?.compactMap { item -> Int? in
            let name = item.name.lowercased()
            guard name == "maxwidth" || name == "maxheight",
                  let value = item.value,
                  let size = Int(value),
                  size > 0 else {
                return nil
            }
            return size
        } ?? []

        return sizeValues.max()
    }
}

private struct ArtworkCacheKey: Hashable, Sendable {
    let url: URL
    let scope: String?

    init(_ resource: AuthenticatedURL) {
        url = resource.url
        scope = resource.artworkCacheScope
    }

    var memoryKey: NSString {
        "\(scope ?? "")\n\(url.absoluteString)" as NSString
    }
}

@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let images = NSCache<NSString, UIImage>()
    private let fallbackKeys = NSCache<NSString, NSString>()
    private let normalizedKeys = NSCache<NSString, NSString>()
    private var inFlight: [ArtworkCacheKey: Task<UIImage?, Never>] = [:]
    private var bytesSinceTrim = 0
    private let session: URLSession

    private init() {
        images.countLimit = 300
        images.totalCostLimit = 80 * 1024 * 1024
        fallbackKeys.countLimit = 300
        normalizedKeys.countLimit = 2_000

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func cachedImage(for resource: AuthenticatedURL, allowsFallback: Bool = false) -> UIImage? {
        let key = ArtworkCacheKey(resource)
        if let image = images.object(forKey: key.memoryKey) { return image }
        guard allowsFallback, let fallback = fallbackKeys.object(forKey: normalizedKey(for: key)) else { return nil }
        return images.object(forKey: fallback)
    }

    func image(for resource: AuthenticatedURL) async -> UIImage? {
        if let cached = cachedImage(for: resource) { return cached }
        let key = ArtworkCacheKey(resource)
        if let pending = inFlight[key] { return await pending.value }

        let task = Task { [self] in
            let image = await fetchImage(for: resource, key: key)
            guard !Task.isCancelled else { return nil as UIImage? }
            inFlight[key] = nil
            if let image {
                let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
                images.setObject(image, forKey: key.memoryKey, cost: cost)
                fallbackKeys.setObject(key.memoryKey, forKey: normalizedKey(for: key))
            }
            return image
        }
        inFlight[key] = task
        return await task.value
    }

    func clear(scope: String) {
        for key in Array(inFlight.keys) where key.scope == scope {
            inFlight.removeValue(forKey: key)?.cancel()
        }
        images.removeAllObjects()
        fallbackKeys.removeAllObjects()
        normalizedKeys.removeAllObjects()
        ArtworkDiskCache.clear(scope: scope)
    }

    private func fetchImage(for resource: AuthenticatedURL, key: ArtworkCacheKey) async -> UIImage? {

        if let diskData = await ArtworkDiskCache.data(for: key) {
            if let image = await ArtworkDecoder.image(from: diskData, url: key.url) {
                return image
            }
            if !Task.isCancelled { ArtworkDiskCache.remove(key) }
        }

        guard !Task.isCancelled else { return nil }
        do {
            let (data, response) = try await session.data(for: resource.request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  !Task.isCancelled,
                  let image = await ArtworkDecoder.image(from: data, url: key.url),
                  !Task.isCancelled else { return nil }
            bytesSinceTrim += data.count
            let shouldTrim = bytesSinceTrim >= 16 * 1024 * 1024
            if shouldTrim { bytesSinceTrim = 0 }
            ArtworkDiskCache.insert(data, for: key, trimsAfterWrite: shouldTrim)
            return image
        } catch {
            return nil
        }
    }

    private func normalizedKey(for key: ArtworkCacheKey) -> NSString {
        let exact = key.memoryKey
        if let cached = normalizedKeys.object(forKey: exact) { return cached }
        guard var components = URLComponents(url: key.url, resolvingAgainstBaseURL: false) else {
            return exact
        }
        let sizeKeys = Set(["maxheight", "maxwidth", "quality"])
        components.queryItems = components.queryItems?.filter { !sizeKeys.contains($0.name.lowercased()) }
        let normalized = "\(key.scope ?? "")\n\(components.string ?? key.url.absoluteString)" as NSString
        normalizedKeys.setObject(normalized, forKey: exact)
        return normalized
    }
}

enum ArtworkDiskCache {
    private static let limitBytes: Int64 = 200 * 1024 * 1024
    private static let queue = DispatchQueue(label: "PrivSong.artwork-cache", qos: .utility)

    fileprivate static func data(for key: ArtworkCacheKey) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                let url = fileURL(for: key)
                let hasImageTag = URLComponents(url: key.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "Tag" }) == true
                if !hasImageTag, let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                   Date().timeIntervalSince(createdAt) > 7 * 24 * 60 * 60 {
                    try? FileManager.default.removeItem(at: url)
                }
                let data = try? Data(contentsOf: url)
                if data != nil { DiskCacheMaintenance.markUsed(url) }
                continuation.resume(returning: data)
            }
        }
    }

    fileprivate static func insert(_ data: Data, for key: ArtworkCacheKey, trimsAfterWrite: Bool) {
        queue.async {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete else { return }
            let url = fileURL(for: key)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            } catch {
                print("[ArtworkDiskCache] Failed to save artwork: \(error.localizedDescription)")
            }
            if trimsAfterWrite { DiskCacheMaintenance.trim(directoryURL, toBytes: limitBytes) }
        }
    }

    fileprivate static func remove(_ key: ArtworkCacheKey) {
        queue.async { try? FileManager.default.removeItem(at: fileURL(for: key)) }
    }

    static func clear(scope: String) {
        queue.async {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(scope, isDirectory: true))
        }
    }

    static func trimToLimit() {
        queue.async { DiskCacheMaintenance.trim(directoryURL, toBytes: limitBytes) }
    }

    private static func fileURL(for key: ArtworkCacheKey) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return directoryURL.appendingPathComponent(key.scope ?? "Unscoped", isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16)).appendingPathExtension("image")
    }

    private static var directoryURL: URL {
        DiskCacheMaintenance.cachesBaseURL
            .appendingPathComponent("PrivSong", isDirectory: true)
            .appendingPathComponent("ArtworkCache", isDirectory: true)
    }
}
