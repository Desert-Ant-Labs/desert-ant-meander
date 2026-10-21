import SwiftUI

struct MediaGridView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", photos = "Photos", videos = "Videos"
        var id: String { rawValue }
    }

    enum Filter: Hashable {
        case all, best, tag(EyeTag)
    }

    @Environment(Curator.self) private var curator
    @Environment(PickerSelection.self) private var selection
    @Environment(\.alreadyAdded) private var alreadyAdded
    let scope: MediaScope

    @State private var kind: Kind = .all
    @State private var filter: Filter = .all
    @State private var rankByEye = false
    @State private var viewing: ViewerSelection?
    @Namespace private var zoom

    private var ofKind: [MediaItem] {
        let kept = curator.kept(scope.items)
        switch kind {
        case .all: return kept
        case .photos: return kept.filter { !$0.isVideo }
        case .videos: return kept.filter(\.isVideo)
        }
    }

    private var shown: [MediaItem] {
        let items: [MediaItem]
        switch filter {
        case .all: items = ofKind
        case .best: return curator.bestOf(ofKind)
        case .tag(let tag): items = ofKind.filter { curator.tags($0).contains(tag) }
        }
        return rankByEye ? items.sorted { curator.score($0) > curator.score($1) } : items
    }

    private var availableTags: [EyeTag] {
        let present = Set(ofKind.flatMap { curator.tags($0) })
        return EyeTag.allCases.filter(present.contains)
    }

    var body: some View {
        let shown = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Show", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .padding(.horizontal)

                chips

                if shown.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle")
                        .padding(.top, 40)
                } else {
                    grid(shown)
                }

                discardedLink
                    .padding(.top, 8)
            }
            .padding(.bottom)
        }
        .canvas()
        .barTitle(scope.title)
        .toolbar { menu(shown) }
        .safeAreaInset(edge: .bottom) { CurationStatus(tripID: scope.tripID) }
        .animation(.default, value: filter)
        .animation(.default, value: kind)
        .onChange(of: availableTags) { _, tags in
            if case .tag(let tag) = filter, !tags.contains(tag) { filter = .all }
        }
        .fullScreenCover(item: $viewing) { selection in
            MediaViewer(items: selection.items, current: selection.startID)
                .navigationTransition(.zoom(sourceID: selection.startID, in: zoom))
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All", isOn: filter == .all) { filter = .all }
                Chip(title: "Best of", symbol: "star", isOn: filter == .best) { filter = .best }
                ForEach(availableTags) { tag in
                    Chip(title: tag.title, symbol: tag.symbol, isOn: filter == .tag(tag)) { filter = .tag(tag) }
                }
            }
            .padding(.horizontal)
        }
    }

    private func grid(_ items: [MediaItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
            ForEach(items) { item in
                let added = alreadyAdded.contains(item.id)
                Button {
                    selection.toggle(item)
                } label: {
                    Tile(item: item, dimmed: added)
                        .overlay(alignment: .topTrailing) {
                            SelectionBadge(isSelected: selection.contains(item), isAdded: added)
                        }
                }
                .buttonStyle(.plain)
                .disabled(added)
                .matchedTransitionSource(id: item.id, in: zoom)
                .accessibilityAddTraits(selection.contains(item) ? .isSelected : [])
                .contextMenu {
                    Button("View", systemImage: "arrow.up.left.and.arrow.down.right") {
                        viewing = ViewerSelection(items: items, startID: item.id)
                    }
                    Button("Discard", systemImage: "hand.thumbsdown") {
                        selection.remove([item])
                        withAnimation { curator.discard(item) }
                    }
                } preview: {
                    AssetImage(asset: item.asset, contentMode: .fit)
                        .frame(width: 300, height: 300)
                }
            }
        }
    }

    @ViewBuilder
    private var discardedLink: some View {
        let discarded = curator.discarded(scope.items)
        if !discarded.isEmpty {
            NavigationLink(value: Route.discarded(scope)) {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("\(discarded.count) discarded \(noun(for: discarded))")
                        .font(.text(.subheadline, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .padding(.vertical, 14)
                .background(Color.surface, in: .rect(cornerRadius: 14))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }

    @ToolbarContentBuilder
    private func menu(_ shown: [MediaItem]) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Order", selection: $rankByEye) {
                    Label("By Date", systemImage: "calendar").tag(false)
                    Label("By Eye Score", systemImage: "sparkles").tag(true)
                }
            } label: {
                Label("Options", systemImage: "ellipsis")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            let pickable = shown.filter { !alreadyAdded.contains($0.id) }
            let allSelected = !pickable.isEmpty && pickable.allSatisfy(selection.contains)
            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected { selection.remove(pickable) } else { selection.add(pickable) }
            }
            .disabled(pickable.isEmpty)
        }
    }

    private var emptyTitle: String {
        switch kind {
        case .videos: "No videos"
        case .photos: "No photos"
        case .all: "Nothing here"
        }
    }
}

func noun(for items: [MediaItem]) -> String {
    let videos = items.filter(\.isVideo).count
    if videos == 0 { return items.count == 1 ? "photo" : "photos" }
    if videos == items.count { return items.count == 1 ? "video" : "videos" }
    return "photos and videos"
}

struct ViewerSelection: Identifiable {
    let items: [MediaItem]
    let startID: String
    var id: String { startID }
}

private struct SelectionBadge: View {
    let isSelected: Bool
    let isAdded: Bool

    var body: some View {
        Group {
            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.paper, .gray)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.canvas, Color.ink)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Color.paper.opacity(0.9))
            }
        }
        .font(.title3)
        .shadow(color: .black.opacity(0.3), radius: 2)
        .padding(5)
    }
}

private struct Chip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let symbol, isOn {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
        .font(.text(.subheadline, weight: .medium))
        .foregroundStyle(isOn ? Color.canvas : Color.ink)
        .buttonBorderShape(.capsule)
        .tint(isOn ? .accentColor : .secondary)
        .modifier(ChipStyle(isOn: isOn))
    }
}

private struct ChipStyle: ViewModifier {
    let isOn: Bool
    func body(content: Content) -> some View {
        if isOn { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

struct Tile: View {
    let item: MediaItem
    var dimmed = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { AssetImage(asset: item.asset) }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Text(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.text(.caption2, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.paper)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.text(.caption2))
                        .foregroundStyle(Color.paper)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .saturation(dimmed ? 0.15 : 1)
            .opacity(dimmed ? 0.6 : 1)
            .clipped()
            .contentShape(.rect)
    }
}
