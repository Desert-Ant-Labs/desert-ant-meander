import CoreLocation
import Foundation

struct PlaceName: Codable, Hashable, Sendable {
    var country: String?
    var region: String?
    var city: String?
    var area: String?
}

/// Names places with the system geocoder, once per ~2km square, and keeps the answers on disk.
/// The geocoder is rate limited, so a trip is named from its busiest squares first.
actor PlaceNamer {
    private var cache: [String: PlaceName] = [:]
    private let fileURL = URL.applicationSupportDirectory.appending(path: "places.json")
    private let geocoder = CLGeocoder()
    private static let maxLookupsPerTrip = 40

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: PlaceName].self, from: data) {
            cache = stored
        }
    }

    /// Fills in a trip's title, cities and places.
    func describe(_ trip: Trip) async -> Trip {
        let located = trip.items.filter { $0.location != nil }
        let cells = Dictionary(grouping: located) { Self.key($0.location!) }
        let busiest = cells.sorted { $0.value.count > $1.value.count }.prefix(Self.maxLookupsPerTrip)

        var names: [String: (CLLocation, PlaceName)] = [:]
        for (key, items) in busiest {
            if let name = await name(key: key, location: items[0].location!) {
                names[key] = (items[0].location!, name)
            }
        }
        save()

        // Named squares within 25km of each other are one city. Districts of one city
        // (Chatuchak, Pathum Wan) take the name of the province they share (Bangkok).
        let named = names.map { (key: $0.key, location: $0.value.0, name: $0.value.1) }
        var cluster = Array(named.indices)
        func root(_ i: Int) -> Int { cluster[i] == i ? i : root(cluster[i]) }
        for i in named.indices {
            for j in named.indices where j > i && named[i].location.distance(from: named[j].location) < 25_000 {
                cluster[root(j)] = root(i)
            }
        }
        var clusterOf: [String: Int] = [:]
        for i in named.indices { clusterOf[named[i].key] = root(i) }

        func nearest(_ item: MediaItem) -> Int? {
            if clusterOf[Self.key(item.location!)] != nil { return named.firstIndex { $0.key == Self.key(item.location!) } }
            return named.indices.min { named[$0].location.distance(from: item.location!) < named[$1].location.distance(from: item.location!) }
        }

        var groups: [Int: [(MediaItem, PlaceName)]] = [:]
        var unplaced = trip.items.count - located.count
        for item in located {
            guard let index = nearest(item) else { unplaced += 1; continue }
            groups[root(index), default: []].append((item, named[index].name))
        }

        var countries: [String: Int] = [:]
        var cities: [City] = []
        var regionOfOnlyCity: String?
        for members in groups.values {
            let localities = Set(members.compactMap { Self.clean($0.1.city) })
            let regions = Set(members.compactMap(\.1.region))
            let cityName: String
            if localities.count == 1 {
                cityName = localities.first!
            } else if regions.count == 1 {
                cityName = Self.clean(regions.first) ?? regions.first!
            } else {
                cityName = Self.mostCommon(members.compactMap { Self.clean($0.1.city) }) ?? members[0].1.country ?? "Unknown"
            }
            for member in members { if let country = member.1.country { countries[country, default: 0] += 1 } }
            regionOfOnlyCity = regions.count == 1 ? regions.first : nil

            let items = members.map(\.0)
            let areas = Dictionary(grouping: members.filter { $0.1.area != nil && $0.1.area != cityName }) { $0.1.area! }
            let places = areas
                .filter { $0.value.count >= 2 }
                .map { Place(id: "\(cityName)/\($0.key)", name: $0.key, items: $0.value.map(\.0)) }
                .sorted { $0.items[0].date < $1.items[0].date }
            cities.append(City(id: cityName, name: cityName, items: items, places: places))
        }

        var described = trip
        described.cities = cities.sorted { $0.items[0].date < $1.items[0].date }
        described.unplacedCount = unplaced
        described.isLocating = false

        let countryNames = countries.sorted { $0.value > $1.value }.map(\.key)
        if countryNames.count == 1, described.cities.count == 1, let city = described.cities.first?.name {
            if let region = Self.clean(regionOfOnlyCity), region != city { described.title = "\(city), \(region)" } else { described.title = city }
        } else if countryNames.count == 1 {
            described.title = countryNames[0]
        } else if countryNames.count == 2 {
            described.title = "\(countryNames[0]) & \(countryNames[1])"
        } else if countryNames.count > 2 {
            described.title = "\(countryNames[0]), \(countryNames[1]) +\(countryNames.count - 2)"
        }
        return described
    }

    private func name(key: String, location: CLLocation) async -> PlaceName? {
        if let cached = cache[key] { return cached }
        for attempt in 0..<3 {
            do {
                guard let placemark = try await geocoder.reverseGeocodeLocation(location).first else { return nil }
                let name = PlaceName(
                    country: placemark.country,
                    region: placemark.administrativeArea,
                    city: placemark.locality ?? placemark.subAdministrativeArea,
                    area: placemark.areasOfInterest?.first ?? placemark.subLocality
                )
                cache[key] = name
                return name
            } catch {
                // Throttled or offline: wait and try again, then give up on this square.
                try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        return nil
    }

    /// "Ko Samui District" reads as "Ko Samui", "Mueang Chiang Mai District" as "Chiang Mai".
    private static func clean(_ name: String?) -> String? {
        guard var name else { return nil }
        for suffix in [" District", " City", " Province"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        if name.hasPrefix("Mueang ") { name.removeFirst("Mueang ".count) }
        return name
    }

    private static func mostCommon(_ names: [String]) -> String? {
        Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: fileURL, options: .atomic) }
    }

    private static func key(_ location: CLLocation) -> String {
        "\(Int((location.coordinate.latitude * 50).rounded())),\(Int((location.coordinate.longitude * 50).rounded()))"
    }
}
