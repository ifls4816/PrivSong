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

        let exactImage = url.flatMap { ArtworkImageCache.shared.image(for: $0.url) }
        let cachedImage = exactImage ?? url.flatMap { ArtworkImageCache.shared.fallbackImage(for: $0.url) }
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

        let url = resource.url
        if let cached = ArtworkImageCache.shared.image(for: url) {
            withoutAnimation {
                image = cached
                displayedURL = resource
            }
            return
        }

        if let fallback = ArtworkImageCache.shared.fallbackImage(for: url) {
            withoutAnimation {
                image = fallback
                displayedURL = nil
            }
        } else if displayedURL != resource {
            withoutAnimation {
                image = nil
                displayedURL = nil
            }
        }

        if let diskData = await ArtworkDiskCache.data(for: url),
           let cached = await ArtworkDecoder.image(from: diskData, url: url) {
            ArtworkImageCache.shared.insert(cached, for: url)
            withoutAnimation {
                image = cached
                displayedURL = resource
            }
            return
        }

        do {
            let (data, _) = try await ArtworkNetwork.session.data(for: resource.request)
            guard !Task.isCancelled,
                  let loaded = await ArtworkDecoder.image(from: data, url: url) else { return }
            ArtworkImageCache.shared.insert(loaded, for: url)
            await ArtworkDiskCache.insert(data, for: url)
            image = loaded
            displayedURL = resource
        } catch {
            withoutAnimation {
                image = nil
                displayedURL = nil
            }
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

@MainActor
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let normalizedCache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 80 * 1024 * 1024
        normalizedCache.countLimit = 300
        normalizedCache.totalCostLimit = 80 * 1024 * 1024
        normalizedKeys.countLimit = 2_000
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func fallbackImage(for url: URL) -> UIImage? {
        normalizedCache.object(forKey: normalizedCacheKey(for: url) as NSString)
    }

    func insert(_ image: UIImage, for url: URL) {
        let pixelCost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: pixelCost)
        normalizedCache.setObject(image, forKey: normalizedCacheKey(for: url) as NSString, cost: pixelCost)
    }

    func clear() {
        cache.removeAllObjects()
        normalizedCache.removeAllObjects()
    }

    /// Memoized because `ArtworkView.init` asks for it on every parent re-render, and parsing
    /// the URL each time adds up across a list of rows.
    private let normalizedKeys = NSCache<NSURL, NSString>()

    private func normalizedCacheKey(for url: URL) -> String {
        if let cached = normalizedKeys.object(forKey: url as NSURL) {
            return cached as String
        }
        let key = computeNormalizedCacheKey(for: url)
        normalizedKeys.setObject(key as NSString, forKey: url as NSURL)
        return key
    }

    private func computeNormalizedCacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let sizeKeys = Set(["maxheight", "maxwidth", "quality"])
        components.queryItems = components.queryItems?.filter { item in
            !sizeKeys.contains(item.name.lowercased())
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

/// Network access for artwork. ArtworkDiskCache already keeps every image, so these requests
/// skip the shared URLCache; going through it stored each image a second time on disk.
enum ArtworkNetwork {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

enum ArtworkDiskCache {
    private static let limitBytes: Int64 = 200 * 1024 * 1024

    static func data(for url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            let data = dataSync(for: url)
            if data != nil {
                DiskCacheMaintenance.markUsed(fileURL(for: url))
            }
            return data
        }.value
    }

    static func dataSync(for url: URL) -> Data? {
        let fileURL = fileURL(for: url)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Self-heal entries saved before validation existed (e.g. a server error page stored as
        // artwork): drop them so the image is downloaded again instead of missing forever.
        guard isImageData(data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return data
    }

    static func insert(_ data: Data, for url: URL) async {
        // Only real images are cached; an error response must never be stored as artwork.
        guard isImageData(data) else { return }
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try data.write(to: fileURL(for: url), options: [.atomic])
            } catch {
                print("[ArtworkDiskCache] Failed to save artwork: \(error.localizedDescription)")
            }
        }.value
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func totalSize() -> Int64 {
        DiskCacheMaintenance.size(of: directoryURL)
    }

    static func trimToLimit() {
        DiskCacheMaintenance.trim(directoryURL, toBytes: limitBytes)
    }

    /// Cheap header check (no full decode) that the bytes are a complete image.
    static func isImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetStatus(source) == .statusComplete
    }

    private static func fileURL(for url: URL) -> URL {
        directoryURL.appendingPathComponent(cacheKey(for: url)).appendingPathExtension("image")
    }

    private static func cacheKey(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for scalar in url.absoluteString.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static var directoryURL: URL {
        DiskCacheMaintenance.cachesBaseURL
            .appendingPathComponent("PrivSong", isDirectory: true)
            .appendingPathComponent("ArtworkCache", isDirectory: true)
    }
}
