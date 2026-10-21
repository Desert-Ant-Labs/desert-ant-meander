import SwiftUI

@main
struct TravelPicksApp: App {
    @State private var library = PhotoLibrary()
    @State private var curator = Curator()
    @State private var store = TripStore()

    init() { Theme.apply() }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(library)
                .environment(curator)
                .environment(store)
                .font(.text(.body))
                // Text is charcoal on cream (cream on charcoal in dark mode) unless a view sets its own colour,
                // like the cream text over photos. Secondary text is a fainter shade of the same.
                .foregroundStyle(Color.ink)
                .tint(Color.ink)
                // Eye downloads at launch so it's ready when the picker opens.
                .task { await curator.prepareModel() }
        }
    }
}
