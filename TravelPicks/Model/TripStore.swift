import CoreLocation
import Observation
import Photos

/// A trip the user has added to TravelPicks. It points at photos in the library; it does not copy them.
struct SavedTrip: Identifiable, Codable, Hashable {
    struct Pin: Codable, Hashable, Identifiable {
        var name: String
        var latitude: Double
        var longitude: Double
        var id: String { name }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    var id = UUID()
    var title: String
    var pins: [Pin]
    var assetIDs: [String]
    /// The cover the user chose. When nil, Eye's top-scored photo is the cover.
    var coverID: String?
    var start: Date
    var end: Date
    /// Journal entries, shown among the photos at the moment they're dated.
    var notes: [JournalNote] = []
    var bookStyle: BookStyle = .gallery
    /// The line under the title, when the user has written their own. Nil shows the places.
    var customSubtitle: String?

    /// The month the trip started in, from its earliest photo: "November 2025".
    var month: String { TripDates.month(of: start) }

    /// The user's own description, or the places: "Bangkok • Chiang Mai • Koh Samui".
    var subtitle: String { customSubtitle ?? placesLine }

    var placesLine: String { pins.map(\.name).joined(separator: " \u{2022} ") }
}

/// A typed journal entry in an album.
struct JournalNote: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    /// Where the entry sits among the photos.
    var date: Date
    /// Whether the date is printed on the entry. It still sets the entry's place either way.
    var showsDate = true
}

extension JournalNote {
    private enum CodingKeys: String, CodingKey { case id, text, date, showsDate }

    /// Entries saved before the date toggle existed have no `showsDate` key.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        showsDate = try c.decodeIfPresent(Bool.self, forKey: .showsDate) ?? true
    }
}

extension SavedTrip {
    private enum CodingKeys: String, CodingKey { case id, title, pins, assetIDs, coverID, start, end, notes, bookStyle, customSubtitle }

    /// Albums saved before journal entries existed have no `notes` key.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pins = try c.decode([Pin].self, forKey: .pins)
        assetIDs = try c.decode([String].self, forKey: .assetIDs)
        coverID = try c.decodeIfPresent(String.self, forKey: .coverID)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        notes = try c.decodeIfPresent([JournalNote].self, forKey: .notes) ?? []
        bookStyle = (try? c.decodeIfPresent(BookStyle.self, forKey: .bookStyle)) ?? .gallery
        customSubtitle = try c.decodeIfPresent(String.self, forKey: .customSubtitle)
    }
}

@MainActor @Observable
final class TripStore {
    private(set) var trips: [SavedTrip] = []
    @ObservationIgnored private var assets: [String: PHAsset] = [:]
    private let fileURL = URL.applicationSupportDirectory.appending(path: "trips.json")

    init() {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode([SavedTrip].self, from: data) {
            trips = stored
        }
    }

    func trip(_ id: UUID) -> SavedTrip? { trips.first { $0.id == id } }

    /// Adds picked media to a trip, or starts a new trip when `tripID` is nil.
    @discardableResult
    func add(_ items: [MediaItem], title: String, pins: [SavedTrip.Pin], to tripID: UUID?) -> UUID? {
        guard !items.isEmpty else { return tripID }
        for item in items { assets[item.id] = item.asset }
        let dates = items.map(\.date)

        if let tripID, let index = trips.firstIndex(where: { $0.id == tripID }) {
            var trip = trips[index]
            let known = Set(trip.assetIDs)
            trip.assetIDs += items.map(\.id).filter { !known.contains($0) }
            for pin in pins where !trip.pins.contains(where: { $0.name == pin.name }) { trip.pins.append(pin) }
            trip.start = min(trip.start, dates.min()!)
            trip.end = max(trip.end, dates.max()!)
            trips[index] = trip
            save()
            return tripID
        }

        let trip = SavedTrip(title: title, pins: pins, assetIDs: items.map(\.id), start: dates.min()!, end: dates.max()!)
        trips.insert(trip, at: 0)
        save()
        return trip.id
    }

    func rename(_ trip: SavedTrip, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].title = title
        save()
    }

    /// Sets the line under the title. An empty description goes back to listing the places.
    func setDescription(_ text: String, for trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trips[index].customSubtitle = text.isEmpty ? nil : text
        save()
    }

    func setBookStyle(_ style: BookStyle, for trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].bookStyle = style
        save()
    }

    func setCover(_ item: MediaItem, for trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].coverID = item.id
        save()
    }

    /// The chosen cover, or Eye's pick when none was chosen or the chosen one is gone from Photos.
    func cover(for trip: SavedTrip, curator: Curator) -> MediaItem? {
        let items = items(for: trip)
        return items.first { $0.id == trip.coverID } ?? curator.cover(items)
    }

    /// Takes one item out of a trip. The photo stays in Photos.
    func remove(_ item: MediaItem, from trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].assetIDs.removeAll { $0 == item.id }
        if trips[index].coverID == item.id { trips[index].coverID = nil }
        save()
    }

    /// Adds a journal entry, or replaces the one with the same id.
    func save(_ note: JournalNote, in trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        if let existing = trips[index].notes.firstIndex(where: { $0.id == note.id }) {
            trips[index].notes[existing] = note
        } else {
            trips[index].notes.append(note)
        }
        save()
    }

    func delete(_ note: JournalNote, from trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].notes.removeAll { $0.id == note.id }
        save()
    }

    func delete(_ trip: SavedTrip) {
        trips.removeAll { $0.id == trip.id }
        save()
    }

    /// The trip's media, oldest first. Items deleted from Photos since they were added are skipped.
    func items(for trip: SavedTrip) -> [MediaItem] {
        let missing = trip.assetIDs.filter { assets[$0] == nil }
        if !missing.isEmpty, PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined {
            PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
                self.assets[asset.localIdentifier] = asset
            }
        }
        return trip.assetIDs.compactMap { assets[$0] }.map(MediaItem.init).sorted { $0.date < $1.date }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(trips) { try? data.write(to: fileURL, options: .atomic) }
    }
}
