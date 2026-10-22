import Foundation

/// What the image model says about one photo or video.
///
/// This is the contract the app is built on. The Eye model from Desert Ant Labs is in beta,
/// so `PreviewEye` fills it in with Apple's Vision framework for now. When the Eye SDK is
/// available, add a type that conforms to `EyeModel` and pass it to `Curator`; the screens
/// do not change.
struct EyeAnalysis: Codable, Hashable, Sendable {
    var tags: Set<EyeTag>
    /// 0 to 1. Higher is a better shot. Used to rank and to pick highlights.
    var score: Double
    var discard: DiscardReason?
}

/// The picker's filters. A photo can be in several.
enum EyeTag: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Oceans, mountains, beaches and other nature.
    case landscape
    /// Sunrises and sunsets.
    case goldenHour
    /// Selfies and posed shots of people.
    case people
    case food
    /// Buildings, ruins, temples and churches, markets, restaurants and city life.
    case sights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape: "Landscape"
        case .goldenHour: "Golden Hour"
        case .people: "People"
        case .food: "Food"
        case .sights: "Sights"
        }
    }

    var symbol: String {
        switch self {
        case .landscape: "mountain.2"
        case .goldenHour: "sun.horizon"
        case .people: "person.2"
        case .food: "fork.knife"
        case .sights: "building.columns"
        }
    }
}

enum DiscardReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case duplicate, closedEyes, accidental, unfocused, byYou

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicate: "Duplicates"
        case .closedEyes: "Closed eyes"
        case .accidental: "Accidental shots"
        case .unfocused: "Unfocused"
        case .byYou: "Discarded by you"
        }
    }

    var symbol: String {
        switch self {
        case .duplicate: "square.on.square"
        case .closedEyes: "eye.slash"
        case .accidental: "hand.raised"
        case .unfocused: "camera.aperture"
        case .byYou: "hand.thumbsdown"
        }
    }
}

protocol EyeModel: Sendable {
    /// Bump to throw away cached results when the model changes.
    var version: String { get }

    /// Analyzes a batch in time order. Batches let the model compare neighbours to find duplicates.
    func analyze(_ items: [MediaItem], progress: @escaping @Sendable (Int) -> Void) async -> [String: EyeAnalysis]
}
