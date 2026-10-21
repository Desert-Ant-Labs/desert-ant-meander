import SwiftUI

enum HomeRoute: Hashable {
    case trip(UUID)
    case book(UUID)
}

/// Where picked media goes: a new trip, or one that already exists.
enum PickerTarget: Identifiable, Hashable {
    /// Naming a new trip and finding it on the map.
    case newTrip
    /// Picking media for a new trip that has been named.
    case draft(TripDraft)
    case trip(UUID)

    var id: String {
        switch self {
        case .newTrip: "new"
        case .draft(let draft): "draft-\(draft.title)"
        case .trip(let id): id.uuidString
        }
    }
}

struct HomeView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case trips = "Albums", map = "Map", books = "Books"
        var id: String { rawValue }
    }

    @Environment(TripStore.self) private var store
    @State private var tab: Tab = .trips
    @State private var path: [HomeRoute] = []
    @State private var picker: PickerTarget?
    @State private var titleCollapsed = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private var header: some View {
        VStack(spacing: 12) {
            Wordmark()
                .frame(width: 214)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            tabs
        }
    }

    private var tabs: some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.trips.isEmpty {
                    VStack(spacing: 0) {
                        header
                    ContentUnavailableView {
                            Label("No albums yet", systemImage: "airplane")
                        } description: {
                            Text("Make an album from your photos. Meander finds your trips and picks the best shots.")
                        } actions: {
                            Button {
                                picker = .newTrip
                            } label: {
                                Label("Add Album", systemImage: "plus")
                                    .font(.text(.headline, weight: .semibold))
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.extraLarge)
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    // One page for all three tabs, so the segmented control is never rebuilt and its
                    // glass selection can slide between them. The tabs scroll away with the content and
                    // the large title collapses into the bar. The map fills the page and holds it still.
                    ScrollView {
                        VStack(spacing: 0) {
                            header
                            switch tab {
                            case .trips: TripCardsView()
                            case .books: BooksView()
                            case .map:
                                TripsMapView { path.append(.trip($0)) }
                                    .containerRelativeFrame(.vertical) { height, _ in max(height - 26, 240) }
                            }
                        }
                    }
                    .scrollDisabled(tab == .map)
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top > 60
                    } action: { _, collapsed in
                        titleCollapsed = collapsed
                    }
                }
            }
            .canvas()
            .onChange(of: tab) { scrollPosition.scrollTo(edge: .top) }
            .navigationTitle("Meander")
            // The large wordmark is the first thing on the page, not a system large title,
            // so it can fill the width. The small one appears in the bar once it scrolls away.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The small wordmark, shown only once the large one has scrolled under the bar.
                ToolbarItem(placement: .title) {
                    Wordmark()
                        .frame(height: 18)
                        .opacity(titleCollapsed ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: titleCollapsed)
                        .accessibilityHidden(!titleCollapsed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Album", systemImage: "plus") { picker = .newTrip }
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .trip(let id): TripStoryView(tripID: id) { picker = .trip(id) }
                case .book(let id): BookView(tripID: id)
                }
            }
        }
        .sheet(item: $picker) { target in
            if target == .newTrip {
                // Step one. Finishing it swaps this sheet for the picker.
                NewTripView { draft in picker = .draft(draft) }
            } else {
                PickerSheet(target: target) { newTripID in
                    if let newTripID, case .draft = target { path = [.trip(newTripID)] }
                }
            }
        }
    }
}

private struct PickerSheet: View {
    @Environment(TripStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    let target: PickerTarget
    let onDone: (UUID?) -> Void

    var body: some View {
        var tripID: UUID?
        var draft: TripDraft?
        if case .trip(let id) = target { tripID = id }
        if case .draft(let named) = target { draft = named }
        let existing = tripID.flatMap(store.trip)

        return MediaPicker(alreadyAdded: Set(existing?.assetIDs ?? []), focus: draft) { items in
            let described = library.describe(items)
            // A new trip keeps the name it was given. Its places come from the photos;
            // if the photos have no location, the place chosen on the map stands in.
            var pins = described.pins
            if pins.isEmpty, let draft, let coordinate = draft.coordinate {
                pins = [SavedTrip.Pin(name: draft.title, latitude: coordinate.latitude, longitude: coordinate.longitude)]
            }
            onDone(store.add(items, title: draft?.title ?? described.title, pins: pins, to: tripID))
        }
    }
}

struct TripCardsView: View {
    @Environment(TripStore.self) private var store
    @State private var choosingCover: SavedTrip?
    @State private var renaming: SavedTrip?
    @State private var newTitle = ""
    @State private var describing: SavedTrip?
    @State private var newDescription = ""

