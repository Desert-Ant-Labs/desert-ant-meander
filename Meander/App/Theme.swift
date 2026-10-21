import SwiftUI
import UIKit

/// Meander's two colours: cream (#FCFAEC) and charcoal (#393F45). Light mode is charcoal on cream,
/// dark mode is cream on charcoal.
extension Color {
    /// Cream in both modes. For text and lines drawn over photos and maps, and for journal pages.
    static let paper = Color(red: 0xFC / 255, green: 0xFA / 255, blue: 0xEC / 255)
    /// Charcoal in both modes. For text on journal pages, which are always cream.
    static let meanderDark = Color(red: 0x39 / 255, green: 0x3F / 255, blue: 0x45 / 255)
    /// The screen background: cream in light mode, charcoal in dark mode.
    static let canvas = Color("Canvas")
    /// Text and primary buttons: charcoal in light mode, cream in dark mode.
    static let ink = Color("Ink")
    /// Cards and rows that sit on the canvas.
    static let surface = Color("Surface")
}

extension View {
    /// Fills the screen behind this view with the canvas colour.
    func canvas() -> some View {
        background(Color.canvas.ignoresSafeArea())
    }
}

/// Two typefaces: EB Garamond for journal entries, Mona Sans for everything else.
/// Both are in `Fonts/`, registered at launch by `Theme.apply()`.
extension Font {
    /// An album's title, on cards, the album screen and books: Mona Sans semibold.
    static func albumTitle(_ style: Font.TextStyle) -> Font {
        .custom(Theme.textFamily, size: Theme.size(style), relativeTo: style).weight(.semibold)
    }

    /// A journal entry's text, in the album title face.
    static func journal(_ style: Font.TextStyle) -> Font {
        .custom(Theme.serifFamily, size: Theme.size(style), relativeTo: style).weight(.medium)
    }

    static func heading(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .custom(Theme.headingFamily, size: Theme.size(style), relativeTo: style).weight(weight)
    }

    static func text(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(Theme.textFamily, size: Theme.size(style), relativeTo: style).weight(weight)
    }
}

/// The small heading in a title bar. Every screen draws it with this one view so they all match.
/// The Meander wordmark, drawn in the ink colour so it is charcoal on cream and cream on charcoal.
struct Wordmark: View {
    var body: some View {
        Image("Logo")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(776.0 / 116.0, contentMode: .fit)
            .foregroundStyle(Color.ink)
            .accessibilityLabel("Meander")
            .accessibilityAddTraits(.isHeader)
    }
}

struct BarTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.heading(.headline, weight: .semibold))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
    }
}

extension View {
    /// An inline title bar heading in the heading font.
    func barTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .title) { BarTitle(title) }
            }
    }
}

extension Text {
    /// Letter-spacing for a trip's date: 2% of the type size.
    func dateTracking(_ style: Font.TextStyle) -> Text { tracking(Theme.size(style) * 0.02) }
}

enum Theme {
    static let headingFamily = "Mona Sans"
    static let serifFamily = "EB Garamond"
    static let textFamily = "Mona Sans"

    /// The system's default point size for each text style.
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }

    /// Registers the two bundled fonts and styles the system segmented control:
    /// text font, and a selected segment that is ink with canvas-coloured text.
    @MainActor static func apply() {
        for file in ["EBGaramond", "MonaSans"] {
            if let url = Bundle.main.url(forResource: file, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        let font = UIFont(descriptor: UIFontDescriptor(fontAttributes: [
            .family: textFamily,
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium],
        ]), size: 15)
        let ink = UIColor(named: "Ink") ?? .label
        let canvas = UIColor(named: "Canvas") ?? .systemBackground
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = ink
        segmented.setTitleTextAttributes([.foregroundColor: ink, .font: font], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: canvas, .font: font], for: .selected)
    }
}

/// A soft band of light sweeping across, left to right, for text that means "working on it".
/// Held still when Reduce Motion is on.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period = 1.6

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .opacity(0.7)
                .overlay {
                    // Driven by the clock so it runs anywhere, including inside lazy lists.
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                        let phase = -0.3 + 1.6 * t
                        // The band in the full text colour, so it shows even on faint secondary text.
                        content
                            .foregroundStyle(Color.ink)
                            .mask {
                                LinearGradient(
                                    stops: [.init(color: .clear, location: phase - 0.3),
                                            .init(color: .black, location: phase),
                                            .init(color: .clear, location: phase + 0.3)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            }
                    }
                }
        }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View {
        Group { if active { modifier(Shimmer()) } else { self } }
    }
}
