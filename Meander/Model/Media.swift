import CoreLocation
import Photos

/// One photo or video from the Photos library.
struct MediaItem: Identifiable, Hashable, @unchecked Sendable {
    let asset: PHAsset

    var id: String { asset.localIdentifier }
    var date: Date { asset.creationDate ?? .distantPast }
    var location: CLLocation? { asset.location }
    var isVideo: Bool { asset.mediaType == .video }
    var duration: TimeInterval { asset.duration }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A trip found in the library: a run of photos taken away from home.
struct Trip: Identifiable, Hashable {
    let id: String
    var title: String
    var items: [MediaItem]
    var cities: [City] = []
    var unplacedCount = 0
    var isLocating = true
    /// Found by time, not place: a burst of photos with no location. Shown under Curated Trips.
    var isPossible = false

    var start: Date { items.first?.date ?? .distantPast }
    var end: Date { items.last?.date ?? .distantPast }

    static func == (lhs: Trip, rhs: Trip) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.cities == rhs.cities && lhs.isLocating == rhs.isLocating
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var month: String { TripDates.month(of: start) }

    var scope: MediaScope {
        MediaScope(id: id, tripID: id, title: title, subtitle: month, items: items)
    }
}

/// A city in a trip, with the named places inside it.
struct City: Identifiable, Hashable {
    let id: String
    let name: String
    let items: [MediaItem]
    let places: [Place]
}

struct Place: Identifiable, Hashable {
    let id: String
    let name: String
    let items: [MediaItem]
}

/// Any set of items that opens in the grid: a trip, city, place, day or week.
struct MediaScope: Identifiable, Hashable {
    let id: String
    let tripID: String
    let title: String
    var subtitle: String?
    let items: [MediaItem]

    static func == (lhs: MediaScope, rhs: MediaScope) -> Bool { lhs.id == rhs.id && lhs.items.count == rhs.items.count }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension City {
    func scope(tripID: String) -> MediaScope {
        MediaScope(id: "\(tripID)/\(id)", tripID: tripID, title: name, items: items)
    }
}

extension Place {
    func scope(tripID: String) -> MediaScope {
        MediaScope(id: "\(tripID)/\(id)", tripID: tripID, title: name, items: items)
    }
}

enum TripDates {
    /// When a trip was, as one short month in capitals: "AUG 2022". A trip that runs across months
    /// shows the month it started in. Used everywhere a trip's date is shown; the app never shows a range.
    static func month(of start: Date) -> String {
        start.formatted(.dateTime.month(.abbreviated).year()).uppercased()
    }
}
