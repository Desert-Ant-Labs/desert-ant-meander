import CoreLocation
import Observation
import Photos

/// A trip the user has added to Meander. It points at photos in the library; it does not copy them.
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
    /// The album's media in the order it shows.
    var assetIDs: [String]
    /// Whether `assetIDs` is the album's order: the order media was picked in, with later additions
    /// placed after the photo that was on screen. Albums saved before that show oldest first
    /// until something is added to them.
    var keepsOwnOrder = true
    /// The cover the user chose. When nil, Eye's top-scored photo is the cover.
    var coverID: String?
    var start: Date
    var end: Date
    /// Journal entries, each shown after the photo it follows.
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
    /// Where an entry sits among the album's media.
    enum Place: Codable, Hashable {
        /// Before the first photo.
        case start
        /// After this photo or video.
        case after(String)
        /// Entries written before entries followed a photo: after the last photo taken by `date`.
        case byDate
    }

    var id = UUID()
    var text: String
    /// The date printed on the entry.
    var date: Date
    var place: Place = .start
    /// Whether the date is printed on the entry.
    var showsDate = true
}

extension JournalNote {
    private enum CodingKeys: String, CodingKey { case id, text, date, place, showsDate }

    /// Entries saved before the date toggle existed have no `showsDate` key,
    /// and ones saved before entries followed a photo have no `place`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        place = try c.decodeIfPresent(Place.self, forKey: .place) ?? .byDate
        showsDate = try c.decodeIfPresent(Bool.self, forKey: .showsDate) ?? true
    }
}

/// Where added media goes in an album.
enum MediaPosition: Hashable {
    case start
    case after(String)
    case end
}

/// Journal entries placed among some of an album's media.
struct NotePlacement {
    /// Entries before the first item.
    var opening: [JournalNote] = []
    /// Entries after each item, by the item's id.
    var after: [String: [JournalNote]] = [:]
}

extension SavedTrip {
    private enum CodingKeys: String, CodingKey { case id, title, pins, assetIDs, keepsOwnOrder, coverID, start, end, notes, bookStyle, customSubtitle }

    /// Albums saved before journal entries existed have no `notes` key,
    /// and ones saved before albums kept their own order have no `keepsOwnOrder`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pins = try c.decode([Pin].self, forKey: .pins)
        assetIDs = try c.decode([String].self, forKey: .assetIDs)
        keepsOwnOrder = try c.decodeIfPresent(Bool.self, forKey: .keepsOwnOrder) ?? false
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

    /// Adds picked media to a trip at `position`, in the order it was picked,
    /// or starts a new trip when `tripID` is nil.
    @discardableResult
    func add(_ items: [MediaItem], title: String, pins: [SavedTrip.Pin], to tripID: UUID?, at position: MediaPosition = .end) -> UUID? {
        guard !items.isEmpty else { return tripID }
        for item in items { assets[item.id] = item.asset }
        let dates = items.map(\.date)

        if let tripID, let index = trips.firstIndex(where: { $0.id == tripID }) {
            var trip = trips[index]
            if !trip.keepsOwnOrder { fixOrder(of: &trip) }
            let known = Set(trip.assetIDs)
            let insertAt = switch position {
            case .start: 0
            case .after(let id): trip.assetIDs.firstIndex(of: id).map { $0 + 1 } ?? trip.assetIDs.count
            case .end: trip.assetIDs.count
            }
            trip.assetIDs.insert(contentsOf: items.map(\.id).filter { !known.contains($0) }, at: insertAt)
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

    /// Turns an album that showed oldest first into one that keeps its own order, starting from
    /// the order it showed. Its journal entries follow the photo they showed after.
    private func fixOrder(of trip: inout SavedTrip) {
        let shown = items(for: trip)
        let shownIDs = Set(shown.map(\.id))
        // Items missing from Photos for now keep their place at the end.
        trip.assetIDs = shown.map(\.id) + trip.assetIDs.filter { !shownIDs.contains($0) }
        for n in trip.notes.indices where trip.notes[n].place == .byDate {
            let date = trip.notes[n].date
            trip.notes[n].place = shown.last { $0.date <= date }.map { .after($0.id) } ?? .start
        }
        trip.keepsOwnOrder = true
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
    /// Entries that followed it move up to follow the item before it.
    func remove(_ item: MediaItem, from trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        let order = items(for: trip)
        let before = order.firstIndex(of: item).flatMap { $0 > 0 ? order[$0 - 1].id : nil }
        for n in trips[index].notes.indices where trips[index].notes[n].place == .after(item.id) {
            trips[index].notes[n].place = before.map { .after($0) } ?? .start
        }
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

    /// The trip's media in album order. Items deleted from Photos since they were added are skipped.
    func items(for trip: SavedTrip) -> [MediaItem] {
        let missing = trip.assetIDs.filter { assets[$0] == nil }
        if !missing.isEmpty, PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined {
            PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
                self.assets[asset.localIdentifier] = asset
            }
        }
        let items = trip.assetIDs.compactMap { assets[$0] }.map(MediaItem.init)
        return trip.keepsOwnOrder ? items : items.sorted { $0.date < $1.date }
    }

    /// Places the trip's journal entries among `shown`, some of its media in album order.
    /// An entry that follows an item not shown goes after the nearest shown item before it.
    /// Entries in the same place go oldest first.
    func placeNotes(in trip: SavedTrip, among shown: [MediaItem]) -> NotePlacement {
        let order = items(for: trip)
        let shownIDs = Set(shown.map(\.id))
        var placement = NotePlacement()
        for note in trip.notes.sorted(by: { $0.date < $1.date }) {
            let anchor: String? = switch note.place {
            case .start: nil
            case .after(let id):
                order.firstIndex { $0.id == id }.flatMap { i in order[...i].last { shownIDs.contains($0.id) }?.id }
            case .byDate: shown.last { $0.date <= note.date }?.id
            }
            if let anchor { placement.after[anchor, default: []].append(note) } else { placement.opening.append(note) }
        }
        return placement
    }

    private func save() {
        if let data = try? JSONEncoder().encode(trips) { try? data.write(to: fileURL, options: .atomic) }
    }
}
