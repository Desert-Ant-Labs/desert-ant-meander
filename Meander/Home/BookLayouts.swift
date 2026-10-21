import CoreLocation
import SwiftUI
import UIKit

/// How a book lays out its photos. Chosen per book. The layouts follow the "Book Styles"
/// section of the Demo Apps Figma file; every measurement below is in its points.
enum BookStyle: String, Codable, CaseIterable, Identifiable {
    /// A large title, one photo per page in a fixed frame, page numbers and captions.
    case gallery = "Gallery"
    /// Photos run the full height of the page, with the title, place and date running up the margin.
    case fullBleed = "Full Bleed"

    var id: String { rawValue }

    /// Books saved in a style that has since been removed (Editorial, later Minimal) open as Gallery.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BookStyle(rawValue: raw) ?? .gallery
    }
}

/// A photo in the book, with what the layouts need to know about it.
struct BookPhoto: Hashable {
    let item: MediaItem
    let aspect: Double
    let place: String?

    var isWide: Bool { aspect >= StoryFrame.wideAspect }
}

enum BookPage: Hashable {
    case blank
    /// A photo, with a journal entry set beneath it when one follows a landscape (Gallery).
    case photo(BookPhoto, note: JournalNote?)
    case note(JournalNote)
}

extension BookPage {
    /// Where the page's photo was taken, for Full Bleed's margin.
    var place: String? {
        if case .photo(let photo, _) = self { photo.place } else { nil }
    }
}

enum BookSpread: Hashable {
    /// The first spread: the album's title, cover photo and description, facing the route map.
    case opening(cover: MediaItem?, hasMap: Bool)
    case pages(BookPage, BookPage)
    /// One photo across both pages (Full Bleed).
    case across(BookPhoto)
}

/// Lays an album out as spreads in a given style.
enum BookLayout {
    enum Entry { case photo(BookPhoto), note(JournalNote) }

    static func spreads(_ style: BookStyle, cover: MediaItem?, entries: [Entry], hasMap: Bool) -> [BookSpread] {
        var spreads: [BookSpread] = [.opening(cover: cover, hasMap: hasMap)]
        switch style {
        case .gallery:
            let pages = pages(entries)
            spreads += stride(from: 0, to: pages.count, by: 2).map { .pages(pages[$0], pages[safe: $0 + 1] ?? .blank) }
        case .fullBleed:
            spreads += fullBleed(entries)
        }
        return spreads
    }

    private static func pages(_ entries: [Entry]) -> [BookPage] {
        var pages: [BookPage] = []
        var index = 0
        while index < entries.count {
            switch entries[index] {
            case .note(let note):
                pages.append(.note(note))
                index += 1
            case .photo(let photo):
                let next = entries[safe: index + 1]
                if photo.isWide, case .note(let note) = next {
                    pages.append(.photo(photo, note: note))
                    index += 2
                } else {
                    pages.append(.photo(photo, note: nil))
                    index += 1
                }
            }
        }
        return pages
    }

    /// Landscapes run across the spread. A portrait takes the left page, facing the next portrait
    /// or journal entry.
    private static func fullBleed(_ entries: [Entry]) -> [BookSpread] {
        var spreads: [BookSpread] = []
        var index = 0
        while index < entries.count {
            switch entries[index] {
            case .note(let note):
                spreads.append(.pages(.blank, .note(note)))
                index += 1
            case .photo(let photo) where photo.isWide:
                spreads.append(.across(photo))
                index += 1
            case .photo(let photo):
                switch entries[safe: index + 1] {
                case .note(let note):
                    spreads.append(.pages(.photo(photo, note: nil), .note(note)))
                    index += 2
                case .photo(let next) where !next.isWide:
                    spreads.append(.pages(.photo(photo, note: nil), .photo(next, note: nil)))
                    index += 2
                default:
                    spreads.append(.pages(.photo(photo, note: nil), .blank))
                    index += 1
                }
            }
        }
        return spreads
    }

