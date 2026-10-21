import SwiftUI

/// An album, shown as a map of its route and then its highlights and journal entries in time order,
/// a screen at a time, with a line per screen that fills when its screen shows.
/// Landscape and square photos share a screen, one above the other.
/// Tap the right or left side to step; it also advances on its own.
struct TripStoryView: View {
    @Environment(TripStore.self) private var store
    @Environment(Curator.self) private var curator
    let tripID: UUID
    let onAddMedia: () -> Void

    @State private var index = 0
    /// One screen of the story.
    enum Slide: Equatable {
        case map
        case media([MediaItem])
        case note(JournalNote)

        var id: String {
            switch self {
            case .map: "map"
            case .media(let items): items.map(\.id).joined(separator: "+")
            case .note(let note): note.id.uuidString
            }
        }
    }

    /// What was showing when the menu was opened. The story holds on it until the menu closes.
    @State private var menuSlide: Slide?
    /// The journal entry being written or edited.
    @State private var editing: JournalNote?
    @State private var editingIsNew = false
    /// Each photo's measured shape. Nil until measured; the story waits for it before it starts advancing,
    /// so screens don't regroup while you watch.
    @State private var shapes: StoryFrame.Shapes?
    private static let highlightCount = 50
    private static let videoPlaces = 10
    private static let secondsPerPhoto = 4.0
    private static let secondsPerSplit = 5.0
    private static let secondsOnMap = 7.0

    private var isPaused: Bool { menuSlide != nil || editing != nil }