    var body: some View {
        VStack {
            LazyVStack(spacing: 28) {
                ForEach(store.trips) { trip in
                    NavigationLink(value: HomeRoute.trip(trip.id)) {
                        SavedTripCard(trip: trip)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.contextMenuPreview, .rect(cornerRadius: 44))
                    .contextMenu {
                        Button("Edit Title", systemImage: "pencil") {
                            newTitle = trip.title
                            renaming = trip
                        }
                        Button("Edit Description", systemImage: "text.alignleft") {
                            newDescription = trip.subtitle
                            describing = trip
                        }
                        Button("Change Cover", systemImage: "photo") { choosingCover = trip }
                        Button(role: .destructive) {
                            withAnimation { store.delete(trip) }
                        } label: {
                            Label("Delete Album", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .tint(.red)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .canvas()
        .sheet(item: $choosingCover) { trip in
            CoverPicker(tripID: trip.id)
        }
        .alert("Edit Title", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { trip in
            TextField("Album title", text: $newTitle)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.rename(trip, to: newTitle) }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .alert("Edit Description", isPresented: Binding(get: { describing != nil }, set: { if !$0 { describing = nil } }), presenting: describing) { trip in
            TextField(trip.placesLine.isEmpty ? "Description" : trip.placesLine, text: $newDescription)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.setDescription(newDescription, for: trip) }
        } message: { _ in
            Text("Leave it empty to list the places again.")
        }
    }
}

/// Pick a trip's cover from the media already added to it.
private struct CoverPicker: View {
    @Environment(TripStore.self) private var store
    @Environment(Curator.self) private var curator
    @Environment(\.dismiss) private var dismiss
    let tripID: UUID

    var body: some View {
        NavigationStack {
            ScrollView {
                if let trip = store.trip(tripID) {
                    let current = store.cover(for: trip, curator: curator)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(store.items(for: trip)) { item in
                            Button {
                                store.setCover(item, for: trip)
                                dismiss()
                            } label: {
                                Tile(item: item)
                                    .overlay(alignment: .topTrailing) {
                                        if item == current {
                                            Image(systemName: "checkmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(Color.canvas, Color.ink)
                                                .font(.title3)
                                                .shadow(color: .black.opacity(0.3), radius: 2)
                                                .padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(item == current ? .isSelected : [])
                        }
                    }
                }
            }
            .canvas()
            .barTitle("Change Cover")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

private struct SavedTripCard: View {
    @Environment(TripStore.self) private var store
    @Environment(Curator.self) private var curator
    let trip: SavedTrip

    var body: some View {
        let cover = store.cover(for: trip, curator: curator)
        ZStack(alignment: .bottomLeading) {
            if let cover {
                AssetImage(asset: cover.asset)
                // Progressive blur: a blurred copy of the photo that fades in toward the bottom.
                AssetImage(asset: cover.asset)
                    .blur(radius: 24, opaque: true)
                    .mask(LinearGradient(
                        stops: [.init(color: .clear, location: 0.52), .init(color: .black, location: 0.72)],
                        startPoint: .top, endPoint: .bottom
                    ))
            } else {
                Rectangle().fill(.quaternary)
            }
            LinearGradient(
                stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.4), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.month)
                    .dateTracking(.caption)
                    .font(.text(.caption))
                    .opacity(0.6)
                Text(trip.title)
                    .font(.albumTitle(.title))
                Text(trip.subtitle)
                    .font(.text(.subheadline))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .aspectRatio(6 / 7, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 44))
        .contentShape(.rect(cornerRadius: 44))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 12)
        .accessibilityElement(children: .combine)
    }
}
