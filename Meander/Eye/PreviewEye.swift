import CoreGraphics
import Photos
import UIKit
import Vision

/// Stand-in for the Eye model while it is in beta.
///
/// Uses Apple's on-device Vision requests plus a few pixel measurements so the interface
/// has real, if rougher, results to show. Every request is optional: if Vision is not
/// available (some simulators), the pixel measurements and Photos metadata still work.
struct PreviewEye: EyeModel {
    let version = "preview-3"

    func analyze(_ items: [MediaItem], progress: @escaping @Sendable (Int) -> Void) async -> [String: EyeAnalysis] {
        let selfies = Self.selfieIDs()
        var measured: [String: Measurement] = [:]

        await withTaskGroup(of: (String, Measurement).self) { group in
            var queue = items[...]
            for _ in 0..<4 {
                guard let item = queue.popFirst() else { break }
                group.addTask { (item.id, await Self.measure(item, isSelfie: selfies.contains(item.id))) }
            }
            for await (id, measurement) in group {
                measured[id] = measurement
                progress(measured.count)
                if let item = queue.popFirst() {
                    group.addTask { (item.id, await Self.measure(item, isSelfie: selfies.contains(item.id))) }
                }
            }
        }

        var results = measured.mapValues(\.analysis)

        // Near-identical shots taken within two minutes of each other: keep the better one.
        let ordered = items.filter { !$0.isVideo }
        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            guard current.date.timeIntervalSince(previous.date) < 120,
                  let a = measured[previous.id], let b = measured[current.id],
                  let hashA = a.hash, let hashB = b.hash,
                  (hashA ^ hashB).nonzeroBitCount <= 10,
                  results[previous.id]?.discard == nil, results[current.id]?.discard == nil
            else { continue }
            let weaker = (results[previous.id]!.score >= results[current.id]!.score) ? current.id : previous.id
            results[weaker]?.discard = .duplicate
        }
        return results
    }

    // MARK: - Per item

    private struct Measurement {
        var analysis: EyeAnalysis
        var hash: UInt64?
    }

    private static func measure(_ item: MediaItem, isSelfie: Bool) async -> Measurement {
        let asset = item.asset
        var tags: Set<EyeTag> = isSelfie ? [.people] : []
        var discard: DiscardReason?

        if asset.mediaSubtypes.contains(.photoScreenshot) { discard = .screenshot }
        if item.isVideo && item.duration < 1.5 { discard = .accidental }

        guard let image = await ImageLoader.shared.cgImage(for: asset, side: 360) else {
            return Measurement(analysis: EyeAnalysis(tags: tags, score: asset.isFavorite ? 0.8 : 0.5, discard: discard), hash: nil)
        }

        let pixels = PixelStats(image.cgImage)
        let orientation = image.orientation

        if let labels = try? await ClassifyImageRequest().perform(on: image.cgImage, orientation: orientation) {
            let confident = labels.filter { $0.confidence > 0.3 }.map { $0.identifier.lowercased() }
            for (tag, words) in keywords where confident.contains(where: { label in words.contains { label.contains($0) } }) {
                tags.insert(tag)
            }
            let textWords = ["document", "menu", "receipt", "handwriting", "printed_page", "ticket"]
            if discard == nil, confident.contains(where: { label in textWords.contains { label.contains($0) } }) {
                discard = .text
            }
        }

        var closedEyes = false
        if let faces = try? await DetectFaceLandmarksRequest().perform(on: image.cgImage, orientation: orientation) {
            let prominent = faces.filter { $0.boundingBox.width * $0.boundingBox.height > 0.01 }
            // A face this big is someone posing for the shot, not a passer-by.
            if prominent.contains(where: { $0.boundingBox.width * $0.boundingBox.height > 0.03 }) { tags.insert(.people) }
            closedEyes = prominent.contains { face in
                guard let landmarks = face.landmarks else { return false }
                return openness(landmarks.leftEye.points) < 0.14 && openness(landmarks.rightEye.points) < 0.14
            }
        }

        var aesthetic: Double?
        if !item.isVideo, let scores = try? await CalculateImageAestheticsScoresRequest().perform(on: image.cgImage, orientation: orientation) {
            aesthetic = Double(scores.overallScore)
            // Vision's "utility" photos are receipts, documents and the like.
            if scores.isUtility, discard == nil { discard = .text }
        }

        if discard == nil {
            if pixels.brightness < 0.07 || pixels.contrast < 0.025 {
                discard = .accidental
            } else if closedEyes {
                discard = .closedEyes
            } else if !item.isVideo && pixels.sharpness < 0.004 {
                discard = .unfocused
            }
        }

        var score: Double
        if let aesthetic {
            score = (aesthetic + 1) / 2
        } else {
            let sharp = min(pixels.sharpness / 0.03, 1)
            let exposure = 1 - min(abs(pixels.brightness - 0.5) * 2, 1)
            score = 0.6 * sharp + 0.4 * exposure
        }
        if asset.isFavorite { score += 0.2 }
        if discard != nil { score *= 0.5 }

        return Measurement(
            analysis: EyeAnalysis(tags: tags, score: min(max(score, 0), 1), discard: discard),
            hash: item.isVideo ? nil : pixels.hash
        )
    }

    /// Height over width of an eye outline. Open eyes sit around 0.3, closed ones near 0.1.
    private static func openness(_ points: [NormalizedPoint]) -> Double {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX
        else { return 1 }
        return Double((maxY - minY) / (maxX - minX))
    }

    private static func selfieIDs() -> Set<String> {
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
        var ids = Set<String>()
        albums.enumerateObjects { album, _, _ in
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        }
        return ids
    }

    private static let keywords: [EyeTag: [String]] = [
        .food: ["food", "dish", "meal", "dessert", "fruit", "noodle", "rice", "soup", "sushi", "pizza", "bread", "cake",
                "salad", "seafood", "meat", "vegetable", "snack", "breakfast", "curry"],
        .landscape: ["landscape", "mountain", "beach", "shore", "ocean", "sea", "lake", "river", "waterfall", "forest",
                     "jungle", "desert", "canyon", "valley", "island", "hill", "cliff", "coast", "volcano", "glacier", "field"],
        .goldenHour: ["sunset", "sunrise"],
        .sights: ["monument", "statue", "tower", "bridge", "castle", "palace", "architecture", "skyscraper", "cityscape",
                  "landmark", "museum", "fountain", "structure", "building", "market", "street", "skyline", "ruins",
                  "temple", "shrine", "pagoda", "stupa", "church", "cathedral", "mosque", "religious", "monastery",
                  "chapel", "restaurant", "cafe", "bazaar"],
    ]
}

