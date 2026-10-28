import CoreLocation
import Observation
import Photos
import PhotosUI
import SwiftUI

/// What the user has ticked in the picker, across every screen of it, in the order it was ticked.
@MainActor @Observable
final class PickerSelection {
    private(set) var items: [MediaItem] = []
    private var ids: Set<String> = []

    var count: Int { items.count }

    func contains(_ item: MediaItem) -> Bool { ids.contains(item.id) }

    func toggle(_ item: MediaItem) {
        if ids.remove(item.id) != nil {
            items.removeAll { $0.id == item.id }
        } else {
            ids.insert(item.id)
            items.append(item)
        }
    }

    func add(_ new: [MediaItem]) {
        for item in new where ids.insert(item.id).inserted { items.append(item) }
    }

    func remove(_ old: [MediaItem]) {
        let gone = Set(old.map(\.id))
        ids.subtract(gone)
        items.removeAll { gone.contains($0.id) }
    }
}

enum Route: Hashable {
    case trip(String)
    case scope(MediaScope)
    case discarded(MediaScope)
}

/// The image picker: browse the library by trip, place, day or week, with Eye's curation,
/// tick what you want, and hand it back.
struct MediaPicker: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(Curator.self) private var curator
    @Environment(\.dismiss) private var dismiss
    @State private var selection = PickerSelection()
    @State private var showsSystemPicker = false
    @State private var systemPicks: [PhotosPickerItem] = []

    /// IDs already in the trip being added to. They show as added and can't be picked twice.
    var alreadyAdded: Set<String> = []
    /// Whether the picker closes once media is added. A new album keeps the sheet open for its next step.
    var closesOnAdd = true
    /// The places of the album being added to, when it has any. Trips nearest them are listed first.
    var near: [CLLocationCoordinate2D] = []
    let onAdd: ([MediaItem]) -> Void

    var body: some View {
        NavigationStack {
            PickerTripsView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .trip(let id): TripView(tripID: id)
                    case .scope(let scope): MediaGridView(scope: scope)
                    case .discarded(let scope): DiscardedView(scope: scope)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("All Photos", systemImage: "photo.on.rectangle") { showsSystemPicker = true }
                    }
                }
                // The system photo picker, for anything the trips don't cover.
                // What is chosen there joins the same selection as everything ticked here.
                .photosPicker(
                    isPresented: $showsSystemPicker,
                    selection: $systemPicks,
                    matching: .any(of: [.images, .videos]),
                    photoLibrary: .shared()
                )
                .onChange(of: systemPicks) { _, picks in
                    guard !picks.isEmpty else { return }
                    let ids = picks.compactMap(\.itemIdentifier)
                    var found: [String: MediaItem] = [:]
                    PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                        if !alreadyAdded.contains(asset.localIdentifier) { found[asset.localIdentifier] = MediaItem(asset: asset) }
                    }
                    // In the order they were chosen; the fetch doesn't keep it.
                    selection.add(ids.compactMap { found[$0] })
                    systemPicks = []
                }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.count > 0 {
                Button {
                    onAdd(selection.items)
                    if closesOnAdd { dismiss() }
                } label: {
                    Text("Add \(selection.count) \(noun(for: selection.items))")
                        .font(.text(.headline, weight: .semibold))
                        .foregroundStyle(Color.canvas)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selection.count > 0)
        .environment(selection)
        .environment(\.alreadyAdded, alreadyAdded)
        .environment(\.pickerNear, near)
        .task {
            await library.start()
            if library.access == .full || library.access == .limited {
                curator.curateLibrary(first: library.trips.filter(\.isPossible).flatMap(\.items))
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var alreadyAdded: Set<String> = []
    @Entry var pickerNear: [CLLocationCoordinate2D] = []
}
