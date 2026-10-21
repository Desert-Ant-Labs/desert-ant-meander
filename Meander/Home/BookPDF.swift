import MapKit
import SwiftUI
import UIKit

/// Renders a book to a PDF: one page per spread, in the book's style, at Figma size (1000×624).
@MainActor
enum BookPDF {
    static var spreadSize: CGSize { BookType.spreadSize }

    static func make(trip: SavedTrip, cover: MediaItem?, photos: [MediaItem], spreads: [BookSpread], stops: [TripStop]) async throws -> URL {
        var images: [String: UIImage] = [:]
        for item in Set(photos + [cover].compactMap { $0 }) {
            if let image = await ImageLoader.shared.image(for: item.asset, size: CGSize(width: 1800, height: 1800), mode: .aspectFit) {
                images[item.id] = decoded(image)
            }
        }
        let map = stops.isEmpty ? nil : await mapSnapshot(stops, photos: images)

        let name = trip.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).pdf")
        guard let pdf = CGContext(url as CFURL, mediaBox: nil, nil) else { throw CocoaError(.fileWriteUnknown) }

        func page<V: View>(_ view: V, size: CGSize) {
            let renderer = ImageRenderer(content: view
                .frame(width: size.width, height: size.height)
                .environment(\.preloadedImages, images)
                .environment(\.routeMapSnapshot, map))
            renderer.render { _, draw in
                var box = CGRect(origin: .zero, size: size)
                pdf.beginPage(mediaBox: &box)
                draw(pdf)
                pdf.endPage()
            }
        }

        for (index, spread) in spreads.enumerated() {
            page(BookSpreadView(spread: spread, style: trip.bookStyle, trip: trip, stops: stops, firstPage: index * 2 - 1, printing: true), size: spreadSize)
        }
        pdf.closePDF()
        return url
    }

    /// A plain bitmap copy at most 1800 points on its long side. Photos can come back lazily decoded
    /// or larger than asked, and those draw blank into a PDF.
    private static func decoded(_ image: UIImage) -> UIImage {
        let scale = min(1, 1800 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// The route map as a still: satellite imagery, the route along the roads where it's known,
    /// and each stop's photo in a ringed circle, matching the live map.
    private static func mapSnapshot(_ stops: [TripStop], photos: [String: UIImage]) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = TripRouteMap.region(for: stops)
        options.size = CGSize(width: 1200, height: 1500)
        options.mapType = .hybridFlyover
        options.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        return UIGraphicsImageRenderer(size: options.size).image { context in
            snapshot.image.draw(at: .zero)
            let cg = context.cgContext
            cg.setStrokeColor(UIColor(Color.paper).cgColor)
            cg.setLineWidth(8)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for (from, to) in zip(stops, stops.dropFirst()) {
                let road = RouteCache.shared.routes[RouteCache.key(from.coordinate, to.coordinate)] ?? [from.coordinate, to.coordinate]
                let points = road.map(snapshot.point(for:))
                guard let first = points.first else { continue }
                cg.move(to: first)
                points.dropFirst().forEach(cg.addLine(to:))
                cg.strokePath()
            }
            let side: CGFloat = 64
            for stop in stops {
                let centre = snapshot.point(for: stop.coordinate)
                let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
                cg.saveGState()
                cg.addEllipse(in: rect)
                cg.clip()
                if let image = photos[stop.cover.id] {
                    let scale = max(side / image.size.width, side / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height))
                }
                cg.restoreGState()
                cg.setLineWidth(5)
                cg.strokeEllipse(in: rect.insetBy(dx: 2.5, dy: 2.5))
            }
        }
    }
}

/// The system share sheet, which offers Save to Files, Mail, AirDrop and printing for the PDF.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
