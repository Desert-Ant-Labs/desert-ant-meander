import CoreLocation
import SwiftUI

struct PickerTripsView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(Curator.self) private var curator
    @Environment(\.openURL) private var openURL
    @Environment(\.pickerNear) private var near
    /// How far each trip is from the album's places, worked out once per set of trips.
    @State private var distances: [String: CLLocationDistance] = [:]
    @State private var grouping = Grouping.location

    /// Trips found by where photos were taken, or by busy days with no location.
    enum Grouping: String, CaseIterable, Identifiable {
        case location = "by Location", date = "by Date"
        var id: Self { self }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .canvas()
            .barTitle("Add Media")
            .task(id: library.trips.map(\.id)) { distances = Self.distances(of: library.trips, from: near) }
    }

    @ViewBuilder
    private var content: some View {
        switch library.access {
        case .unknown:
            LoadingTrips()
        case .denied:
            ContentUnavailableView {
                Label("Allow access to Photos", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Meander finds your trips in Photos and picks the best shots from each one.")
            } actions: {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("Open Settings").foregroundStyle(Color.canvas)
                }
                .buttonStyle(.borderedProminent)
            }
        case .full, .limited:
            if library.trips.isEmpty {
                if library.isLoading {
                    LoadingTrips()
                } else {
                    ContentUnavailableView {
                        Label("No trips yet", systemImage: "airplane")
                    } description: {
                        Text("Trips are found from where and when your photos were taken: days away from home, or busy days with many more photos than usual.")
                    } actions: {
                        if library.access == .limited {
                            Button("Choose More Photos") { library.manageLimitedSelection() }
                        }
                    }
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        let trips = ordered(library.trips.filter { !$0.isPossible })
        let possible = possibleTrips
        // The control only appears when there are trips of both kinds to choose between.
        let showsControl = !trips.isEmpty && !possible.isEmpty
        let shown = showsControl ? grouping : (trips.isEmpty ? .date : .location)

        return ScrollView {
            VStack(spacing: 12) {
                if library.access == .limited {
                    LimitedAccessBanner().padding(.horizontal)
                }
                EyeStatus().padding(.horizontal)

                if showsControl {
                    Picker("Trips", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                    .padding(.horizontal)
                }

                switch shown {
                case .location:
                    LazyVStack(spacing: CardMetrics.gap) {
                        ForEach(trips) { trip in
                            NavigationLink(value: Route.trip(trip.id)) { TripCard(trip: trip) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, CardMetrics.gap)

                case .date:
                    Text("Busy days including nature or landscapes")
                        .font(.serif(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    // Newest first.
                    LazyVStack(spacing: CardMetrics.gap) {
                        ForEach(possible) { trip in
                            // Curated trips have no places, so they open on their photos.
                            NavigationLink(value: Route.scope(trip.scope)) { TripCard(trip: trip) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, CardMetrics.gap)
                }
            }
            .padding(.top, 4)
            .padding(.bottom)
        }
        .refreshable { await library.load() }
    }

    /// When adding to an album with places, trips nearest those places come first. Otherwise newest first.
    private func ordered(_ trips: [Trip]) -> [Trip] {
        guard !distances.isEmpty else { return trips }
        return trips.enumerated().sorted { a, b in
            let da = distances[a.element.id] ?? .infinity, db = distances[b.element.id] ?? .infinity
            return da == db ? a.offset < b.offset : da < db
        }.map(\.element)
    }

    /// For each trip, the distance from its nearest photo to the nearest of the album's places.
    /// Up to 60 photos a trip are checked, spread across it, which is plenty to place it.
    private static func distances(of trips: [Trip], from near: [CLLocationCoordinate2D]) -> [String: CLLocationDistance] {
        guard !near.isEmpty else { return [:] }
        let places = near.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        var result: [String: CLLocationDistance] = [:]
        for trip in trips where !trip.isPossible {
            let located = trip.items.compactMap(\.location)
            guard !located.isEmpty else { continue }
            let step = max(1, located.count / 60)
            var nearest = CLLocationDistance.infinity
            for location in stride(from: 0, to: located.count, by: step).map({ located[$0] }) {
                for place in places { nearest = min(nearest, location.distance(from: place)) }
            }
            result[trip.id] = nearest
        }
        return result
    }

    /// Newest first. Groups Eye has judged and found little nature in are left out; groups it hasn't
    /// seen enough of yet stay in until it has.
    private var possibleTrips: [Trip] {
        library.trips
            .filter(\.isPossible)
            .filter { trip in
                let signal = curator.travelSignal(trip.items)
                return !signal.isJudged || signal.looksLikeTravel
            }
            .sorted { $0.start > $1.start }
    }
}

/// A trip as a photo card, the same card as albums on the home screen. A trip found by place shows
/// its month and cities beneath its name. A curated trip shows what was found in it, over its best
/// nature shot.
private struct TripCard: View {
    @Environment(Curator.self) private var curator
    let trip: Trip

    var body: some View {
        let cover = trip.isPossible ? curator.natureCover(trip.items) : curator.cover(trip.items)
        PhotoCard(cover: cover?.asset, title: trip.title, isLocating: !trip.isPossible && trip.isLocating) {
            if trip.isPossible {
                let signal = curator.travelSignal(trip.items)
                if signal.isJudged {
                    Text(cardDetail(["\(signal.nature) nature \(signal.nature == 1 ? "photo" : "photos")", "\(trip.items.count) in all"]))
                } else {
                    Text("Curating \(trip.items.count) photos\u{2026}").shimmer()
                }
            } else {
                let cities = trip.cities.map(\.name).filter { $0 != trip.title }.prefix(2)
                Text(cardDetail([trip.month] + cities))
            }
        }
    }
}

private struct LimitedAccessBanner: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        HStack {
            Label("Meander can only see the photos you chose.", systemImage: "photo.badge.exclamationmark")
                .font(.text(.footnote))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Change") { library.manageLimitedSelection() }
                .font(.text(.footnote, weight: .semibold))
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
    }
}

/// One quiet line while trips are still being sorted (or why it's paused), with how many photos
/// across the library are curated so far. When setup fails, a card says why with a way to try again.
private struct EyeStatus: View {
    @Environment(Curator.self) private var curator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .unavailable(let reason) = curator.modelState {
                unavailable(reason)
            }
            if isWorking {
                HStack {
                    if let pause = curator.libraryPass?.pauseReason {
                        Label(pause, systemImage: "pause.circle")
                    } else {
                        Label("Finding trips\u{2026}", systemImage: "sparkles").shimmer()
                    }
                    Spacer()
                    // Across the whole library, not just this batch.
                    if let pass = curator.libraryPass {
                        Text("\(pass.curated.formatted()) of \(pass.total.formatted()) curated")
                            .font(.text(.footnote))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.text(.footnote, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: isWorking)
    }

    private var isWorking: Bool {
        if case .downloading = curator.modelState { return true }
        return curator.libraryPass != nil
    }

    /// Eye couldn't download: why, in the system's or the SDK's words, and a way to try again.
    private func unavailable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn\u{2019}t finish setting up. Photos are sorted more simply for now.", systemImage: "wifi.slash")
                .font(.text(.footnote, weight: .semibold))
            Text(reason)
                .font(.text(.caption))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Try Again", systemImage: "arrow.clockwise") {
                Task { await curator.retryModel() }
            }
            .font(.text(.footnote, weight: .semibold))
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.surface, in: .rect(cornerRadius: 16))
    }
}

/// While trips are being found: the shape of the screen to come, in placeholder grey, gently pulsing.
private struct LoadingTrips: View {
    @State private var dim = false

    var body: some View {
        // In a still scroll view, so the cards run off the bottom rather than pushing the line off the top.
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Label("Finding trips\u{2026}", systemImage: "sparkles")
                .font(.text(.footnote, weight: .medium))
                .foregroundStyle(.secondary)
                .shimmer()
                .padding(.horizontal)

            // Laid out like the real column of trip cards.
            VStack(spacing: CardMetrics.gap) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: CardMetrics.cornerRadius)
                        .fill(Color.surface)
                        .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
                        // Height from the full width, so the screen's height doesn't shrink them.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, CardMetrics.gap)
            .opacity(dim ? 0.5 : 1)
        }
        .padding(.top, 8)
        }
        .scrollDisabled(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding trips in your photos")
    }
}
