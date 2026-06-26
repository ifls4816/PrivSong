import ImageIO
import SwiftUI
import UIKit

@MainActor
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var showsPlaceholder = true
    @State private var image: UIImage?
    @State private var displayedURL: URL?

    init(url: URL?, cornerRadius: CGFloat = 8, showsPlaceholder: Bool = true) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.showsPlaceholder = showsPlaceholder

        let exactImage = url.flatMap { ArtworkImageCache.shared.image(for: $0) }
        let cachedImage = exactImage ?? url.flatMap { ArtworkImageCache.shared.fallbackImage(for: $0) }
        _image = State(initialValue: cachedImage)
        _displayedURL = State(initialValue: exactImage == nil ? nil : url)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if showsPlaceholder {
                    placeholder
                } else {
                    Color.clear
                }
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipped()
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
    private func loadImage(from url: URL?) async {
        guard let url else {
            image = nil
            displayedURL = nil
            return
        }

        if displayedURL == url, image != nil {
            return
        }

        if let cached = ArtworkImageCache.shared.image(for: url) {
            withoutAnimation {
                image = cached
                displayedURL = url
            }
            return
        }

        if let fallback = ArtworkImageCache.shared.fallbackImage(for: url) {
            withoutAnimation {
                image = fallback
                displayedURL = nil
            }
        } else if displayedURL != url {
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
                displayedURL = url
            }
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled,
                  let loaded = await ArtworkDecoder.image(from: data, url: url) else { return }
            ArtworkImageCache.shared.insert(loaded, for: url)
            await ArtworkDiskCache.insert(data, for: url)
            image = loaded
            displayedURL = url
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

private enum ArtworkDecoder {
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

    private func normalizedCacheKey(for url: URL) -> String {
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

enum ArtworkDiskCache {
    static func data(for url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            dataSync(for: url)
        }.value
    }

    static func dataSync(for url: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    static func insert(_ data: Data, for url: URL) async {
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PrivSong", isDirectory: true)
            .appendingPathComponent("ArtworkCache", isDirectory: true)
    }
}