    /// The pin nearest a photo, within 80km.
    static func place(of item: MediaItem, pins: [SavedTrip.Pin]) -> String? {
        guard let location = item.location else { return nil }
        return pins
            .map { ($0.name, CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: location)) }
            .filter { $0.1 < 80_000 }
            .min { $0.1 < $1.1 }?.0
    }
}

// MARK: - Type and colour

enum BookType {
    static let paper = Color(red: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255)
    static let ink = Color.black

    /// A spread in Figma points: two 500×624 pages.
    static let spreadSize = CGSize(width: 1000, height: 624)
    static let pageWidth: CGFloat = 500

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom(Theme.textFamily, size: size).weight(weight)
    }

    static func serif(_ size: CGFloat) -> Font {
        .custom(Theme.serifFamily, size: size).weight(.medium)
    }

    /// Mona Sans for UIKit drawing. It's a variable font, so the weight is asked for as a trait.
    static func monaSans(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: UIFontDescriptor(fontAttributes: [
            .family: Theme.textFamily,
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ]), size: size)
    }

    /// "September 2024", as the Gallery running heads print it.
    static func longMonth(_ trip: SavedTrip) -> String {
        trip.start.formatted(.dateTime.month(.wide).year())
    }
}

// MARK: - Drawing

/// One spread, drawn at Figma size (1000×624) and scaled to fit wherever it's shown.
struct BookSpreadView: View {
    let spread: BookSpread
    let style: BookStyle
    let trip: SavedTrip
    let stops: [TripStop]
    /// The number printed on the left page; the right page is one more.
    let firstPage: Int
    /// For the PDF: no fold shading, no shadow, no rounded corners.
    var printing = false

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / BookType.spreadSize.width
            content
                .frame(width: BookType.spreadSize.width, height: BookType.spreadSize.height, alignment: .topLeading)
                .background(BookType.paper)
                .foregroundStyle(BookType.ink)
                .overlay { if !printing { fold } }
                .clipped()
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(BookType.spreadSize.width / BookType.spreadSize.height, contentMode: .fit)
        .clipShape(.rect(cornerRadius: printing ? 0 : 3))
        .shadow(color: .black.opacity(printing ? 0 : 0.2), radius: 14, y: 8)
    }

    private var fold: some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0.47), .init(color: .black.opacity(0.1), location: 0.5), .init(color: .clear, location: 0.53)],
            startPoint: .leading, endPoint: .trailing
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .gallery: GallerySpread(spread: spread, trip: trip, stops: stops, firstPage: firstPage)
        case .fullBleed: FullBleedSpread(spread: spread, trip: trip, stops: stops)
        }
    }
}

/// Places a view in the spread by its top-left corner.
private extension View {
    func at(_ x: CGFloat, _ y: CGFloat, width: CGFloat? = nil) -> some View {
        frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: width == nil, vertical: true)
            .offset(x: x, y: y)
    }
}

private struct BookPhotoView: View {
    let item: MediaItem
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        AssetImage(asset: item.asset).frame(width: width, height: height).clipped()
    }
}

// MARK: Gallery

