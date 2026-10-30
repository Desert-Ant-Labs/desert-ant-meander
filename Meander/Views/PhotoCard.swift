import Photos
import SwiftUI

/// An album or trip as a photo card: its cover with the title in Forum capitals centred near the bottom,
/// and a small line of detail beneath. The same card on the home screen and in the picker.
struct PhotoCard<Detail: View>: View {
    let cover: PHAsset?
    let title: String
    /// Greys out the title while the trip's places are still being named.
    var isLocating = false
    @ViewBuilder let detail: Detail

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let cover {
                    AssetImage(asset: cover)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            LinearGradient(
                stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.45), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 6) {
                // One size for every card; long titles wrap onto a second line.
                Text(title)
                    .font(.albumTitle(size: 34))
                    .textCase(.uppercase)
                    .lineLimit(2)
                    .redacted(reason: isLocating ? .placeholder : [])
                detail
                    .font(.cardDetail)
                    .tracking(1)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: CardMetrics.cornerRadius))
        .contentShape(.rect(cornerRadius: CardMetrics.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

/// Sizes shared by cards and the album screen's photo frames.
enum CardMetrics {
    /// Cards on the home screen and in the picker.
    static let cornerRadius: CGFloat = 40
    /// The album screen's photo frames.
    static let albumCornerRadius: CGFloat = 56
    /// Between cards, and between a card and the screen edge.
    static let gap: CGFloat = 4
    /// Width over height: a little taller than wide-landscape, short of square.
    static let aspectRatio: CGFloat = 1.2
}

/// A card's detail line: parts joined by a middle dot, like "Jun 2024 · Koh Lanta · Bangkok".
func cardDetail(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
}

