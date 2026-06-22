import SwiftUI
import UIKit

@MainActor
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    @State private var image: UIImage?
    @State private var displayedURL: URL?

    init(url: URL?, cornerRadius: CGFloat = 8) {
        self.url = url
        self.cornerRadius = cornerRadius

        let cachedImage = url.flatMap { ArtworkImageCache.shared.image(for: $0) }
        _image = State(initialValue: cachedImage)
        _displayedURL = State(initialValue: cachedImage == nil ? nil : url)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
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

        if displayedURL != url {
            withoutAnimation {
                image = nil
                displayedURL = nil
            }
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, let loaded = UIImage(data: data) else { return }
            ArtworkImageCache.shared.insert(loaded, for: url)
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

@MainActor
private final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let pixelCost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: pixelCost)
    }
}
