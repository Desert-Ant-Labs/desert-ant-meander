import MapKit
import SwiftUI

/// A trip that has a name, and usually a place, but no media yet.
struct TripDraft: Hashable {
    var title: String
    var latitude: Double?
    var longitude: Double?
    /// How far from the place still counts as "there", in metres. A country is wider than a city.
    var radius: Double = 150_000

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Step one of adding a trip: search the map for where you went and name the trip.
/// Step two is the media picker, which then knows the place.
struct NewTripView: View {
    @Environment(\.dismiss) private var dismiss
    let onNext: (TripDraft) -> Void

    @State private var search = PlaceSearch()
    @State private var query = ""
    @State private var draft = TripDraft(title: "")
    @State private var position: MapCameraPosition = .automatic
    @State private var isSearching = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                if let coordinate = draft.coordinate {
                    Marker(draft.title, coordinate: coordinate)
                        .tint(Color.ink)
                }
            }
            .mapStyle(.hybrid(elevation: .flat))
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if isSearching, !query.isEmpty {
                    suggestions
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isSearching { nameCard }
            }
            .searchable(text: $query, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Where did you go?")
            .onChange(of: query) { _, text in search.update(text) }
            .barTitle("New Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private var suggestions: some View {
        List(search.results, id: \.self) { result in
            Button {
                Task { await choose(result) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.text(.body, weight: .medium))
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle).font(.text(.footnote)).foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.canvas)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
    }

    private var nameCard: some View {
        VStack(spacing: 12) {
            TextField("Album name", text: $draft.title)
                .font(.albumTitle(.title3))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Color.surface, in: .capsule)

            Button {
                var named = draft
                named.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                onNext(named)
            } label: {
                Text("Choose Photos")
                    .font(.text(.headline, weight: .semibold))
                    .foregroundStyle(Color.canvas)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Looks the suggestion up, drops a pin, frames it on the map, and offers its name as the trip's.
    private func choose(_ result: MKLocalSearchCompletion) async {
        let request = MKLocalSearch.Request(completion: result)
        guard let response = try? await MKLocalSearch(request: request).start(), let place = response.mapItems.first else { return }
        let region = response.boundingRegion
        let coordinate = place.location.coordinate

        draft.title = result.title
        draft.latitude = coordinate.latitude
        draft.longitude = coordinate.longitude
        let halfSpan = max(region.span.latitudeDelta, region.span.longitudeDelta) * 111_000 / 2
        draft.radius = min(max(halfSpan * 1.2, 60_000), 1_500_000)

        query = ""
        isSearching = false
        withAnimation { position = .region(region) }
    }
}

/// Place suggestions as you type, from the system's map search.
@MainActor @Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ text: String) {
        if text.isEmpty { results = [] } else { completer.queryFragment = text }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { results = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }
}
