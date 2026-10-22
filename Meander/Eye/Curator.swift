import Foundation
import Observation
import Photos

/// Runs the model over trips, caches what it says, and remembers what you restore or discard.
/// Nothing is ever deleted from Photos: discarding only hides an item inside Meander.
@MainActor @Observable
final class Curator {
    struct Progress: Equatable { var done: Int; var total: Int }

    private(set) var analyses: [String: EyeAnalysis] = [:]
    private(set) var progress: [String: Progress] = [:]
    private var kept: Set<String> = []
    private var discarded: Set<String> = []

    enum ModelState: Equatable {
        case downloading(Double)
        case ready
        /// Eye couldn't download (offline, say). The Vision stand-in does the work until next launch.
        case unavailable
    }

    /// The library pass: newest photos first, 1,000 at a time.
    /// Progress across the whole library: photos Eye has curated, of all the photos there are.
    struct LibraryPass: Equatable {
        /// The batch Eye is working on, up to 1,000 photos.
        var batchDone: Int
        var batchTotal: Int
        /// Across the whole library.
        var curated: Int
        var total: Int
        /// Why the pass is waiting (the phone is hot, or in Low Power Mode), or nil while it runs.
        var pauseReason: String?
    }

    private(set) var modelState: ModelState
    private(set) var libraryPass: LibraryPass?
    static let batchSize = 1_000

    private var model: any EyeModel
    private let eye = DesertAntEye()
    /// What Eye said about each photo, so rule changes don't need Eye to run again.
    private let records = EyeRecordStore(modelVersion: DesertAntEye.modelVersion)
    /// The model and rules `analyses` came from. When it isn't the current one, the rules are applied
    /// again to Eye's saved records.
    private var analysesVersion: String?
    @ObservationIgnored private var modelReady: Task<Void, Never>?
    @ObservationIgnored private var passTask: Task<Void, Never>?
    private let fileURL: URL

    init() {
        modelState = eye.isDownloaded ? .ready : .downloading(0)
        model = eye.isDownloaded ? eye : PreviewEye()
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appending(path: "curation.json")
        load()
    }

    // MARK: Running

    func curate(_ trip: Trip) async {
        guard progress[trip.id] == nil else { return }
        await prepareModel()
        let pending = trip.items.filter { analyses[$0.id] == nil }
        guard !pending.isEmpty else { return }

        progress[trip.id] = Progress(done: 0, total: pending.count)
        let tripID = trip.id
        let results = await run(pending) { done in
            Task { @MainActor [weak self] in self?.progress[tripID]?.done = done }
        }
        analyses.merge(results) { _, new in new }
        progress[trip.id] = nil
        save()
    }

    func isCurating(_ tripID: String) -> Bool { progress[tripID] != nil }

    // MARK: Eye

    /// Downloads and loads Eye. Called at launch; later callers wait on the same download.
    func prepareModel() async {
        if modelReady == nil {
            let eye = self.eye
            modelReady = Task {
                do {
                    try await eye.prepare { fraction in
                        Task { @MainActor [weak self] in
                            if case .downloading = self?.modelState { self?.modelState = .downloading(fraction) }
                        }
                    }
                    let switching = !(model is DesertAntEye)
                    model = eye
                    // Results from the stand-in are redone by Eye.
                    if switching { analyses = [:]; analysesVersion = nil }
                    await applyRulesToRecords()
                    modelState = .ready
                } catch {
                    modelState = .unavailable
                }
            }
        }
        await modelReady?.value
    }

