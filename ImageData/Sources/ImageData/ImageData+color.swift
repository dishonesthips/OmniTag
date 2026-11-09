import SwiftUI
import Metadata

// various image metadata values are displayed in different colors
// depending upon current state.  The colors used in addition to
// .primary and .secondary are defined here.

extension Color {
    public static let changed = Color(nsColor: .systemGreen)
    public static let mostSelected = Color(nsColor: .systemYellow)
}

// and the code to select the appropriate color for timestamps
// and location fields

extension ImageData {
    public var timestampTextColor: Color {
        if updatable {
            return metadata.dateTimeCreated == original?.dateTimeCreated
                ? .primary
                : .changed
        }
        return .secondary
    }

    public var locationTextColor: Color {
        if updatable {
            return metadata.location == original?.location
                ? .primary
                : .changed
        }
        return .secondary
    }

    /// Color for a camera/film metadata field based on whether it differs
    /// from the value captured when the image was loaded.
    public func filmMetadataTextColor(
        _ keyPath: KeyPath<Metadata, String?>
    ) -> Color {
        if updatable {
            return metadata[keyPath: keyPath] == original?[keyPath: keyPath]
                ? .primary
                : .changed
        }
        return .secondary
    }
}
