import Observation
import Photos
import PhotosUI
import UIKit

@MainActor @Observable
final class PhotoLibrary {
    enum Access { case unknown, denied, full, limited }

    private(set) var access: Access = .unknown
    private(set) var trips: [Trip] = []
    private(set) var isLoading = false

    private let namer = PlaceNamer()

    func start() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized: access = .full
        case .limited: access = .limited
        default: access = .denied; return
        }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let found = await Task.detached(priority: .userInitiated) {
            TripFinder.trips(in: Self.fetchAll())
        }.value
        trips = found.map { found in trips.first { $0.id == found.id && $0.items.count == found.items.count } ?? found }

        for index in trips.indices where trips[index].isLocating {
            let described = await namer.describe(trips[index])
            if let current = trips.firstIndex(where: { $0.id == described.id }) { trips[current] = described }
        }
    }

    func trip(_ id: String) -> Trip? { trips.first { $0.id == id } }

    /// Names a set of picked items after the library trip and cities they come from.
    func describe(_ items: [MediaItem]) -> (title: String, pins: [SavedTrip.Pin]) {
        let picked = Set(items.map(\.id))
        var title = "New Trip"
        var most = 0
        var pins: [SavedTrip.Pin] = []
        for trip in trips {
            let overlap = trip.items.filter { picked.contains($0.id) }.count
            guard overlap > 0 else { continue }
            if overlap > most { most = overlap; title = trip.title }
            for city in trip.cities {
                let points = city.items.filter { picked.contains($0.id) }.compactMap(\.location)
                guard !points.isEmpty, !pins.contains(where: { $0.name == city.name }) else { continue }
                pins.append(SavedTrip.Pin(
                    name: city.name,
                    latitude: points.map(\.coordinate.latitude).reduce(0, +) / Double(points.count),
                    longitude: points.map(\.coordinate.longitude).reduce(0, +) / Double(points.count)
                ))
            }
        }
        return (title, pins)
    }

    func manageLimitedSelection() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root) { _ in
            Task { await self.load() }
        }
    }

    nonisolated private static func fetchAll() -> [MediaItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var items: [MediaItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if asset.creationDate != nil { items.append(MediaItem(asset: asset)) }
        }
        return items
    }
}
