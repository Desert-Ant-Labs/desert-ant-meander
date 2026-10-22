import Eye
import Foundation
import UIKit

/// The Eye model from Desert Ant Labs (desert-ant-core 4.0), behind the app's `EyeModel` interface.
/// Its weights download from Hugging Face on first use and are cached, so later launches work offline.
struct DesertAntEye: EyeModel {
    /// The Eye release. Records are kept per release; a new one means running Eye again.
    static let modelVersion = "eye-4.0.0"
    /// Meander's rules for turning Eye's records into filters, scores and discards. Change this when a
    /// rule changes: saved records are re-sorted in seconds, without running Eye again.
    static let rulesVersion = "rules-7"
    var version: String { "\(Self.modelVersion)+\(Self.rulesVersion)" }
    private let eye = Eye()

    var isDownloaded: Bool { eye.isDownloaded() }

    /// Downloads and loads the model, reporting progress 0...1.
    func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await eye.download(progress: progress)
    }

    /// Everything the picker reads: what the photo is and how good (photo), faces for eyes closed,
    /// sharpness for blurry. Layout (crops, people boxes) is left out; faces stop at five.
    private static let options = Options(parts: [.photo, .faces, .sharpness], maxFaces: 5)

    func analyze(_ items: [MediaItem], progress: @escaping @Sendable (Int) -> Void) async -> [String: EyeAnalysis] {
        Self.translate(await record(items, progress: progress), items: items)
    }

    /// Runs Eye over `items` and returns what it said about each. Photos download their original if it's
    /// in iCloud, then go through Eye, `width` at a time (`Heat.width`: fewer when the phone is warm).
    /// Downloads are slow and the Neural Engine is not, so several at once keep it busy.
    func record(_ items: [MediaItem], progress: @escaping @Sendable (Int) -> Void) async -> [String: EyeRecord] {
        var records: [String: EyeRecord] = [:]
        let eye = self.eye
        let width = Heat.width

        await withTaskGroup(of: (MediaItem, EyeRecord?).self) { group in
            var queue = items[...]
            func startNext() {
                guard let item = queue.popFirst() else { return }
                group.addTask {
                    // For a video this is its cover frame, which is what Eye judges it by.
                    guard let image = await ImageLoader.shared.analysisImage(for: item.asset),
                          let analysis = try? await eye.analyze(image, options: Self.options) else { return (item, nil) }
                    return (item, EyeRecord(analysis, warmSky: SkyColour.isWarm(image)))
                }
            }
            for _ in 0..<width { startNext() }

            var done = 0
            for await (item, record) in group {
                if Task.isCancelled { group.cancelAll(); break }
                records[item.id] = record
                done += 1
                progress(done)
                startNext()
            }
        }
        return records
    }

    /// Applies Meander's rules to Eye's records: filters, score and discard for each item, and duplicates
    /// among the photos. A video Eye couldn't see gets a neutral score; a photo it couldn't see gets nothing,
    /// so it's tried again later.
    static func translate(_ records: [String: EyeRecord], items: [MediaItem]) -> [String: EyeAnalysis] {
        var results: [String: EyeAnalysis] = [:]
        var photos: [(item: MediaItem, record: EyeRecord)] = []
        for item in items {
            if let record = records[item.id] {
                if item.isVideo {
                    results[item.id] = translateVideo(record, item: item)
                } else {
                    photos.append((item, record))
                    results[item.id] = translate(record, item: item)
                }
            } else if item.isVideo {
                results[item.id] = EyeAnalysis(tags: [], score: 0.5, discard: item.duration < 1.5 ? .accidental : nil)
            }
        }

        // Near-duplicates: the best of each group is kept; the rest are set aside.
        for group in duplicateGroups(photos) {
            guard let best = group.indices.max(by: { better(group[$1].record, than: group[$0].record) }) else { continue }
            for (index, member) in group.enumerated() where index != best && results[member.item.id]?.discard == nil {
                results[member.item.id]?.discard = .duplicate
            }
        }
        return results
    }

    /// The one to keep from a group: no one's eyes closed, then the higher keeper score.
    private static func better(_ a: EyeRecord, than b: EyeRecord) -> Bool {
        let aClosed = a.has(.eyesClosed), bClosed = b.has(.eyesClosed)
        if aClosed != bClosed { return bClosed }
        return (a.keeper ?? 0) > (b.keeper ?? 0)
    }

    /// How alike two photos must look to be duplicates. Eye calls 0.9 a near-duplicate; this asks for near-identical.
    static let duplicateSimilarity = 0.95
    /// How soon after the first photo of a group the others must be taken.
    static let duplicateWindow: TimeInterval = 60

    /// Groups of near-identical photos taken within a minute of each other. Each photo is compared with
    /// the first of a group only, so groups don't chain: a run of shots that changes a little each time
    /// (a panorama, a sunset as the light goes) stays separate photos instead of becoming one group.
    private static func duplicateGroups(_ photos: [(item: MediaItem, record: EyeRecord)]) -> [[(item: MediaItem, record: EyeRecord)]] {
        var groups: [[(item: MediaItem, record: EyeRecord)]] = []
        var firstVectors: [[Float]?] = []
        var open: [Int] = []
        for photo in photos.sorted(by: { $0.item.date < $1.item.date }) {
            open.removeAll { photo.item.date.timeIntervalSince(groups[$0][0].item.date) > duplicateWindow }
            let vector = photo.record.vector
            let match = vector.flatMap { vector in
                open
                    .compactMap { i in firstVectors[i].map { (i, EyeRecord.similarity($0, vector)) } }
                    .filter { $0.1 >= duplicateSimilarity }
                    .max { $0.1 < $1.1 }
            }
            if let (i, _) = match {
                groups[i].append(photo)
            } else {
                groups.append([photo])
                firstVectors.append(vector)
                open.append(groups.count - 1)
            }
        }
        return groups.filter { $0.count > 1 }
    }

    /// A video, judged by its cover frame: its filters and score come from the frame, but not the frame's
    /// flaws (one blurry frame doesn't make a blurry video). Only a clip under a second and a half is set aside.
    private static func translateVideo(_ frame: EyeRecord, item: MediaItem) -> EyeAnalysis {
        var analysis = translate(frame, item: item)
        analysis.discard = item.duration < 1.5 ? .accidental : nil
        var score = frame.keeper ?? 0.5
        if item.asset.isFavorite { score += 0.2 }
        analysis.score = min(max(score, 0), 1)
        return analysis
    }

    /// Sunrises and sunsets. Eye has no sunrise tag, and its sunset tag misses some, so three things count:
    /// - Eye seeing a sunset, even at its recommended (looser) confidence.
    /// - The sun being low where and when the photo was taken, with sky or open scenery in the shot.
    /// - A pink, orange or purple sky across the top of the photo, with sky in the shot.
    private static func isGoldenHour(_ photo: EyeRecord, item: MediaItem) -> Bool {
        func any(_ tags: Tag...) -> Bool { tags.contains { photo.has($0) } }
        if any(.sunset) { return true }
        let hasSky = any(.sky, .cloud, .cumulus, .horizon, .sun)
        let isOutdoors = hasSky || any(.landscape, .beach, .coast, .shore, .sea, .ocean, .lake, .mountain, .mountainRange,
                                       .cityscape, .skyline, .field, .hill)
        if isOutdoors, let place = item.location?.coordinate, SunPosition.isGoldenHour(at: item.date, coordinate: place) {
            return true
        }
        return photo.warmSky && hasSky
    }

    private static let textTags: [Tag] = [.menu, .document, .receipt, .handwriting, .letterMessage, .newspaper, .idCard,
                                          .identityDocument, .whiteboard, .chartOrSlide, .map, .memeOrGraphic]
    private static let foodTags: [Tag] = [.food, .meal, .dessert, .seafood, .sushi, .pizza, .pasta, .salad, .bakedGoods,
                                          .pastry, .bread, .iceCream, .fastFood, .friedFood, .hamburger, .sandwich, .snack,
                                          .drink, .plate]

    /// A photo taken for its text: a menu, a receipt, a document, a ticket, a map. Eye sees restaurant food
    /// and menus as alike, so a photo counts only when Eye is surer of the text than of any food in it:
    /// a menu with a dish beside it is a menu, a meal with a menu at the edge is a food shot.
    private static func isMostlyText(_ photo: EyeRecord) -> Bool {
        let text = textTags.map { photo.confidence($0) }.max() ?? 0
        let food = foodTags.map { photo.confidence($0) }.max() ?? 0
        return text >= 0.5 && text > food
    }

    /// Any sign of text Eye picks up, reference shots included. Not enough to set a photo aside,
    /// but enough to keep it out of Highlights.
    private static func showsText(_ photo: EyeRecord) -> Bool {
        (textTags + [.referencePhoto, .shoppingReference, .medicalReference, .repairReference]).contains { photo.has($0) }
    }

    private static func translate(_ photo: EyeRecord, item: MediaItem) -> EyeAnalysis {
        // Strict: a tag counts only at 0.9 confidence or more (the SDK's recommended cutoff is 0.5).
        func any(_ tags: Tag...) -> Bool { tags.contains { photo.has($0, .strict) } }

        var tags: Set<EyeTag> = []
        if any(.landscape, .beach, .mountain, .mountainRange, .coast, .shore, .ocean, .sea, .waveNoun, .reef, .sand,
               .lake, .river, .waterfall, .forest, .jungle, .field, .grassland, .hill, .horizon, .cave, .wilderness, .hiking) {
            tags.insert(.landscape)
        }
        if isGoldenHour(photo, item: item) { tags.insert(.goldenHour) }
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
        if item.asset.mediaSubtypes.contains(.photoScreenshot) || photo.has(.screenshot) || photo.has(.photoOfScreen) {
            discard = .screenshot
        } else if isMostlyText(photo) {
            discard = .text
        } else if any(.eyesClosed) {
            discard = .closedEyes
        } else if any(.blurry) {
            discard = .unfocused
        } else if any(.accidental, .lowContent) {
            discard = .accidental
        }

        var score = photo.keeper ?? 0.5
        if item.asset.isFavorite { score += 0.2 }
        if discard != nil { score *= 0.5 }
        return EyeAnalysis(tags: tags, score: min(max(score, 0), 1), discard: discard, showsText: showsText(photo))
    }
}
