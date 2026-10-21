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
    }

    private(set) var modelState: ModelState
    private(set) var libraryPass: LibraryPass?
    static let batchSize = 1_000

    private var model: any EyeModel
    private let eye = DesertAntEye()
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
        let results = await model.analyze(pending) { done in
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
                    modelState = .ready
                    // Results from the stand-in are redone by Eye.
                    if switching { analyses = [:]; save() }
                } catch {
                    modelState = .unavailable
                }
            }
        }
        await modelReady?.value
    }

    /// Runs Eye over the whole library, newest photos first, in batches of 1,000, skipping anything
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
            let pending = (first.filter { !$0.isVideo } + rest).filter { analyses[$0.id] == nil }
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
                    let curated = libraryPass?.curated ?? 0, batchDone = libraryPass?.batchDone ?? 0
                    let results = await model.analyze(chunk) { done in
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

    /// Every photo in the library, newest first. Videos are left for the trip pass.
    nonisolated private static func libraryNewestFirst() -> [MediaItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
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

    /// Eye's best landscape or nature photo among `items`, if it has found one.
    func natureCover(_ items: [MediaItem]) -> MediaItem? {
        kept(items).filter { !$0.isVideo && tags($0).contains(.landscapes) }.max { score($0) < score($1) }
    }

    func travelSignal(_ items: [MediaItem]) -> TravelSignal {
        let photos = items.filter { !$0.isVideo }
        let seen = photos.compactMap { analyses[$0.id] }
        return TravelSignal(photos: photos.count, seen: seen.count, nature: seen.filter { $0.tags.contains(.landscapes) }.count)
    }

    func discarded(_ items: [MediaItem]) -> [MediaItem] { items.filter(isDiscarded) }

    /// The top fifth of what is kept, ranked by score. At least one item when anything is kept.
    func bestOf(_ items: [MediaItem]) -> [MediaItem] {
        let ranked = kept(items).filter { analyses[$0.id] != nil }.sorted { score($0) > score($1) }
        return Array(ranked.prefix(max(1, Int((Double(ranked.count) * 0.2).rounded()))))
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
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        kept = stored.kept
        discarded = stored.discarded
        if stored.version == model.version { analyses = stored.analyses }
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
