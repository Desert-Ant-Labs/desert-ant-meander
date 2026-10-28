import MapKit
import SwiftUI

/// A new album's name and, once chosen on the map, its place.
struct TripDraft: Hashable {
    var title: String
    var latitude: Double?
    var longitude: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Where a new album was, for media with no location of its own: search the map for the place,
/// and name the album (choosing a place offers its name).
struct NewTripView: View {
    @Environment(\.dismiss) private var dismiss
    var actionTitle = "Create Album"
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
                Text(actionTitle)
                    .font(.text(.headline, weight: .semibold))
                    .foregroundStyle(Color.canvas)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.coordinate == nil)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Looks the suggestion up, drops a pin, frames it on the map, and offers its name as the album's.
    private func choose(_ result: MKLocalSearchCompletion) async {
        let request = MKLocalSearch.Request(completion: result)
        guard let response = try? await MKLocalSearch(request: request).start(), let place = response.mapItems.first else { return }
        let region = response.boundingRegion
        let coordinate = place.location.coordinate

        draft.title = result.title
        draft.latitude = coordinate.latitude
        draft.longitude = coordinate.longitude

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
