import Foundation

/// What the image model says about one photo or video.
///
/// This is the contract the app is built on. The Eye model from Desert Ant Labs is in beta,
/// so `PreviewEye` fills it in with Apple's Vision framework for now. When the Eye SDK is
/// available, add a type that conforms to `EyeModel` and pass it to `Curator`; the screens
/// do not change.
struct EyeAnalysis: Codable, Hashable, Sendable {
    var tags: Set<EyeTag>
    /// 0 to 1. Higher is a better shot. Used to rank and to pick "Best of".
    var score: Double
    var discard: DiscardReason?
}

enum EyeTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case sights, selfies, landscapes, people, food, temples

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sights: "Sights"
        case .selfies: "Selfies"
        case .landscapes: "Landscapes"
        case .people: "People"
        case .food: "Food"
        case .temples: "Temples"
        }
    }

    var symbol: String {
        switch self {
        case .sights: "building.columns"
        case .selfies: "person.crop.square"
        case .landscapes: "mountain.2"
        case .people: "person.2"
        case .food: "fork.knife"
        case .temples: "sparkles"
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