    var body: some View {
        if let trip = store.trip(tripID) {
            let highlights = highlights(of: trip)
            let stops = TripRoute.stops(for: store.items(for: trip), cover: curator.cover)
            let slides = makeSlides(trip, highlights: highlights, hasMap: !stops.isEmpty)
            let slideCount = slides.count
            let current = slides[safe: index]
            let currentVideo: MediaItem? = if case .media(let items) = current, items.count == 1, items[0].isVideo { items[0] } else { nil }
            let isNote: Bool = if case .note = current { true } else { false }
            ZStack(alignment: .bottomLeading) {
                Color.black.ignoresSafeArea()

                switch current {
                case .map:
                    TripRouteMap(stops: stops)
                        .ignoresSafeArea()
                        .transition(.opacity)
                case .media(let frame):
                    Group {
                        if frame.count == 2 {
                            SplitFrame(top: frame[0], bottom: frame[1], shapes: shapes ?? [:])
                        } else if let video = currentVideo {
                            StoryVideo(asset: video.asset, isPaused: isPaused) { step(1, count: slideCount) }
                        } else {
                            AssetImage(asset: frame[0].asset, full: true)
                        }
                    }
                    .ignoresSafeArea()
                    .id(current?.id)
                    .transition(.opacity)
                case .note(let note):
                    JournalNoteView(note: note)
                        .ignoresSafeArea()
                        .id(current?.id)
                        .transition(.opacity)
                case nil:
                    ContentUnavailableView {
                        Label("Nothing in this album yet", systemImage: "photo.on.rectangle")
                    } actions: {
                        Button("Add Media", action: onAddMedia)
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.colorScheme, .dark)
                }

                if !isNote {
                    LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                HStack(spacing: 0) {
                    Color.clear.contentShape(.rect).onTapGesture { step(-1, count: slideCount) }
                    Color.clear.contentShape(.rect).onTapGesture { step(1, count: slideCount) }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.month)
                        .dateTracking(.caption)
                        .font(.text(.caption))
                        .opacity(0.6)
                    Text(trip.title).font(.albumTitle(.title))
                    Text(trip.subtitle).font(.text(.subheadline)).opacity(0.9)
                }
                .foregroundStyle(Color.paper)
                .padding()
                .padding(.bottom, 8)
                .opacity(isNote ? 0 : 1)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                // Tighter gaps once there are many lines, so each one keeps some width.
                HStack(spacing: slideCount > 20 ? 2 : 4) {
                    ForEach(0..<slideCount, id: \.self) { i in
                        Capsule()
                            .fill((isNote ? Color.meanderDark : Color.paper).opacity(i <= index ? 1 : 0.25))
                            .frame(height: 3)
                    }
                }
                .animation(nil, value: index)
                .padding(.horizontal)
                .padding(.top, 4)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add", systemImage: "plus") {
                        Button("Photos and Videos", systemImage: "photo.on.rectangle", action: onAddMedia)
                        Button("Journal Entry", systemImage: "square.and.pencil") {
                            editingIsNew = true
                            editing = JournalNote(text: "", date: noteDate(after: current, in: trip))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("More", systemImage: "ellipsis") { menuSlide = current }
                        .disabled(current == nil || current == .map)
                        .confirmationDialog("", isPresented: Binding(get: { menuSlide != nil }, set: { if !$0 { menuSlide = nil } }), presenting: menuSlide) { slide in
                            switch slide {
                            case .media(let frame):
                                ForEach(Array(frame.enumerated()), id: \.element.id) { position, item in
                                    Button(removeLabel(item, position: position, of: frame.count), systemImage: "minus.circle", role: .destructive) {
                                        withAnimation {
                                            store.remove(item, from: trip)
                                            index = min(index, max(slideCount - 1, 0))
                                        }
                                    }
                                }
                            case .note(let note):
                                Button("Edit Journal Entry", systemImage: "pencil") {
                                    editingIsNew = false
                                    editing = note
                                }
                                Button("Delete Journal Entry", systemImage: "trash", role: .destructive) {
                                    withAnimation {
                                        store.delete(note, from: trip)
                                        index = min(index, max(slideCount - 2, 0))
                                    }
                                }
                            case .map:
                                EmptyView()
                            }
                        }
                }
            }
            .sheet(item: $editing) { note in
                JournalNoteEditor(note: note, isNew: editingIsNew) { saved in
                    store.save(saved, in: trip)
                    // Show the entry that was just written or edited.
                    if let position = makeSlides(store.trip(tripID) ?? trip, highlights: highlights, hasMap: !stops.isEmpty)
                        .firstIndex(where: { $0.id == saved.id.uuidString }) {
                        index = position
                    }
                }
            }
            .toolbarColorScheme(isNote ? .light : .dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task(id: highlights.map(\.id)) {
                shapes = await StoryFrame.measure(highlights)
            }
            .task(id: "\(index)-\(slideCount)-\(isPaused)-\(shapes == nil)") {
                guard slideCount > 1, !isPaused, shapes != nil else { return }
                // The map gets longer: there is more to read, and its routes may still be loading.
                // A video moves on when it finishes playing; the wait here is only a backstop in case it never loads.
                let wait: Double = switch current {
                case .map: Self.secondsOnMap
                case .note(let note): Self.readingTime(note)
                case .media(let frame):
                    if let currentVideo { currentVideo.duration + 15 } else { frame.count == 2 ? Self.secondsPerSplit : Self.secondsPerPhoto }
                case nil: Self.secondsPerPhoto
                }
                try? await Task.sleep(for: .seconds(wait))
                if !Task.isCancelled { step(1, count: slideCount) }
            }
            .task { await curate(trip) }
        } else {
            ContentUnavailableView("Album not found", systemImage: "airplane")
        }
    }

    /// Eye's top picks from the trip, back in the order they were taken.
    /// Up to ten places go to videos first, so adding a video always shows; photos fill the rest.
    private func highlights(of trip: SavedTrip) -> [MediaItem] {
        let items = store.items(for: trip)
        guard items.count > Self.highlightCount else { return items }
        let ranked = items.sorted { curator.score($0) > curator.score($1) }
        let videos = ranked.filter(\.isVideo).prefix(Self.videoPlaces)
        let photos = ranked.filter { !$0.isVideo }.prefix(Self.highlightCount - videos.count)
        return (videos + photos).sorted { $0.date < $1.date }
    }

    /// The map, then photo screens and journal entries in time order. An entry comes after
    /// every screen whose first photo was taken at or before the entry's date.
    private func makeSlides(_ trip: SavedTrip, highlights: [MediaItem], hasMap: Bool) -> [Slide] {
        let frames = StoryFrame.frames(for: highlights, shapes: shapes ?? [:])
        var slides: [Slide] = hasMap ? [.map] : []
        var notes = trip.notes.sorted { $0.date < $1.date }[...]
        for frame in frames {
            while let note = notes.first, note.date < frame[0].date {
                slides.append(.note(note))
                notes.removeFirst()
            }
            slides.append(.media(frame))
        }
        slides += notes.map(Slide.note)
        return slides
    }

    /// A new entry is dated just after what's on screen, so it appears right after it;
    /// from the map, just before the first photo, so it opens the album.
    private func noteDate(after slide: Slide?, in trip: SavedTrip) -> Date {
        switch slide {
        case .media(let items): items.map(\.date).max()!.addingTimeInterval(1)
        case .note(let note): note.date.addingTimeInterval(1)
        case .map, nil: trip.start.addingTimeInterval(-1)
        }
    }

    /// Long enough to read: 4 seconds plus a quarter second a word, up to 15.
    private static func readingTime(_ note: JournalNote) -> Double {
        min(4 + Double(note.text.split(separator: " ").count) * 0.25, 15)
    }

    /// "Remove Photo", or on a split screen "Remove Top Photo" and "Remove Bottom Photo".
    private func removeLabel(_ item: MediaItem, position: Int, of count: Int) -> String {
        let kind = item.isVideo ? "Video" : "Photo"
        return count == 1 ? "Remove \(kind)" : "Remove \(position == 0 ? "Top" : "Bottom") \(kind)"
    }

    private func step(_ by: Int, count: Int) {
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) { index = (index + by + count) % count }
    }

    private func curate(_ trip: SavedTrip) async {
        let items = store.items(for: trip)
        await curator.curate(Trip(id: trip.id.uuidString, title: trip.title, items: items))
    }
}
