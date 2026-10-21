import CoreLocation
import Foundation

/// Finds trips in a library, two ways.
///
/// By place: runs of photos taken far from home. A trip ends at the first photo taken back home,
/// or after a week with no photos away.
///
/// By time, for photos with no location (a camera without GPS, location turned off): a run of days
/// on which you took far more photos than you usually do, with nothing placing you at home.
enum TripFinder {
    static let awayDistance: CLLocationDistance = 60_000
    static let maxGap: TimeInterval = 7 * 24 * 3600
    static let minimumItems = 6

    /// A busy day has at least this many times your usual number of photos a day, and never fewer
    /// than `busyDayFloor`. A trip by time needs two busy days or more and `minimumTimedItems` photos.
    static let busyDayFactor = 3.0
    static let busyDayFloor = 12
    static let minimumTimedItems = 30
    /// Busy days this close together (a quiet day between them) are one trip.
    static let busyDayGap = 2
    static let longestTimedTrip = 30

    /// `items` must be sorted oldest first. Returns trips newest first.
    static func trips(in items: [MediaItem]) -> [Trip] {
        let home = home(of: items)
        let byPlace = home.map { tripsByPlace(in: items, home: $0) } ?? []
        let taken = Set(byPlace.flatMap { $0.items.map(\.id) })
        let byTime = tripsByTime(in: items, excluding: taken, home: home)
        return (byPlace + byTime).sorted { $0.start > $1.start }
    }

    private static func tripsByPlace(in items: [MediaItem], home: CLLocation) -> [Trip] {

        var trips: [Trip] = []
        var current: [MediaItem] = []
        var pending: [MediaItem] = []
        var lastAway = Date.distantPast
        var awayCount = 0

        func close() {
            if current.count >= minimumItems, awayCount >= 3 {
                let start = current.first!.date
                trips.append(Trip(
                    id: "trip-\(Int(start.timeIntervalSince1970))",
                    title: "Trip in \(start.formatted(.dateTime.month(.wide)))",
                    items: current
                ))
            }
            current = []
            pending = []
            awayCount = 0
        }

        for item in items {
            if !current.isEmpty, item.date.timeIntervalSince(lastAway) > maxGap { close() }

            if let location = item.location {
                guard location.distance(from: home) > awayDistance else {
                    if !current.isEmpty { close() }
                    continue
                }
                current += pending + [item]
                pending = []
                lastAway = item.date
                awayCount += 1
            } else if !current.isEmpty {
                // No location: part of the trip only if more away photos follow.
                pending.append(item)
            }
        }
        close()
        return trips
    }

    /// "August 17 – 19", or "August 30 – September 2" across a month's end. The year is left
    /// to the heading the trip sits under.
    static func dayRange(_ first: Date, _ last: Date) -> String {
        // Built from parts so it reads month-first whatever the phone's region.
        func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide)) }
        func day(_ date: Date) -> String { date.formatted(.dateTime.day()) }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        let end = sameMonth ? day(last) : "\(month(last)) \(day(last))"
        return "\(month(first)) \(day(first)) \u{2013} \(end)"
    }

    private static func tripsByTime(in items: [MediaItem], excluding taken: Set<String>, home: CLLocation?) -> [Trip] {
        let calendar = Calendar.current
        let everyDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        guard !everyDay.isEmpty else { return [] }

        // Your usual day: the median number of photos on days you took any.
        let counts = everyDay.values.map(\.count).sorted()
        let usual = Double(counts[counts.count / 2])
        let busy = max(Int((usual * busyDayFactor).rounded(.up)), busyDayFloor)

        let candidates = Dictionary(grouping: items.filter { !taken.contains($0.id) }) { calendar.startOfDay(for: $0.date) }
        func isAway(_ day: [MediaItem]) -> Bool {
            guard let home else { return true }
            let atHome = day.filter { ($0.location?.distance(from: home) ?? .infinity) < awayDistance }.count
            return Double(atHome) < 0.2 * Double(day.count)
        }
        let busyDays = candidates.filter { $0.value.count >= busy && isAway($0.value) }.keys.sorted()

        // Join busy days into runs, allowing a quiet day or two between them.
        var runs: [[Date]] = []
        for day in busyDays {
            if let last = runs.last?.last,
               let gap = calendar.dateComponents([.day], from: last, to: day).day, gap <= busyDayGap,
               let first = runs.last?.first,
               (calendar.dateComponents([.day], from: first, to: day).day ?? 0) < longestTimedTrip {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }

        return runs.compactMap { run -> Trip? in
            guard run.count >= 2, let first = run.first, let last = run.last,
                  let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
            let tripItems = items.filter { !taken.contains($0.id) && $0.date >= first && $0.date < end }
            guard tripItems.count >= minimumTimedItems else { return nil }
            return Trip(
                id: "time-\(Int(first.timeIntervalSince1970))",
                title: dayRange(first, last),
                items: tripItems,
                isPossible: true
            )
        }
    }

    /// Home is where you take photos on the most different days. A trip can produce more
    /// photos than home does, but home photos are spread over months. Each 25km square also
    /// counts its neighbours so a home on a square's edge is not split in two.
    static func home(of items: [MediaItem]) -> CLLocation? {
        struct Cell: Hashable { let lat: Int; let lon: Int }
        let calendar = Calendar.current
        var days: [Cell: Set<Date>] = [:]
        var locations: [Cell: [CLLocation]] = [:]
        for item in items {
            guard let location = item.location else { continue }
            let cell = Cell(lat: Int((location.coordinate.latitude * 4).rounded()), lon: Int((location.coordinate.longitude * 4).rounded()))
            days[cell, default: []].insert(calendar.startOfDay(for: item.date))
            locations[cell, default: []].append(location)
        }
        func neighbourhood(_ cell: Cell) -> [Cell] {
            (-1...1).flatMap { dLat in (-1...1).map { dLon in Cell(lat: cell.lat + dLat, lon: cell.lon + dLon) } }
        }
        guard let best = days.keys.max(by: { a, b in
            let daysA = neighbourhood(a).reduce(into: Set<Date>()) { $0.formUnion(days[$1] ?? []) }.count
            let daysB = neighbourhood(b).reduce(into: Set<Date>()) { $0.formUnion(days[$1] ?? []) }.count
            return daysA == daysB ? (locations[a]?.count ?? 0) < (locations[b]?.count ?? 0) : daysA < daysB
        }) else { return nil }
        let points = neighbourhood(best).flatMap { locations[$0] ?? [] }
        let latitude = points.map(\.coordinate.latitude).reduce(0, +) / Double(points.count)
        let longitude = points.map(\.coordinate.longitude).reduce(0, +) / Double(points.count)
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}
