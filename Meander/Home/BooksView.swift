import SwiftUI

/// Each trip as a photo book.
struct BooksView: View {
    @Environment(TripStore.self) private var store

    var body: some View {
        VStack {
            LazyVStack(spacing: 16) {
                ForEach(store.trips) { trip in
                    NavigationLink(value: HomeRoute.book(trip.id)) {
                        BookCard(trip: trip)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .canvas()
    }
}

private struct BookCard: View {
    @Environment(TripStore.self) private var store
    @Environment(Curator.self) private var curator
    let trip: SavedTrip

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.month).dateTracking(.caption).font(.text(.caption)).foregroundStyle(.tertiary)
                Text(trip.title).font(.albumTitle(.title2)).foregroundStyle(Color.ink)
                Text(trip.subtitle).font(.text(.footnote)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)

            BookCover(cover: store.cover(for: trip, curator: curator))
                .frame(width: 130, height: 172)
        }
        .padding(20)
        .background(Color.surface, in: .rect(cornerRadius: 24))
        .contentShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// A cover photo with page edges behind it.
struct BookCover: View {
    let cover: MediaItem?

    var body: some View {
        ZStack {
            ForEach([2, 1], id: \.self) { layer in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.paper)
                    .stroke(Color(.separator), lineWidth: 0.5)
                    .offset(x: CGFloat(layer) * 4, y: CGFloat(layer) * 3)
            }
            Group {
                if let cover {
                    AssetImage(asset: cover.asset)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
        .padding(.trailing, 8)
        .padding(.bottom, 6)
    }
}

/// A preview of the book: a cover, then the trip's picks a page at a time.
/// A preview of the book: the cover, then two-page spreads in the book's style.
struct BookView: View {
    @Environment(TripStore.self) private var store
    @Environment(Curator.self) private var curator
    let tripID: UUID

    @State private var page = 0
    @State private var showPrintNotice = false
    @State private var shapes: StoryFrame.Shapes = [:]
    @State private var isExporting = false
    @State private var exported: URL?
    @State private var exportFailed = false

    var body: some View {
        if let trip = store.trip(tripID) {
            let items = store.items(for: trip)
            let photos = items.filter { !$0.isVideo }
            let stops = TripRoute.stops(for: items, cover: curator.cover)
            let cover = store.cover(for: trip, curator: curator)
            let spreads = BookLayout.spreads(trip.bookStyle, cover: cover, entries: entries(trip, photos: photos), hasMap: !stops.isEmpty)
            let style = Binding(get: { trip.bookStyle }, set: { store.setBookStyle($0, for: trip) })

            VStack(spacing: 16) {
                Picker("Style", selection: style) {
                    ForEach(BookStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .padding(.horizontal)

                TabView(selection: $page) {
                    ForEach(Array(spreads.enumerated()), id: \.offset) { index, spread in
                        BookSpreadView(spread: spread, style: trip.bookStyle, trip: trip, stops: stops, firstPage: index * 2 - 1)
                            .padding(.horizontal, 16)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .id(trip.bookStyle)

                Text(page == 0 ? "Cover \u{00B7} swipe to turn \(spreads.count - 1) spreads" : "Spread \(page) of \(spreads.count - 1)")
                    .font(.text(.footnote))
                    .foregroundStyle(.secondary)

                Button {
                    showPrintNotice = true
                } label: {
                    Text("Order Printed Book")
                        .font(.text(.headline, weight: .semibold))
                        .foregroundStyle(Color.canvas)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .canvas()
            .barTitle(trip.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Download PDF", systemImage: "arrow.down.document") {
                            isExporting = true
                            Task {
                                do {
                                    exported = try await BookPDF.make(
                                        trip: trip, cover: cover, photos: photos, spreads: spreads, stops: stops
                                    )
                                } catch {
                                    exportFailed = true
                                }
                                isExporting = false
                            }
                        }
                    }
                }
            }
            .sheet(item: Binding(get: { exported.map(ExportedFile.init) }, set: { if $0 == nil { exported = nil } })) { file in
                ShareSheet(url: file.url).presentationDetents([.medium, .large])
            }
            .alert("Couldn\u{2019}t make the PDF", isPresented: $exportFailed) {
                Button("OK") {}
            }
            .onChange(of: trip.bookStyle) { page = 0 }
            .task(id: photos.map(\.id)) { shapes = await StoryFrame.measure(photos) }
            .alert("Printing isn\u{2019}t available yet", isPresented: $showPrintNotice) {
                Button("OK") {}
            } message: {
                Text("This is a preview of how your book will look.")
            }
        } else {
            ContentUnavailableView("Book not found", systemImage: "book.closed")
        }
    }

    /// Photos and journal entries in time order. Videos are left out of print.
    private func entries(_ trip: SavedTrip, photos: [MediaItem]) -> [BookLayout.Entry] {
        let photoEntries = photos.map { item in
            (item.date, BookLayout.Entry.photo(BookPhoto(
                item: item,
                aspect: StoryFrame.aspect(item, shapes),
                place: BookLayout.place(of: item, pins: trip.pins)
            )))
        }
        let noteEntries = trip.notes.map { ($0.date, BookLayout.Entry.note($0)) }
        return (photoEntries + noteEntries).sorted { $0.0 < $1.0 }.map(\.1)
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
