import Photos
import UIKit

final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let manager = PHCachingImageManager()

    struct Oriented: @unchecked Sendable {
        let cgImage: CGImage
        let orientation: CGImagePropertyOrientation
    }

    func image(for asset: PHAsset, size: CGSize, mode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The photo for Eye, at least `side` pixels on its long side. A thumbnail looks soft to Eye and
    /// gets judged unfocused, so a small copy is never used: the large version already on the phone
    /// when there is one (quick, no full decode), otherwise the original downloaded from iCloud.
    /// Nil when neither can be had (offline, say); the photo waits for a later pass.
    func analysisImage(for asset: PHAsset, side: CGFloat = 1024) async -> UIImage? {
        if let local = await request(asset, side: side, network: false), Self.isLarge(local, side: side) {
            return local
        }
        return await request(asset, side: side, network: true)
    }

    private func request(_ asset: PHAsset, side: CGFloat, network: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                continuation.resume(returning: degraded ? nil : image)
            }
        }
    }

    /// Big enough for Eye: the long side within a quarter of what was asked, or the whole photo
    /// when the photo itself is smaller than that.
    private static func isLarge(_ image: UIImage, side: CGFloat) -> Bool {
        let long = max(image.size.width * image.scale, image.size.height * image.scale)
        return long >= side * 0.75
    }

    /// A small copy for analysis, with the orientation Vision needs.
    func cgImage(for asset: PHAsset, side: CGFloat) async -> Oriented? {
        guard let image = await image(for: asset, size: CGSize(width: side, height: side), mode: .aspectFit),
              let cgImage = image.cgImage else { return nil }
        return Oriented(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }

    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