    /// Runs Eye over the whole library, newest first, in batches of 1,000, skipping anything
    /// already done. Starts when the picker opens and keeps going in the background; results are
    /// saved as it goes, so a later pass picks up where this one stopped.
    /// `first` jumps the queue: the photos in possible trips, so Eye can judge those soonest.
    func curateLibrary(first: [MediaItem] = []) {
        guard passTask == nil else { return }
        passTask = Task {
            await prepareModel()
            let library = Self.libraryNewestFirst()
            let firstIDs = Set(first.map(\.id))
            let rest = library.filter { !firstIDs.contains($0.id) }
            let pending = (first + rest).filter { analyses[$0.id] == nil }
            libraryPass = LibraryPass(batchDone: 0, batchTotal: 0, curated: library.count - pending.count, total: library.count)
            let batches = stride(from: 0, to: pending.count, by: Self.batchSize).map {
                Array(pending[$0..<min($0 + Self.batchSize, pending.count)])
            }
            for batch in batches {
                if Task.isCancelled { break }
                libraryPass?.batchDone = 0
                libraryPass?.batchTotal = batch.count
                // Results show and save every 100 photos, so the screen updates as Eye goes and leaving
                // part-way loses little.
                for chunk in stride(from: 0, to: batch.count, by: 100).map({ Array(batch[$0..<min($0 + 100, batch.count)]) }) {
                    if Task.isCancelled { break }
                    if let reason = Heat.pauseReason {
                        libraryPass?.pauseReason = reason
                        await Heat.waitUntilReady()
                        libraryPass?.pauseReason = nil
                        if Task.isCancelled { break }
                    }
                    let curated = libraryPass?.curated ?? 0, batchDone = libraryPass?.batchDone ?? 0
                    let results = await run(chunk) { done in
                        Task { @MainActor [weak self] in
                            self?.libraryPass?.curated = curated + done
                            self?.libraryPass?.batchDone = batchDone + done
                        }
                    }
                    analyses.merge(results) { _, new in new }
                    save()
                }
            }
            libraryPass = nil
            passTask = nil
        }
    }

    /// Runs the model over `items`. With Eye, what it says is saved first, then the rules are applied.
    private func run(_ items: [MediaItem], progress: @escaping @Sendable (Int) -> Void) async -> [String: EyeAnalysis] {
        guard let eye = model as? DesertAntEye else { return await model.analyze(items, progress: progress) }
        let found = await eye.record(items, progress: progress)
        await records.append(found)
        return DesertAntEye.translate(found, items: items)
    }

    /// When the rules changed since `analyses` were made, applies them again to everything Eye has
    /// already seen. Takes seconds and never runs Eye; only photos Eye hasn't seen are left for the pass.
    private func applyRulesToRecords() async {
        guard analysesVersion != model.version else { return }
        let records = self.records
        let fresh = await Task.detached(priority: .userInitiated) { () -> [String: EyeAnalysis] in
            let saved = await records.loadAll()
            guard !saved.isEmpty else { return [:] }
            var items: [MediaItem] = []
            PHAsset.fetchAssets(withLocalIdentifiers: Array(saved.keys), options: nil)
                .enumerateObjects { asset, _, _ in items.append(MediaItem(asset: asset)) }
            return DesertAntEye.translate(saved, items: items)
        }.value
        analyses = fresh
        analysesVersion = model.version
        save()
    }

