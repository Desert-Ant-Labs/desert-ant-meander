import SwiftUI

/// A trip in the picker. With more than one place, its places: each city as a card with its spots
/// beneath, and a grid button for everything. With one place or none, straight to the photos.
struct TripView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(Curator.self) private var curator
    let tripID: String

    var body: some View {
        if let trip = library.trip(tripID) {
            Group {
                if trip.isLocating || Self.hasSeveralPlaces(trip) {
                    places(trip)
                } else {
                    MediaGridView(scope: trip.scope)
                }
            }
            .task { await curator.curate(trip) }
        } else {
            ContentUnavailableView("Trip not found", systemImage: "airplane")
        }
    }

    /// More than one city, or one city with two spots or more.
    static func hasSeveralPlaces(_ trip: Trip) -> Bool {
        trip.cities.count > 1 || (trip.cities.first?.places.count ?? 0) > 1
    }

    private func places(_ trip: Trip) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                locations(trip)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .canvas()
        .barTitle(trip.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.scope(trip.scope)) {
                    Label("All Photos", systemImage: "square.grid.2x2")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { CurationStatus(tripID: trip.id) }
    }

    @ViewBuilder
    private func locations(_ trip: Trip) -> some View {
        if trip.isLocating {
            ProgressView("Finding places")
                .padding(.top, 40)
        }
        ForEach(trip.cities) { city in
            NavigationLink(value: Route.scope(city.scope(tripID: trip.id))) {
                CityCard(city: city)
            }
            .buttonStyle(.plain)
            ForEach(city.places) { place in
                NavigationLink(value: Route.scope(place.scope(tripID: trip.id))) {
                    PlaceRow(name: place.name, count: curator.kept(place.items).count)
                }
                .buttonStyle(.plain)
            }
        }
        if !trip.isLocating, trip.unplacedCount > 0 {
            let items = trip.items.filter { $0.location == nil }
            NavigationLink(value: Route.scope(MediaScope(id: "\(trip.id)/unplaced", tripID: trip.id, title: "No Location", items: items))) {
                PlaceRow(name: "No location", count: curator.kept(items).count, symbol: "location.slash")
            }
            .buttonStyle(.plain)
        }
    }
}

private struct CityCard: View {
    @Environment(Curator.self) private var curator
    let city: City

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let cover = curator.cover(city.items) {
                AssetImage(asset: cover.asset)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(city.name).font(.heading(.title2))
                Text(countLabel(curator.kept(city.items).count)).font(.text(.subheadline)).opacity(0.85)
            }
            .foregroundStyle(Color.paper)
            .padding()
        }
        .frame(height: 130)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .padding(.top, 8)
    }
}

private struct PlaceRow: View {
    let name: String
    let count: Int
    var symbol = "mappin.and.ellipse"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(name)
                .font(.text(.subheadline, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.text(.subheadline))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.text(.footnote, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(Color.surface, in: .rect(cornerRadius: 14))
    }
}

func countLabel(_ count: Int) -> String {
    count == 1 ? "1 pick" : "\(count) picks"
}

/// Shows while the model works through a trip.
struct CurationStatus: View {
    @Environment(Curator.self) private var curator
    let tripID: String

    var body: some View {
        if let progress = curator.progress[tripID] {
            VStack(alignment: .leading, spacing: 6) {
                Text("Curating \(progress.done) of \(progress.total)")
                    .font(.text(.footnote, weight: .semibold))
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            }
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