private struct GallerySpread: View {
    let spread: BookSpread
    let trip: SavedTrip
    let stops: [TripStop]
    let firstPage: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch spread {
            case .opening(let cover, let hasMap):
                Text(trip.title).font(BookType.sans(32)).lineLimit(1).at(28, 21, width: 444)
                Text(trip.subtitle.uppercased()).font(BookType.sans(9)).at(28, 63, width: 444)
                if let cover { BookPhotoView(item: cover, width: 444, height: 438).offset(x: 28, y: 91) }
                Text(BookType.longMonth(trip)).font(BookType.serif(12)).at(28, 581)
                if hasMap { RouteMapImage(stops: stops).frame(width: 364, height: 466).clipped().offset(x: 568, y: 79) }
            case .pages(let left, let right):
                Text(trip.title).font(BookType.sans(32)).lineLimit(1).at(28, 21, width: 600)
                Text(BookType.longMonth(trip)).font(BookType.serif(12))
                    .frame(width: 300, alignment: .trailing).offset(x: 677, y: 21)
                page(left, x: 0, isLeft: true)
                page(right, x: BookType.pageWidth, isLeft: false)
                Text("\(firstPage).").font(BookType.serif(24)).at(28, 569)
                if right != .blank { Text("\(firstPage + 1).").font(BookType.serif(24)).at(525, 569) }
            case .across:
                EmptyView()
            }
        }
    }

    /// The page's photo with its caption or journal entry, centred between the title and the page
    /// numbers. Landscapes sit 28 (left page) or 30 (right page) in from the page edge, portraits 64 or 68.
    @ViewBuilder
    private func page(_ page: BookPage, x: CGFloat, isLeft: Bool) -> some View {
        switch page {
        case .photo(let photo, let note):
            let size = photo.isWide ? CGSize(width: 447, height: 322) : CGSize(width: 364, height: 466)
            let inset: CGFloat = photo.isWide ? (isLeft ? 28 : 30) : (isLeft ? 64 : 68)
            centred(x: x + inset) {
                VStack(alignment: .leading, spacing: 0) {
                    BookPhotoView(item: photo.item, width: size.width, height: size.height)
                    if let note {
                        noteText(note).padding(.top, 21)
                    } else if photo.place != nil {
                        caption(photo).frame(width: 303, alignment: .leading).padding(.top, 6)
                    }
                }
            }
        case .note(let note):
            centred(x: x + 28) { noteText(note) }
        case .blank:
            EmptyView()
        }
    }

    /// The space between the title (which ends at 66) and the page numbers (which start at 569).
    private func centred<Content: View>(x: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize()
            .frame(height: 569 - 66)
            .offset(x: x, y: 66)
    }

    private func noteText(_ note: JournalNote) -> some View {
        Text(note.text).font(BookType.serif(12)).lineSpacing(12 * 0.3).frame(width: 303, alignment: .leading)
    }

    @ViewBuilder
    private func caption(_ photo: BookPhoto) -> some View {
        if let place = photo.place { Text(place.uppercased()).font(BookType.sans(9)) }
    }
}

// MARK: Full Bleed

private struct FullBleedSpread: View {
    let spread: BookSpread
    let trip: SavedTrip
    let stops: [TripStop]

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch spread {
            case .opening(let cover, let hasMap):
                if let cover { BookPhotoView(item: cover, width: 449, height: 624).offset(x: 51) }
                if hasMap { RouteMapImage(stops: stops).frame(width: 449, height: 624).clipped().offset(x: 500) }
                // The title in a paper box that fits the words, its bottom edge 35 points off the page's foot.
                let title = Text(trip.title.uppercased()).font(BookType.sans(38)).lineSpacing(-38 * 0.4)
                // One line hugs its words; a longer title wraps at 366.
                ViewThatFits(in: .horizontal) {
                    title.fixedSize()
                    title.frame(width: 366, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                    .fixedSize()
                    // Mona Sans sets taller than Figma's 1.0 line height; trim it back.
                    .padding(.vertical, -8)
                    .padding(EdgeInsets(top: 10, leading: 11, bottom: 12, trailing: 11))
                    .background(BookType.paper)
                    .frame(height: 589, alignment: .bottomLeading)
                    .offset(x: 80)
                VerticalLabel(text: trip.month, font: BookType.serif(12), tracking: 0.72, edge: 43, top: 13)
                VerticalLabel(text: trip.subtitle.uppercased(), font: BookType.sans(12), edge: 44, bottom: 611)
            case .across(let photo):
                BookPhotoView(item: photo.item, width: 817, height: 624).offset(x: 92)
                margin(places: [photo.place])
            case .pages(let left, let right):
                page(left, x: 96)
                page(right, x: 500)
                margin(places: [left, right].map(\.place))
            }
        }
    }

