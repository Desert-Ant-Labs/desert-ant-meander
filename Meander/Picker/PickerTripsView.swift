import CoreLocation
import SwiftUI

struct PickerTripsView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(Curator.self) private var curator
    @Environment(\.openURL) private var openURL
    @Environment(\.pickerNear) private var near
    /// How far each trip is from the album's places, worked out once per set of trips.
    @State private var distances: [String: CLLocationDistance] = [:]

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if library.access == .limited {
                    LimitedAccessBanner().padding(.horizontal)
                }
                EyeStatus().padding(.horizontal)

                let trips = ordered(library.trips.filter { !$0.isPossible })
                if !trips.isEmpty {
                    Text("Trips").font(.heading(.title2)).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(trips) { trip in
                                NavigationLink(value: Route.trip(trip.id)) {
                                    TripCard(trip: trip).frame(width: 260, height: 200)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollClipDisabled()
                }

                let possible = possibleTrips
                if !possible.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Curated Trips").font(.heading(.title2))
                        Text("Busy days including nature or landscapes.")
                            .font(.text(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, trips.isEmpty ? 0 : 8)

                    // Under a heading per year, newest year first.
                    let years = Dictionary(grouping: possible) { Calendar.current.component(.year, from: $0.start) }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(years.keys.sorted(by: >), id: \.self) { year in
                            Text(String(year))
                                .font(.heading(.title3))
                                .padding(.top, 6)
                            ForEach(years[year] ?? []) { trip in
                                // Curated trips have no places, so they open on their photos.
                                NavigationLink(value: Route.scope(trip.scope)) {
                                    PossibleTripRow(trip: trip)
                                }
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

/// A possible trip: its dates, what Eye found in it, and its best photo.
private struct PossibleTripRow: View {
    @Environment(Curator.self) private var curator
    let trip: Trip

    var body: some View {
        let signal = curator.travelSignal(trip.items)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(trip.title).font(.heading(.title3))
                Group {
                    if signal.isJudged {
                        Label("\(signal.nature) nature \(signal.nature == 1 ? "photo" : "photos") \u{00B7} \(trip.items.count) in all",
                              systemImage: "mountain.2")
                    } else {
                        Label("Looking through photos\u{2026} \u{00B7} \(trip.items.count) photos", systemImage: "sparkles")
                            .shimmer()
                    }
                }
                .font(.text(.caption))
                .foregroundStyle(.secondary)
            }
            Spacer()
            // Always a nature shot: the best one once Eye has found it; until then, a placeholder.
            Group {
                if let cover = curator.natureCover(trip.items) {
                    AssetImage(asset: cover.asset)
                } else {
                    Image(systemName: "mountain.2").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 84, height: 84)
            .background(.fill.tertiary)
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding(12)
        .padding(.leading, 4)
        .background(Color.surface, in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

private struct TripCard: View {
    @Environment(Curator.self) private var curator
    let trip: Trip

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let cover = curator.cover(trip.items) {
                AssetImage(asset: cover.asset)
            } else {
                Rectangle().fill(.quaternary)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title)
                    .font(.heading(.title2))
                    .redacted(reason: trip.isLocating ? .placeholder : [])
                Text(trip.month)
                    .dateTracking(.subheadline)
                    .font(.text(.subheadline))
                    .opacity(0.85)
            }
            .foregroundStyle(Color.paper)
            .padding()
        }
        .clipShape(.rect(cornerRadius: 24))
        .contentShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
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

/// What Eye is doing: downloading, or curating the library 1,000 photos at a time, with the total
/// across the whole library beneath.
private struct EyeStatus: View {
    @Environment(Curator.self) private var curator

    var body: some View {
        VStack(spacing: 12) {
            if case .unavailable(let reason) = curator.modelState {
                unavailable(reason)
            }
            if case .downloading(let fraction) = curator.modelState {
                row("Getting ready", detail: "\(Int(fraction * 100))%", value: fraction)
            } else if let pass = curator.libraryPass {
                row(pass.pauseReason ?? "Curating photos",
                    detail: "\(pass.batchDone.formatted()) of \(pass.batchTotal.formatted())",
                    value: Double(pass.batchDone) / Double(max(pass.batchTotal, 1)),
                    footnote: "\(pass.curated.formatted()) of \(pass.total.formatted()) photos and videos curated")
            }
        }
        .animation(.default, value: curator.libraryPass == nil)
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

    private func row(_ title: String, detail: String, value: Double, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.text(.footnote, weight: .semibold)).shimmer()
                Spacer()
                Text(detail).font(.text(.footnote)).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: value)
            if let footnote {
                Text(footnote).font(.text(.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding()
        .background(Color.surface, in: .rect(cornerRadius: 16))
    }
}

/// While trips are being found: the shape of the screen to come, in placeholder grey, gently pulsing.
private struct LoadingTrips: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Finding trips in your photos\u{2026}", systemImage: "sparkles")
                .font(.text(.footnote, weight: .medium))
                .foregroundStyle(.secondary)
                .shimmer()
                .padding(.horizontal)

            Text("Trips").font(.heading(.title2))
                .padding(.horizontal)
            // Laid out like the real row: it runs off the right edge without widening the screen.
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 24).fill(Color.surface).frame(width: 260, height: 200)
                    }
                }
                .padding(.horizontal)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .opacity(dim ? 0.5 : 1)

            Text("Curated Trips").font(.heading(.title2))
                .padding(.horizontal)
                .padding(.top, 8)
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule().fill(.fill.secondary).frame(width: 150, height: 14)
                            Capsule().fill(.fill.tertiary).frame(width: 100, height: 10)
                        }
                        Spacer()
                        RoundedRectangle(cornerRadius: 12).fill(.fill.tertiary).frame(width: 84, height: 84)
                    }
                    .padding(12)
                    .padding(.leading, 4)
                    .background(Color.surface, in: .rect(cornerRadius: 20))
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
