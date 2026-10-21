import AVKit
import Photos
import SwiftUI

struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Curator.self) private var curator
    let items: [MediaItem]
    @State var current: String

    private var item: MediaItem? { items.first { $0.id == current } }

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(items) { item in
                    Group {
                        if item.isVideo {
                            VideoPage(asset: item.asset)
                        } else {
                            AssetImage(asset: item.asset, contentMode: .fit, full: true)
                        }
                    }
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .background(.black)
            .barTitle(item.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let item { EyePanel(item: item) }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// What Eye thinks of the current item, and the one decision you can make about it.
private struct EyePanel: View {
    @Environment(Curator.self) private var curator
    let item: MediaItem

    var body: some View {
        let reason = curator.reason(item)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let analysis = curator.analyses[item.id] {
                    Text("Eye score \(Int((analysis.score * 100).rounded()))")
                        .font(.text(.subheadline, weight: .semibold))
                    let tags = EyeTag.allCases.filter(analysis.tags.contains)
                    if let reason {
                        Label(reason.title, systemImage: reason.symbol)
                            .font(.text(.caption))
                            .foregroundStyle(.secondary)
                    } else if !tags.isEmpty {
                        Text(tags.map(\.title).joined(separator: " \u{00B7} "))
                            .font(.text(.caption))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not curated yet").font(.text(.subheadline)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if reason == nil {
                Button("Discard", systemImage: "hand.thumbsdown") {
                    withAnimation { curator.discard(item) }
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    withAnimation { curator.restore(item) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward").foregroundStyle(Color.canvas)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal)
    }
}

private struct VideoPage: View {
    let asset: PHAsset
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                AssetImage(asset: asset, contentMode: .fit, full: true)
                ProgressView()
            }
        }
        .task {
            if let item = await ImageLoader.shared.playerItem(for: asset) {
                player = AVPlayer(playerItem: item)
            }
        }
        .onDisappear { player?.pause() }
    }
}
