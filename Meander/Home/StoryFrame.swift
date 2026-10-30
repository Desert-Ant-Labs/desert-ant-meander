import SwiftUI

/// How the trip carousel lays its photos out: one to a screen, or two stacked when a landscape or
/// square photo would otherwise sit small on a tall screen.
enum StoryFrame {
    /// Width over height at or above this counts as landscape or square-ish.
    static let wideAspect = 0.85

    /// Width over height for each item, measured from the image Photos actually hands back for display.
    /// The size recorded on the asset can disagree with what is shown (rotated, edited or imported
    /// photos), so the recorded size is only the fallback.
    typealias Shapes = [String: Double]

    static func measure(_ items: [MediaItem]) async -> Shapes {
        await withTaskGroup(of: (String, Double?).self) { group in
            for item in items where !item.isVideo {
                group.addTask {
                    let image = await ImageLoader.shared.image(for: item.asset, size: CGSize(width: 160, height: 160), mode: .aspectFit)
                    guard let size = image?.size, size.height > 0 else { return (item.id, nil) }
                    return (item.id, size.width / size.height)
                }
            }
            var shapes: Shapes = [:]
            for await (id, aspect) in group { shapes[id] = aspect }
            return shapes
        }
    }

    static func aspect(_ item: MediaItem, _ shapes: Shapes) -> Double {
        if let measured = shapes[item.id] { return measured }
        let width = Double(item.asset.pixelWidth), height = Double(item.asset.pixelHeight)
        return height > 0 ? width / height : 1
    }

    static func isWide(_ item: MediaItem, _ shapes: Shapes) -> Bool {
        !item.isVideo && aspect(item, shapes) >= wideAspect
    }

    /// Groups items into screens of one or two.
    /// A wide photo shares a screen with the next wide photo in the trip, even when portraits or
    /// videos sit between them; the pair shows where the first one was. A wide photo left without
    /// a wide partner shares with the nearest portrait instead, so it is never shown alone and cropped
    /// to a tall screen. Other portraits, and all videos, get a screen each.
    static func frames(for items: [MediaItem], shapes: Shapes) -> [[MediaItem]] {
        var frames: [[MediaItem]] = []
        var paired: Set<String> = []
        for (index, item) in items.enumerated() where !paired.contains(item.id) {
            if isWide(item, shapes), let partner = items[(index + 1)...].first(where: { isWide($0, shapes) && !paired.contains($0.id) }) {
                paired.insert(partner.id)
                frames.append([item, partner])
            } else {
                frames.append([item])
            }
        }

        func isLonePortrait(_ frame: [MediaItem]) -> Bool {
            frame.count == 1 && !frame[0].isVideo && !isWide(frame[0], shapes)
        }
        // At most one wide photo is left over. Give it the portrait after it, or failing that the one before.
        if let lone = frames.firstIndex(where: { $0.count == 1 && isWide($0[0], shapes) }) {
            if let after = frames[(lone + 1)...].firstIndex(where: isLonePortrait) {
                frames[lone].append(frames[after][0])
                frames.remove(at: after)
            } else if let before = frames[..<lone].lastIndex(where: isLonePortrait) {
                frames[before].append(frames[lone][0])
                frames.remove(at: lone)
            }
        }
        return frames
    }

    /// The top photo's share of the screen height, so each photo is cropped as little as possible:
    /// two landscapes split evenly, a landscape with a portrait gives the portrait about two thirds.
    static func topShare(_ top: MediaItem, _ bottom: MediaItem, _ shapes: Shapes) -> Double {
        let topHeight = 1 / aspect(top, shapes), bottomHeight = 1 / aspect(bottom, shapes)
        return min(max(topHeight / (topHeight + bottomHeight), 1.0 / 3), 2.0 / 3)
    }
}

/// Two photos sharing a screen, one above the other, each in its own rounded frame.
struct SplitFrame: View {
    let top: MediaItem
    let bottom: MediaItem
    let shapes: StoryFrame.Shapes
    private let gap = CardMetrics.gap

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: gap) {
                AssetImage(asset: top.asset, full: true)
                    .frame(height: (geometry.size.height - gap) * StoryFrame.topShare(top, bottom, shapes))
                    .clipShape(.rect(cornerRadius: CardMetrics.albumCornerRadius))
                AssetImage(asset: bottom.asset, full: true)
                    .clipShape(.rect(cornerRadius: CardMetrics.albumCornerRadius))
            }
        }
    }
}
