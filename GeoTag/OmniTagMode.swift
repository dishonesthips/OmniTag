import SwiftUI

enum OmniTagMode: String, CaseIterable, Identifiable, Sendable {
    case location
    case time
    case film

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }
}