/// Cheap pixel measurements on a small grayscale copy.
private struct PixelStats {
    var brightness = 0.5
    var contrast = 0.2
    var sharpness = 0.02
    var hash: UInt64 = 0

    init(_ image: CGImage) {
        if let gray = Self.gray(image, width: 160, height: 160) {
            let values = gray.map { Double($0) / 255 }
            let mean = values.reduce(0, +) / Double(values.count)
            brightness = mean
            contrast = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()

            var laplacian: [Double] = []
            laplacian.reserveCapacity(158 * 158)
            for y in 1..<159 {
                for x in 1..<159 {
                    let i = y * 160 + x
                    laplacian.append(4 * values[i] - values[i - 1] - values[i + 1] - values[i - 160] - values[i + 160])
                }
            }
            let lMean = laplacian.reduce(0, +) / Double(laplacian.count)
            sharpness = laplacian.reduce(0) { $0 + ($1 - lMean) * ($1 - lMean) } / Double(laplacian.count)
        }
        if let tiny = Self.gray(image, width: 9, height: 8) {
            for row in 0..<8 {
                for column in 0..<8 where tiny[row * 9 + column] > tiny[row * 9 + column + 1] {
                    hash |= 1 << UInt64(row * 8 + column)
                }
            }
        }
    }

    private static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
