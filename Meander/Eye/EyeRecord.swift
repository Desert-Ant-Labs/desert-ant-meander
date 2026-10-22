import Eye
import Foundation

/// What Eye said about one photo or video, kept on disk so Meander's rules (what counts as Golden Hour,
/// what's a duplicate) can change and be applied again in seconds, without running Eye again.
/// Only what the rules read is kept: tag confidences, the keeper score, the fingerprint duplicates are
/// found with, and the colour of the sky.
struct EyeRecord: Codable, Sendable {
    /// Confidence for each tag, `0...1`. Tags below `floor` are left out to keep records small.
    var tags: [String: Float]
    var keeper: Double?
    /// Eye's 512-number fingerprint of the photo, as half-precision floats.
    var embedding: Data?
    /// Whether the top of the photo is the pink or orange of a sunrise or sunset.
    var warmSky: Bool

    static let floor: Float = 0.25

    init(_ analysis: Analysis, warmSky: Bool) {
        tags = analysis.confidences.reduce(into: [:]) { tags, entry in
            if Float(entry.value) >= Self.floor { tags[entry.key.rawValue] = Float(entry.value) }
        }
        keeper = analysis.scores?.keeper
        embedding = analysis.embedding.map { vector in
            vector.map { Float16($0) }.withUnsafeBytes { Data($0) }
        }
        self.warmSky = warmSky
    }

    enum Level {
        /// 0.5, the cutoff Eye recommends.
        case recommended
        /// 0.9.
        case strict
    }

    func has(_ tag: Tag, _ level: Level = .recommended) -> Bool {
        confidence(tag) >= (level == .strict ? 0.9 : 0.5)
    }

    /// `0...1`; 0 for a tag below `floor`.
    func confidence(_ tag: Tag) -> Double { Double(tags[tag.rawValue] ?? 0) }

    /// The fingerprint as full floats, for comparing photos.
    var vector: [Float]? {
        embedding.map { data in
            data.withUnsafeBytes { raw in
                (0..<raw.count / 2).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Float16.self)) }
            }
        }
    }

    /// Cosine similarity of two fingerprints, `-1...1`. Near-duplicates are above about 0.9.
    static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return Double(sum)
    }
}

/// Eye's records on disk: a folder per Eye version, each save a small file of its own, so saving as Eye
/// goes never rewrites everything. Loading merges the files (later ones win) and folds them into one.
actor EyeRecordStore {
    private let folder: URL

    init(modelVersion: String) {
        let root = URL.applicationSupportDirectory.appending(path: "eye-records")
        folder = root.appending(path: modelVersion)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Records from another Eye version can't be used; free the space.
        let others = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for other in others where other.lastPathComponent != modelVersion {
            try? FileManager.default.removeItem(at: other)
        }
    }

    func append(_ records: [String: EyeRecord]) {
        guard !records.isEmpty, let data = try? Self.encoder.encode(records) else { return }
        try? data.write(to: folder.appending(path: Self.newName()), options: .atomic)
    }

    func loadAll() -> [String: EyeRecord] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var all: [String: EyeRecord] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let records = try? PropertyListDecoder().decode([String: EyeRecord].self, from: data) else { continue }
            all.merge(records) { _, newer in newer }
        }
        // Fold many small files into one.
        if files.count > 1, let data = try? Self.encoder.encode(all) {
            let merged = folder.appending(path: Self.newName())
            if (try? data.write(to: merged, options: .atomic)) != nil {
                for file in files { try? FileManager.default.removeItem(at: file) }
            }
        }
        return all
    }

    private static let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    /// Sorts by when it was written.
    private static func newName() -> String {
        String(format: "%015.4f-%@.plist", Date().timeIntervalSince1970, UUID().uuidString)
    }
}
