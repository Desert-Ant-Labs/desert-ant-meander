import MapKit
import SwiftUI

/// One place the trip stopped at, in the order it was visited.
struct TripStop: Identifiable, Equatable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let cover: MediaItem

    static func == (lhs: TripStop, rhs: TripStop) -> Bool {
        lhs.id == rhs.id && lhs.cover == rhs.cover
            && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

enum TripRoute {
    static let maxStops = 12

    /// Walks the trip's photos in time order and starts a new stop each time they move far enough.
    /// "Far enough" scales with the trip, so a city break and a tour of a country both get a handful of stops.
    static func stops(for items: [MediaItem], cover: ([MediaItem]) -> MediaItem?) -> [TripStop] {
        let located = items.filter { $0.location != nil }.sorted { $0.date < $1.date }
        guard let first = located.first?.location else { return [] }

        let span = located.map { $0.location!.distance(from: first) }.max() ?? 0
        var threshold = max(800, span / 10)
        var groups: [[MediaItem]] = []

        repeat {
            groups = []
            var centre = first
            for item in located {
                if groups.isEmpty || item.location!.distance(from: centre) > threshold {
                    groups.append([item])
                    centre = item.location!
                } else {
                    groups[groups.count - 1].append(item)
                }
            }
            threshold *= 1.5
        } while groups.count > maxStops

        return groups.enumerated().compactMap { index, group in
            guard let photo = cover(group) ?? group.first else { return nil }
            let points = group.map { $0.location!.coordinate }
            return TripStop(
                id: index,
                coordinate: CLLocationCoordinate2D(
                    latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
                    longitude: points.map(\.longitude).reduce(0, +) / Double(points.count)
                ),
                cover: photo
            )
        }
    }
}

/// The trip drawn on a satellite map: a photo at each stop and a line joining them in order.
/// Every leg follows the road, however long. A leg only runs straight when Maps has no driving
/// route for it at all, such as a flight to an island.
struct TripRouteMap: View {
    let stops: [TripStop]

    /// A leg is missing while its route is being looked up, so a straight line never flashes first.
    @State private var legs: [Int: Leg] = [:]

    private enum Leg {
        case road([CLLocationCoordinate2D])
        case noRoad
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            ForEach(Array(zip(stops, stops.dropFirst())), id: \.0.id) { from, to in
                switch legs[from.id] {
                case .road(let road):
                    MapPolyline(coordinates: road).stroke(Color.paper, style: Self.line)
                case .noRoad:
                    MapPolyline(coordinates: [from.coordinate, to.coordinate], contourStyle: .geodesic)
                        .stroke(Color.paper, style: Self.line)
                case nil:
                    EmptyMapContent()
                }
            }
            ForEach(stops) { stop in
                Annotation("", coordinate: stop.coordinate, anchor: .center) {
                    AssetImage(asset: stop.cover.asset)
                        .frame(width: 28, height: 28)
                        .clipShape(.circle)
                        .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .flat))
        .allowsHitTesting(false)
        .id(stops.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }.joined())
        .task(id: stops.count) { await findRoads() }
        .accessibilityLabel("Map of the album with \(stops.count) stops")
    }

    static let line = StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)

    /// Every stop, with room around the edge for the photo circles.
    var region: MKCoordinateRegion { Self.region(for: stops) }

    static func region(for stops: [TripStop]) -> MKCoordinateRegion {
        let lats = stops.map(\.coordinate.latitude), lons = stops.map(\.coordinate.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(.world)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.7, 0.03),
                longitudeDelta: max((maxLon - minLon) * 1.7, 0.03)
            )
        )
    }

    /// Looks up every leg at once. Routes already saved on the device draw straight away.
    private func findRoads() async {
        await withTaskGroup(of: (Int, Leg).self) { group in
            for (from, to) in zip(stops, stops.dropFirst()) where legs[from.id] == nil {
                let key = RouteCache.key(from.coordinate, to.coordinate)
                if let known = RouteCache.shared.routes[key] {
                    legs[from.id] = .road(known)
                    continue
                }
                let id = from.id, a = from.coordinate, b = to.coordinate
                group.addTask {
                    guard let road = await Self.drive(from: a, to: b) else { return (id, .noRoad) }
                    await RouteCache.shared.store(road, for: key)
                    return (id, .road(road))
                }
            }
            for await (id, leg) in group { legs[id] = leg }
        }
    }

    static func drive(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: a.latitude, longitude: a.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: b.latitude, longitude: b.longitude), address: nil)
        request.transportType = .automobile

        var route = try? await MKDirections(request: request).calculate().routes.first
        if route == nil, !Task.isCancelled {
            // Maps limits how fast routes can be asked for; one more try after a pause.
            try? await Task.sleep(for: .seconds(1.5))
            route = try? await MKDirections(request: request).calculate().routes.first
        }
        guard let line = route?.polyline else { return nil }
        var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: line.pointCount)
        line.getCoordinates(&points, range: NSRange(location: 0, length: line.pointCount))
        return points
    }
}

/// Road routes between stops, saved on the device so a trip's map draws without waiting.
@MainActor
final class RouteCache {
    static let shared = RouteCache()

    private(set) var routes: [String: [CLLocationCoordinate2D]] = [:]
    private let fileURL = URL.cachesDirectory.appending(path: "routes.json")

    private init() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return }
        routes = stored.mapValues { flat in
            stride(from: 0, to: flat.count - 1, by: 2).map { CLLocationCoordinate2D(latitude: flat[$0], longitude: flat[$0 + 1]) }
        }
    }

    nonisolated static func key(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> String {
        [a.latitude, a.longitude, b.latitude, b.longitude].map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    func store(_ road: [CLLocationCoordinate2D], for key: String) {
        routes[key] = road
        let flat = routes.mapValues { $0.flatMap { [$0.latitude, $0.longitude] } }
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(flat) { try? data.write(to: url, options: .atomic) }
        }
    }
}
