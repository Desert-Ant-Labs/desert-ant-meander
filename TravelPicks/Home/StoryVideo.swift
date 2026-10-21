import AVFoundation
import Photos
import SwiftUI

/// A video in the trip carousel: fills the screen, plays once with no controls, and reports when it ends.
/// Its still frame shows until playback is ready.
struct StoryVideo: View {
    let asset: PHAsset
    /// True while something is covering the story, such as the menu.
    let isPaused: Bool
    let onEnded: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            AssetImage(asset: asset, full: true)
            if let player {
                PlayerLayer(player: player)
            }
        }
        .task(id: asset.localIdentifier) {
            guard let item = await ImageLoader.shared.playerItem(for: asset), !Task.isCancelled else { return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            if !isPaused { player.play() }
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                onEnded()
                break
            }
        }
        .onChange(of: isPaused) { _, paused in
            if paused { player?.pause() } else { player?.play() }
        }
        .onDisappear { player?.pause() }
        .accessibilityLabel("Video")
    }
}

private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
