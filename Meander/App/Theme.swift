import SwiftUI
import UIKit

/// Meander's two colours: cream (#FCFAEC) and near-black (#1A1A1A). Light mode is dark on cream,
/// dark mode is cream on dark.
extension Color {
    /// Cream in both modes. For text and lines drawn over photos and maps, and for journal pages.
    static let paper = Color(red: 0xFC / 255, green: 0xFA / 255, blue: 0xEC / 255)
    /// Near-black in both modes. For text on journal pages, which are always cream.
    static let meanderDark = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)
    /// The screen background: cream in light mode, near-black in dark mode.
    static let canvas = Color("Canvas")
    /// Text and primary buttons: near-black in light mode, cream in dark mode.
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

/// Two typefaces: Forum for album titles, the app title, journal entries and segmented controls;
/// Mona Sans for everything else. Both are in `Fonts/`, registered at launch by `Theme.apply()`.
extension Font {
    /// An album's title, on cards, the album screen and books: Forum, shown in capitals.
    static func albumTitle(size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(Theme.serifFamily, size: size, relativeTo: style)
    }

    /// An album's title at a text style's size.
    static func albumTitle(_ style: Font.TextStyle) -> Font {
        albumTitle(size: Theme.size(style), relativeTo: style)
    }

    /// A journal entry's text, in the album title face.
    static func journal(_ style: Font.TextStyle) -> Font {
        .custom(Theme.serifFamily, size: Theme.size(style), relativeTo: style)
    }

    /// Forum at a text style's size: for the segmented controls' look in SwiftUI text and short lines.
    static func serif(_ style: Font.TextStyle) -> Font {
        .custom(Theme.serifFamily, size: Theme.size(style), relativeTo: style)
    }

    /// The small line under an album's title: Mona Sans bold capitals, widely spaced.
    static let cardDetail = Font.custom(Theme.textFamily, size: 10, relativeTo: .caption2).weight(.bold)

    static func heading(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .custom(Theme.headingFamily, size: Theme.size(style), relativeTo: style).weight(weight)
    }

    static func text(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(Theme.textFamily, size: Theme.size(style), relativeTo: style).weight(weight)
    }
}

/// "MEANDER" in Forum capitals, in the ink colour so it is dark on cream and cream on dark.
struct Wordmark: View {
    var size: CGFloat = 68

    var body: some View {
        Text("MEANDER")
            .font(.custom(Theme.serifFamily, size: size, relativeTo: .largeTitle))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel("Meander")
            .accessibilityAddTraits(.isHeader)
    }
}

/// The small heading in a title bar. Every screen draws it with this one view so they all match.
struct BarTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.custom(Theme.serifFamily, size: 20, relativeTo: .headline))
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
    static let serifFamily = "Forum"
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
    /// Forum, and a selected segment that is ink with canvas-coloured text.
    @MainActor static func apply() {
        for file in ["Forum", "MonaSans"] {
            if let url = Bundle.main.url(forResource: file, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        let font = UIFont(name: serifFamily, size: 16) ?? .systemFont(ofSize: 15, weight: .medium)
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