    /// Every photo and video in the library, newest first.
    nonisolated private static func libraryNewestFirst() -> [MediaItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        var items: [MediaItem] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in items.append(MediaItem(asset: asset)) }
        return items
    }

    // MARK: Reading

    func reason(_ item: MediaItem) -> DiscardReason? {
        if kept.contains(item.id) { return nil }
        if discarded.contains(item.id) { return .byYou }
        return analyses[item.id]?.discard
    }

    func isDiscarded(_ item: MediaItem) -> Bool { reason(item) != nil }

    func score(_ item: MediaItem) -> Double { analyses[item.id]?.score ?? 0 }

    func tags(_ item: MediaItem) -> Set<EyeTag> { analyses[item.id]?.tags ?? [] }

    func kept(_ items: [MediaItem]) -> [MediaItem] { items.filter { !isDiscarded($0) } }

    /// How a possible trip looks to Eye: how many of its photos it has seen, and how many of those
    /// are landscapes, beaches or other nature, the kind of photo a trip tends to have.
    struct TravelSignal {
        var photos: Int
        var seen: Int
        var nature: Int

        /// Decided once Eye has seen at least half the photos.
        var isJudged: Bool { photos > 0 && seen * 2 >= photos }
        var share: Double { seen > 0 ? Double(nature) / Double(seen) : 0 }
        /// One photo in ten being nature is enough to count as a likely trip.
        var looksLikeTravel: Bool { share >= 0.1 }
    }

    /// Eye's best landscape or golden hour photo among `items`, if it has found one.
    func natureCover(_ items: [MediaItem]) -> MediaItem? {
        kept(items).filter { !$0.isVideo && isNature(tags($0)) }.max { score($0) < score($1) }
    }

    private func isNature(_ tags: Set<EyeTag>) -> Bool { tags.contains(.landscape) || tags.contains(.goldenHour) }

    func travelSignal(_ items: [MediaItem]) -> TravelSignal {
        let photos = items.filter { !$0.isVideo }
        let seen = photos.compactMap { analyses[$0.id] }
        return TravelSignal(photos: photos.count, seen: seen.count, nature: seen.filter { isNature($0.tags) }.count)
    }

    func discarded(_ items: [MediaItem]) -> [MediaItem] { items.filter(isDiscarded) }

    /// Good shots from across the filters, in the order given:
    /// - From each filter, and from photos in none, the best-scored `share`: at least one, at most `perTag`.
    /// - Within each, nothing taken within `apart` of a shot already picked, so each covers its own moment.
    /// - Videos are picked on their own, a couple per filter at most, since a video's score comes from one
    ///   frame and would otherwise crowd out the photos. With only videos to choose from, they get the full share.
    /// - Shots with text in them (a menu, a sign-up sheet) are left out.
    /// - Your favorites in Photos are always in, text or not.
    func highlights(_ items: [MediaItem], share: Double = 0.3, perTag: Int = 15, videosPerTag: Int = 2,
                    apart: TimeInterval = 5 * 60) -> [MediaItem] {
        let ranked = kept(items).filter { analyses[$0.id].map { !$0.showsText } ?? false }.sorted { score($0) > score($1) }
        let photos = ranked.filter { !$0.isVideo }
        let videos = ranked.filter(\.isVideo)

        func pick(_ pool: [MediaItem], cap: Int) -> [MediaItem] {
            let quota = min(cap, max(1, Int((Double(pool.count) * share).rounded())))
            var chosen: [MediaItem] = []
            for item in pool where chosen.count < quota {
                if chosen.contains(where: { abs($0.date.timeIntervalSince(item.date)) < apart }) { continue }
                chosen.append(item)
            }
            return chosen
        }

        // Each filter, then the photos no filter claimed.
        let buckets: [(MediaItem) -> Bool] = EyeTag.allCases.map { tag in { self.tags($0).contains(tag) } }
            + [{ self.tags($0).isEmpty }]
        var picked: Set<String> = []
        for inBucket in buckets {
            let bucketPhotos = photos.filter(inBucket)
            let bucketVideos = videos.filter(inBucket)
            if !bucketPhotos.isEmpty { picked.formUnion(pick(bucketPhotos, cap: perTag).map(\.id)) }
            if !bucketVideos.isEmpty {
                picked.formUnion(pick(bucketVideos, cap: photos.isEmpty ? perTag : videosPerTag).map(\.id))
            }
        }
        picked.formUnion(kept(items).filter { $0.asset.isFavorite }.map(\.id))
        return items.filter { picked.contains($0.id) }
    }

    /// The photo that stands for a set: the best one once analyzed, a favorite or the middle one before.
    func cover(_ items: [MediaItem]) -> MediaItem? {
        let candidates = kept(items).filter { !$0.isVideo }
        if let best = candidates.filter({ analyses[$0.id] != nil }).max(by: { score($0) < score($1) }) { return best }
        return candidates.first { $0.asset.isFavorite } ?? candidates[safe: candidates.count / 2] ?? items.first
    }

    // MARK: Changing

    func restore(_ item: MediaItem) {
        discarded.remove(item.id)
        if analyses[item.id]?.discard != nil { kept.insert(item.id) }
        save()
    }

    func discard(_ item: MediaItem) {
        kept.remove(item.id)
        if analyses[item.id]?.discard == nil { discarded.insert(item.id) }
        save()
    }

    // MARK: Storage

    private struct Stored: Codable {
        var version: String
        var analyses: [String: EyeAnalysis]
        var kept: Set<String>
        var discarded: Set<String>

        init(version: String, analyses: [String: EyeAnalysis], kept: Set<String>, discarded: Set<String>) {
            self.version = version
            self.analyses = analyses
            self.kept = kept
            self.discarded = discarded
        }

        /// Analyses saved under older filters may not decode; what you kept and discarded always does.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(String.self, forKey: .version)
            analyses = (try? c.decode([String: EyeAnalysis].self, forKey: .analyses)) ?? [:]
            kept = try c.decode(Set<String>.self, forKey: .kept)
            discarded = try c.decode(Set<String>.self, forKey: .discarded)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        kept = stored.kept
        discarded = stored.discarded
        if stored.version == model.version {
            analyses = stored.analyses
            analysesVersion = stored.version
        }
    }

    private func save() {
        let stored = Stored(version: model.version, analyses: analyses, kept: kept, discarded: discarded)
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url, options: .atomic) }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
