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
            VStack(alignment: .leading, spacing: 16) {
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
                    Text("Trips").font(.heading(.title2)).padding(.horizontal)
                    LazyVStack(spacing: 12) {
                        ForEach(trips) { trip in
                            NavigationLink(value: Route.trip(trip.id)) { TripCard(trip: trip) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)

                case .date:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Curated Trips").font(.heading(.title2))
                        Text("Busy days including nature or landscapes.")
                            .font(.text(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    // Under a heading per year, newest year first.
                    let years = Dictionary(grouping: possible) { Calendar.current.component(.year, from: $0.start) }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(years.keys.sorted(by: >), id: \.self) { year in
                            Text(String(year))
                                .font(.heading(.title3))
                                .padding(.top, 6)
                            ForEach(years[year] ?? []) { trip in
                                // Curated trips have no places, so they open on their photos.
                                NavigationLink(value: Route.scope(trip.scope)) { TripCard(trip: trip) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
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

/// A trip as a photo card, the same for both kinds. A trip found by place shows its name and month
/// over its best shot. A curated trip shows its dates and what was found in it over its best nature shot.
private struct TripCard: View {
    @Environment(Curator.self) private var curator
    let trip: Trip

    var body: some View {
        let cover = trip.isPossible ? curator.natureCover(trip.items) : curator.cover(trip.items)
        ZStack(alignment: .bottomLeading) {
            Group {
                if let cover {
                    AssetImage(asset: cover.asset)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(alignment: .top) {
                            Image(systemName: "mountain.2")
                                .font(.title)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 56)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title)
                    .font(.heading(.title2))
                    .redacted(reason: trip.isLocating ? .placeholder : [])
                subtitle
                    .font(.text(.subheadline))
                    .opacity(0.85)
            }
            .foregroundStyle(Color.paper)
            .padding()
        }
        .frame(height: 200)
        .clipShape(.rect(cornerRadius: 24))
        .contentShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        if trip.isPossible {
            let signal = curator.travelSignal(trip.items)
            if signal.isJudged {
                Text("\(signal.nature) nature \(signal.nature == 1 ? "photo" : "photos") \u{00B7} \(trip.items.count) in all")
            } else {
                Text("Curating \(trip.items.count) photos\u{2026}").shimmer()
            }
        } else {
            Text(trip.month).dateTracking(.subheadline)
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
                            .font(.text(.subheadline))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.text(.subheadline, weight: .semibold))
                // The same container as the discarded photos row.
                .padding(.horizontal)
                .padding(.vertical, 14)
                .background(Color.surface, in: .rect(cornerRadius: 14))
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
        VStack(alignment: .leading, spacing: 16) {
            Label("Finding trips\u{2026}", systemImage: "sparkles")
                .font(.text(.footnote, weight: .medium))
                .foregroundStyle(.secondary)
                .shimmer()
                .padding(.horizontal)

            Text("Trips").font(.heading(.title2))
                .padding(.horizontal)
            // Laid out like the real column of trip cards.
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 24).fill(Color.surface).frame(height: 200)
                }
            }
            .padding(.horizontal)
            .opacity(dim ? 0.5 : 1)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding trips in your photos")
    }
}
