import SwiftUI

struct DiscardedView: View {
    @Environment(Curator.self) private var curator
    let scope: MediaScope

    @State private var selected: String?
    @State private var confirmRestoreAll = false
    @State private var viewing: ViewerSelection?

    var body: some View {
        let discarded = curator.discarded(scope.items)
        let groups = DiscardReason.allCases.compactMap { reason -> (DiscardReason, [MediaItem])? in
            let items = discarded.filter { curator.reason($0) == reason }
            return items.isEmpty ? nil : (reason, items)
        }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Text("Duplicates, screenshots, menus and documents, people with closed eyes, accidental shots and unfocused shots are set aside. Nothing is deleted from Photos.")
                    .font(.text(.footnote))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ForEach(groups, id: \.0) { reason, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(reason.title) \u{00B7} \(items.count)", systemImage: reason.symbol)
                            .font(.text(.subheadline, weight: .semibold))
                            .padding(.horizontal)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                            ForEach(items) { item in
                                tile(item)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if discarded.isEmpty {
                ContentUnavailableView("Nothing discarded", systemImage: "checkmark.circle", description: Text("Everything in \(scope.title) made the cut."))
            }
        }
        .canvas()
        .barTitle("Discarded Media")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Restore All") { confirmRestoreAll = true }
                    .disabled(discarded.isEmpty)
            }
        }
        .confirmationDialog("Restore all \(discarded.count) \(noun(for: discarded))?", isPresented: $confirmRestoreAll, titleVisibility: .visible) {
            Button("Restore All") {
                withAnimation { discarded.forEach(curator.restore) }
            }
        }
        .fullScreenCover(item: $viewing) { selection in
            MediaViewer(items: selection.items, current: selection.startID)
        }
        .animation(.default, value: discarded.count)
    }

    private func tile(_ item: MediaItem) -> some View {
        let isSelected = selected == item.id
        return Tile(item: item, dimmed: !isSelected)
            .overlay {
                if isSelected {
                    Button {
                        withAnimation {
                            curator.restore(item)
                            selected = nil
                        }
                    } label: {
                        Text("Restore").foregroundStyle(Color.canvas)
                    }
                    .font(.text(.footnote, weight: .semibold))
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .onTapGesture {
                withAnimation(.snappy) { selected = isSelected ? nil : item.id }
            }
            .contextMenu {
                Button("View", systemImage: "eye") {
                    viewing = ViewerSelection(items: [item], startID: item.id)
                }
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    withAnimation { curator.restore(item) }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows the restore button")
    }
}
