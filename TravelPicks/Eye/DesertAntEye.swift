import Eye
import Foundation
import UIKit

/// The Eye model from Desert Ant Labs (desert-ant-core 4.0), behind the app's `EyeModel` interface.
/// Its weights download from Hugging Face on first use and are cached, so later launches work offline.
struct DesertAntEye: EyeModel {
    let version = "eye-4.0.0-nature-strict"
    private let eye = Eye()

    var isDownloaded: Bool { eye.isDownloaded() }

    /// Downloads and loads the model, reporting progress 0...1.
    func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await eye.download(progress: progress)
    }

    /// Everything the picker reads: what the photo is and how good (photo), faces for eyes closed and
    /// people, sharpness for blurry. Layout (crops, people boxes) is left out; faces stop at five.
    private static let options = Options(parts: [.photo, .faces, .sharpness], maxFaces: 5)
    /// Photos in flight at once. Each downloads its original if it's in iCloud, then runs through
    /// Eye. Downloads are slow and the Neural Engine is not, so several go at once to keep it busy
    /// (measured on an M-series Mac: 37ms a photo one at a time, 24ms with four or more).
    private static let width = 8

    func analyze(_ items: [MediaItem], progress: @escaping @Sendable (Int) -> Void) async -> [String: EyeAnalysis] {
        var analysed: [(item: MediaItem, analysis: Analysis)] = []
        var results: [String: EyeAnalysis] = [:]
        let eye = self.eye

        await withTaskGroup(of: (MediaItem, Analysis?).self) { group in
            var queue = items[...]
            func startNext() {
                guard let item = queue.popFirst() else { return }
                group.addTask {
                    if item.isVideo { return (item, nil) }
                    guard let image = await ImageLoader.shared.analysisImage(for: item.asset) else { return (item, nil) }
                    return (item, try? await eye.analyze(image, options: Self.options))
                }
            }
            for _ in 0..<Self.width { startNext() }

            var done = 0
            for await (item, analysis) in group {
                if Task.isCancelled { group.cancelAll(); break }
                if item.isVideo {
                    // Eye scores still images; a video gets a neutral score and no tags.
                    results[item.id] = EyeAnalysis(tags: [], score: 0.5, discard: item.duration < 1.5 ? .accidental : nil)
                } else if let analysis {
                    analysed.append((item, analysis))
                    results[item.id] = Self.translate(analysis, item: item)
                }
                done += 1
                progress(done)
                startNext()
            }
        }

        // Near-duplicates: Eye lists the photo to keep first in each group; the rest are set aside.
        let groups = Eye.duplicates(in: analysed.map(\.analysis), dates: analysed.map { $0.item.date.timeIntervalSince1970 })
        for group in groups {
            for index in group.dropFirst() where results[analysed[index].item.id]?.discard == nil {
                results[analysed[index].item.id]?.discard = .duplicate
            }
        }
        return results
    }

    private static func translate(_ photo: Analysis, item: MediaItem) -> EyeAnalysis {
        // Strict: a tag counts only at 0.9 confidence or more (the SDK's recommended cutoff is 0.5).
        func any(_ tags: Tag...) -> Bool { tags.contains { photo.has($0, .strict) } }

        var tags: Set<EyeTag> = []
        if any(.selfie) { tags.insert(.selfies) }
        if any(.people, .person, .groupShot, .portrait) || !(photo.faces ?? []).isEmpty { tags.insert(.people) }
        if any(.food, .meal) { tags.insert(.food) }
        // Landscapes covers nature generally: it's also what marks a likely trip among possible ones.
        if any(.landscape, .beach, .mountain, .coast, .lake, .river, .forest, .jungle, .field, .grassland,
               .hill, .horizon, .waterfall, .sea, .ocean, .sunset, .cave, .hiking, .wilderness) {
            tags.insert(.landscapes)
        }
        if any(.landmark, .monument, .architecture) { tags.insert(.sights) }
        if any(.temple) { tags.insert(.temples) }

        var discard: DiscardReason?
        if any(.eyesClosed) {
            discard = .closedEyes
        } else if any(.blurry) {
            discard = .unfocused
        } else if any(.accidental, .screenshot, .lowContent) {
            discard = .accidental
        }

        var score = photo.scores?.keeper ?? 0.5
        if item.asset.isFavorite { score += 0.2 }
        if discard != nil { score *= 0.5 }
        return EyeAnalysis(tags: tags, score: min(max(score, 0), 1), discard: discard)
    }
}
