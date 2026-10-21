import MapKit
import SwiftUI

/// Every place from every trip on one satellite map, drawn like a trip's own map:
/// a photo at each place and a line along the roads between a trip's places. Tap a photo to open its trip.
struct TripsMapView: View {
    @Environment(TripStore.self) private var store
    @Environment(Curator.self) private var curator
    let onOpen: (UUID) -> Void

    @State private var position: MapCameraPosition = .automatic
    /// Road routes between a trip's places, by leg. A leg is missing until it has been looked up.
    @State private var roads: [String: [CLLocationCoordinate2D]] = [:]

    private struct Stop: Identifiable {
        let id: String
        let tripID: UUID
        let name: String
        let coordinate: CLLocationCoordinate2D
        let photo: MediaItem?
    }

    private struct Leg: Identifiable {
        let id: String
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
    }

    private var stops: [Stop] {
        store.trips.flatMap { trip in
            let located = store.items(for: trip).filter { $0.location != nil }
            return trip.pins.map { pin in
                // The pin's photo: Eye's pick from the shots taken nearest to it.
                let here = CLLocation(latitude: pin.latitude, longitude: pin.longitude)
                let nearby = located.filter { $0.location!.distance(from: here) < 30_000 }
                return Stop(
                    id: "\(trip.id)|\(pin.name)", tripID: trip.id, name: pin.name, coordinate: pin.coordinate,
                    photo: curator.cover(nearby) ?? store.cover(for: trip, curator: curator)
                )
            }
        }
    }

    private var legs: [Leg] {
        store.trips.flatMap { trip in
            zip(trip.pins, trip.pins.dropFirst()).map { from, to in
                Leg(id: RouteCache.key(from.coordinate, to.coordinate), from: from.coordinate, to: to.coordinate)
            }
        }
    }

    var body: some View {
        let stops = stops
        let legs = legs
        Map(position: $position) {
            ForEach(legs) { leg in
                if let road = roads[leg.id] {
                    MapPolyline(coordinates: road).stroke(Color.paper, style: TripRouteMap.line)
                }
            }
            ForEach(stops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                    Button {
                        onOpen(stop.tripID)
                    } label: {
                        Group {
                            if let photo = stop.photo {
                                AssetImage(asset: photo.asset)
                            } else {
                                Color.surface
                            }
                        }
                        .frame(width: 34, height: 34)
                        .clipShape(.circle)
                        .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open album at \(stop.name)")
                }
            }
        }
        .mapStyle(.hybrid(elevation: .flat))
        .overlay(alignment: .bottom) {
            if stops.isEmpty {
                Text("Your albums have no places yet. Photos need location data to appear on the map.")
                    .font(.text(.footnote))
                    .multilineTextAlignment(.center)
                    .padding()
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .padding()
            }
        }
        .onAppear { position = .region(Self.region(around: stops.map(\.coordinate))) }
        .task(id: legs.map(\.id)) { await findRoads(legs) }
    }

    private func findRoads(_ legs: [Leg]) async {
        await withTaskGroup(of: (String, [CLLocationCoordinate2D]?).self) { group in
            for leg in legs where roads[leg.id] == nil {
                if let known = RouteCache.shared.routes[leg.id] {
                    roads[leg.id] = known
                    continue
                }
                group.addTask { (leg.id, await TripRouteMap.drive(from: leg.from, to: leg.to)) }
            }
            for await (id, road) in group {
                guard let road else { continue }
                RouteCache.shared.store(road, for: id)
                roads[id] = road
            }
        }
    }

    /// Fits every pin with room to spare, and never closer than about a country.
    private static func region(around points: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = points.first else { return MKCoordinateRegion(.world) }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for point in points {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: min(max((maxLat - minLat) * 1.6, 12), 150),
                longitudeDelta: min(max((maxLon - minLon) * 1.6, 12), 340)
            )
        )
    }
}
