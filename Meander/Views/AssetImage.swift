import Photos
import SwiftUI

/// A photo from the library, loaded at the size it is drawn.
struct AssetImage: View {
    let asset: PHAsset
    var contentMode: ContentMode = .fill
    /// Loads at full screen resolution, for the viewer.
    var full = false

    @Environment(\.displayScale) private var scale
    @Environment(\.preloadedImages) private var preloaded
    @State private var loaded: UIImage?

    /// When rendering to a PDF there's no time to load, so images are handed in up front.
    private var image: UIImage? { preloaded[asset.localIdentifier] ?? loaded }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .allowsHitTesting(false)
                } else if contentMode == .fill {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: "\(asset.localIdentifier)-\(Int(geometry.size.width))x\(Int(geometry.size.height))") {
                guard geometry.size.width > 0, preloaded[asset.localIdentifier] == nil else { return }
                let side = max(geometry.size.width, geometry.size.height) * scale * (full ? 1 : 1.2)
                loaded = await ImageLoader.shared.image(
                    for: asset,
                    size: CGSize(width: side, height: side),
                    mode: contentMode == .fill ? .aspectFill : .aspectFit
                ) ?? loaded
            }
        }
        .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
    }
}

extension EnvironmentValues {
    @Entry var preloadedImages: [String: UIImage] = [:]
    /// A still of the trip's route map, used in place of the live map when rendering to a PDF.
    @Entry var routeMapSnapshot: UIImage?
}
