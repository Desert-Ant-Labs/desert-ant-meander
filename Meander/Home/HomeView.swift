import SwiftUI

enum HomeRoute: Hashable {
    case trip(UUID)
    case book(UUID)
}

/// Where picked media goes: a new album, or one that already exists.
enum PickerTarget: Identifiable, Hashable {
    /// A new album: pick its media, then it's named and placed from them.
    case newTrip
    /// Adding to an album that exists, at a place in it.
    case trip(UUID, MediaPosition)

    var id: String {
        switch self {
        case .newTrip: "new"
        case .trip(let id, _): id.uuidString
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
    /// A new album to open once the sheet that made it has closed. Opening it while the sheet is
    /// still closing leaves the album without its toolbar.
    @State private var madeTrip: UUID?
    @State private var titleCollapsed = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Ties each album card to its album, so the card grows into the album when opened.
    @Namespace private var albumZoom

    private var header: some View {
        VStack(spacing: 0) {
            Wordmark()
                .frame(maxWidth: .infinity)
                // All capitals, so the space the font keeps for descenders below the line is trimmed.
                .padding(.bottom, -12)
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
                            case .trips: TripCardsView(zoom: albumZoom)
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
                    Wordmark(size: 20)
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
                case .trip(let id):
                    TripStoryView(tripID: id) { position in picker = .trip(id, position) }
                        .navigationTransition(.zoom(sourceID: id, in: albumZoom))
                case .book(let id): BookView(tripID: id)
                }
            }
        }
        .sheet(item: $picker, onDismiss: {
            if let madeTrip { path = [.trip(madeTrip)] }
            madeTrip = nil
        }) { target in
            PickerSheet(target: target) { newTripID in
                if target == .newTrip { madeTrip = newTripID }
            }
        }
    }
}

/// Adding media, as one sheet. For a new album: pick the media first. If any of it has a location,
/// the album is made straight away, named and pinned from where the photos were taken. If none of it
/// does, the next step asks where it was, then makes the album.
private struct PickerSheet: View {
    @Environment(TripStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let target: PickerTarget
    let onDone: (UUID?) -> Void

    private enum Step: Equatable {
        case picking
        /// Naming the places the picked media was taken.
        case placing
        /// The picked media has no location: where was it?
        case locating([MediaItem])
    }
    @State private var step = Step.picking

    var body: some View {
        switch step {
        case .picking:
            picker
        case .placing:
            ProgressView("Making your album\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .canvas()
        case .locating(let items):
            NewTripView(actionTitle: "Create Album") { draft in
                let pin = draft.coordinate.map { SavedTrip.Pin(name: draft.title, latitude: $0.latitude, longitude: $0.longitude) }
                finish(store.add(items, title: draft.title, pins: pin.map { [$0] } ?? [], to: nil))
            }
        }
    }

    private var picker: some View {
        var tripID: UUID?
        var position = MediaPosition.end
        if case .trip(let id, let at) = target { tripID = id; position = at }
        let existing = tripID.flatMap(store.trip)

        return MediaPicker(alreadyAdded: Set(existing?.assetIDs ?? []),
                           closesOnAdd: tripID != nil,
                           near: existing?.pins.map(\.coordinate) ?? []) { items in
            if let tripID {
                let described = library.describe(items)
                onDone(store.add(items, title: described.title, pins: described.pins, to: tripID, at: position))
                return
            }
            step = .placing
            Task {
                let described = await library.describePlaces(items)
                if described.pins.isEmpty {
                    step = .locating(items)
                } else {
                    finish(store.add(items, title: described.title, pins: described.pins, to: nil))
                }
            }
        }
    }

    private func finish(_ tripID: UUID?) {
        onDone(tripID)
        dismiss()
    }
}

struct TripCardsView: View {
    @Environment(TripStore.self) private var store
    let zoom: Namespace.ID
    @State private var choosingCover: SavedTrip?
    @State private var renaming: SavedTrip?
    @State private var newTitle = ""
    @State private var describing: SavedTrip?
    @State private var newDescription = ""

    var body: some View {
        VStack {
            LazyVStack(spacing: CardMetrics.gap) {
                ForEach(store.trips) { trip in
                    NavigationLink(value: HomeRoute.trip(trip.id)) {
                        SavedTripCard(trip: trip)
                            .matchedTransitionSource(id: trip.id, in: zoom) { source in
                                source.clipShape(.rect(cornerRadius: CardMetrics.cornerRadius))
                            }
                    }
                    .buttonStyle(.plain)
                    .contentShape(.contextMenuPreview, .rect(cornerRadius: CardMetrics.cornerRadius))
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
            .padding(.horizontal, CardMetrics.gap)
            .padding(.top, 4)
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
        PhotoCard(cover: store.cover(for: trip, curator: curator)?.asset, title: trip.title) {
            Text(cardDetail([trip.month, trip.subtitle.replacingOccurrences(of: "\u{2022}", with: "\u{00B7}")]))
        }
    }
}