    /// The date at the top of the left margin; the album title at its foot, with the spread's
    /// place running on above it, 40 points clear.
    private func margin(places: [String?]) -> some View {
        var seen: Set<String> = []
        let place = places.compactMap { $0 }.filter { seen.insert($0).inserted }.joined(separator: " \u{2022} ")
        return ZStack(alignment: .topLeading) {
            VerticalLabel(text: trip.month, font: BookType.serif(12), tracking: 0.72, edge: 85, top: 13)
            VerticalLabel(text: trip.title.uppercased(), secondary: place.isEmpty ? nil : place.uppercased(),
                          font: BookType.sans(16), edge: 85, bottom: 611)
        }
    }

    @ViewBuilder
    private func page(_ page: BookPage, x: CGFloat) -> some View {
        switch page {
        case .photo(let photo, _):
            BookPhotoView(item: photo.item, width: 404, height: 624).offset(x: x)
        case .note(let note):
            JustifiedText(text: note.text, font: BookType.monaSans(30, weight: .semibold),
                          lineHeight: 1.4, width: 447, maxHeight: 560)
                .frame(height: 624)
                .offset(x: 527)
        case .blank:
            EmptyView()
        }
    }
}

/// Text running bottom-to-top, its right edge on a line `edge` points from the spread's left,
/// either reading towards `top` or ending at `bottom`.
private struct VerticalLabel: View {
    let text: String
    /// Further text running on after `text`, 40 points clear of it.
    var secondary: String?
    let font: Font
    var tracking: CGFloat = 0
    let edge: CGFloat
    var top: CGFloat?
    var bottom: CGFloat?

    var body: some View {
        RotatedLeft {
            HStack(spacing: 40) {
                Text(text)
                if let secondary { Text(secondary) }
            }
            .font(font).tracking(tracking).lineLimit(1).fixedSize()
            .rotationEffect(.degrees(-90))
        }
        .frame(width: edge, alignment: .trailing)
        .frame(height: (bottom ?? BookType.spreadSize.height) - (top ?? 0), alignment: top != nil ? .top : .bottom)
        .offset(y: top ?? 0)
    }
}

/// Lays its one child out turned a quarter-turn anticlockwise, so it takes up the rotated space.
private struct RotatedLeft: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let size = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(.unspecified)
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
    }
}

/// Justified text, which SwiftUI can't lay out, drawn by UIKit into an image at print resolution.
private struct JustifiedText: View {
    let text: String
    let font: UIFont
    let lineHeight: CGFloat
    let width: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        let image = Self.render(text, font: font, lineHeight: lineHeight, width: width, maxHeight: maxHeight)
        Image(uiImage: image).resizable().frame(width: image.size.width, height: image.size.height)
            .accessibilityLabel(text)
    }

    /// Shrinks the type until the text fits the height, like a minimum scale factor.
    static func render(_ text: String, font: UIFont, lineHeight: CGFloat, width: CGFloat, maxHeight: CGFloat) -> UIImage {
        var size = font.pointSize
        var attributed = NSAttributedString()
        var bounds = CGRect.zero
        repeat {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .justified
            paragraph.minimumLineHeight = size * lineHeight
            paragraph.maximumLineHeight = size * lineHeight
            attributed = NSAttributedString(string: text, attributes: [
                .font: font.withSize(size), .paragraphStyle: paragraph, .foregroundColor: UIColor.black,
            ])
            bounds = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            size -= 1
        } while bounds.height > maxHeight && size > 10
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let canvas = CGSize(width: width, height: ceil(bounds.height))
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            attributed.draw(with: CGRect(origin: .zero, size: canvas), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }
}

/// The live route map on screen, or its still when rendering to a PDF.
private struct RouteMapImage: View {
    let stops: [TripStop]
    @Environment(\.routeMapSnapshot) private var snapshot

    var body: some View {
        if let snapshot {
            Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fill).clipped()
        } else {
            TripRouteMap(stops: stops)
        }
    }
}
