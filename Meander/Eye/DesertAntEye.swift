import Eye
import Foundation
import UIKit

/// The Eye model from Desert Ant Labs (desert-ant-core 4.0), behind the app's `EyeModel` interface.
/// Its weights download from Hugging Face on first use and are cached, so later launches work offline.
struct DesertAntEye: EyeModel {
    let version = "eye-4.0.0-filters-3"
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

        await withTaskGroup(of: (MediaItem, Analysis?, Bool).self) { group in
            var queue = items[...]
            func startNext() {
                guard let item = queue.popFirst() else { return }
                group.addTask {
                    // For a video this is its cover frame, which is what Eye judges it by.
                    guard let image = await ImageLoader.shared.analysisImage(for: item.asset) else { return (item, nil, false) }
                    return (item, try? await eye.analyze(image, options: Self.options), SkyColour.isWarm(image))
                }
            }
            for _ in 0..<Self.width { startNext() }

            var done = 0
            for await (item, analysis, warmSky) in group {
                if Task.isCancelled { group.cancelAll(); break }
                if item.isVideo {
                    results[item.id] = analysis.map { Self.translateVideo($0, item: item, warmSky: warmSky) }
                        ?? EyeAnalysis(tags: [], score: 0.5, discard: item.duration < 1.5 ? .accidental : nil)
                } else if let analysis {
                    analysed.append((item, analysis))
                    results[item.id] = Self.translate(analysis, item: item, warmSky: warmSky)
                }
                done += 1
                progress(done)
                startNext()
            }
        }

        // Near-duplicates: the best of each group is kept; the rest are set aside.
        for group in Self.duplicateGroups(analysed) {
            guard let best = Eye.best(of: group.map(\.analysis)) else { continue }
            for (index, member) in group.enumerated() where index != best && results[member.item.id]?.discard == nil {
                results[member.item.id]?.discard = .duplicate
            }
        }
        return results
    }

    /// How alike two photos must look to be duplicates. Eye calls 0.9 a near-duplicate; this asks for near-identical.
    static let duplicateSimilarity = 0.95
    /// How soon after the first photo of a group the others must be taken.
    static let duplicateWindow: TimeInterval = 60

    /// Groups of near-identical photos taken within a minute of each other. Each photo is compared with
    /// the first of a group only, so groups don't chain: a run of shots that changes a little each time
    /// (a panorama, a sunset as the light goes) stays separate photos instead of becoming one group.
    private static func duplicateGroups(_ photos: [(item: MediaItem, analysis: Analysis)]) -> [[(item: MediaItem, analysis: Analysis)]] {
        var groups: [[(item: MediaItem, analysis: Analysis)]] = []
        var open: [Int] = []
        for photo in photos.sorted(by: { $0.item.date < $1.item.date }) {
            open.removeAll { photo.item.date.timeIntervalSince(groups[$0][0].item.date) > duplicateWindow }
            let match = open
                .compactMap { i in groups[i][0].analysis.similarity(to: photo.analysis).map { (i, $0) } }
                .filter { $0.1 >= duplicateSimilarity }
                .max { $0.1 < $1.1 }
            if let (i, _) = match {
                groups[i].append(photo)
            } else {
                groups.append([photo])
                open.append(groups.count - 1)
            }
        }
        return groups.filter { $0.count > 1 }
    }

    /// A video, judged by its cover frame: its filters and score come from the frame, but not the frame's
    /// flaws (one blurry frame doesn't make a blurry video). Only a clip under a second and a half is set aside.
    private static func translateVideo(_ frame: Analysis, item: MediaItem, warmSky: Bool) -> EyeAnalysis {
        var analysis = translate(frame, item: item, warmSky: warmSky)
        analysis.discard = item.duration < 1.5 ? .accidental : nil
        var score = frame.scores?.keeper ?? 0.5
        if item.asset.isFavorite { score += 0.2 }
        analysis.score = min(max(score, 0), 1)
        return analysis
    }

    /// Sunrises and sunsets. Eye has no sunrise tag, and its sunset tag misses some, so three things count:
    /// - Eye seeing a sunset, even at its recommended (looser) confidence.
    /// - The sun being low where and when the photo was taken, with sky or open scenery in the shot.
    /// - A pink, orange or purple sky across the top of the photo, with sky in the shot.
    private static func isGoldenHour(_ photo: Analysis, item: MediaItem, warmSky: Bool) -> Bool {
        func any(_ tags: Tag...) -> Bool { tags.contains { photo.has($0) } }
        if any(.sunset) { return true }
        let hasSky = any(.sky, .cloud, .cumulus, .horizon, .sun)
        let isOutdoors = hasSky || any(.landscape, .beach, .coast, .shore, .sea, .ocean, .lake, .mountain, .mountainRange,
                                       .cityscape, .skyline, .field, .hill)
        if isOutdoors, let place = item.location?.coordinate, SunPosition.isGoldenHour(at: item.date, coordinate: place) {
            return true
        }
        return warmSky && hasSky
    }

    private static func translate(_ photo: Analysis, item: MediaItem, warmSky: Bool) -> EyeAnalysis {
        // Strict: a tag counts only at 0.9 confidence or more (the SDK's recommended cutoff is 0.5).
        func any(_ tags: Tag...) -> Bool { tags.contains { photo.has($0, .strict) } }

        var tags: Set<EyeTag> = []
        if any(.landscape, .beach, .mountain, .mountainRange, .coast, .shore, .ocean, .sea, .waveNoun, .reef, .sand,
               .lake, .river, .waterfall, .forest, .jungle, .field, .grassland, .hill, .horizon, .cave, .wilderness, .hiking) {
            tags.insert(.landscape)
        }
        if isGoldenHour(photo, item: item, warmSky: warmSky) { tags.insert(.goldenHour) }
        // Posed: a selfie, a portrait or group shot, or people looking at the camera. Crowds in the background don't count.
        if any(.selfie, .portrait, .groupShot, .everyoneLooking)
            || (any(.people, .person) && any(.lookingAtCamera)) {
            tags.insert(.people)
        }
        if any(.food, .meal, .dessert, .seafood, .sushi, .pizza, .pasta, .salad, .bakedGoods, .pastry, .bread,
               .iceCream, .fastFood, .friedFood, .hamburger, .sandwich, .snack) {
            tags.insert(.food)
        }
        // Eye has no market or restaurant tags; street, city and crowd scenes bring those in.
        if any(.landmark, .monument, .architecture, .building, .ruins, .temple, .church, .castle, .tower, .statue,
               .sculpture, .stoneCarving, .stainedGlass, .bridgeStructure, .fountain, .canal, .street, .city, .cityscape,
               .skyline, .metropolis, .town, .neighbourhood, .urbanArea, .sidewalk, .pedestrian, .crowd) {
            tags.insert(.sights)
        }

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
