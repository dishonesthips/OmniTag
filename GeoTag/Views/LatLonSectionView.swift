import Coords
import CoreLocation
import ImageData
import Metadata
import SwiftUI
import UDF

struct LatLonSectionView: View {
    @Environment(GeoTagStore.self) var store

    var image: ImageData

    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var loadedLatitude: Double?
    @State private var loadedLongitude: Double?
    @State private var editTarget: Set<ImageData.ID> = []
    @State private var editImageID: ImageData.ID?
    @State private var undoGroupOpen = false
    @State private var geocodeTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    @AppStorage(Coords.coordFormatKey) var coordFormat: CoordFormat = .deg

    // notice the bogus "focused" value given to .focusedValue. I need a non
    // empty string to enable cut/copy/paste/select all and this was an
    // easy way to do it with a side effect of the menu commands being
    // enabled even when the fields are empty.

    var body: some View {
        VStack {
            LabeledContent("Latitude:") {
                TextField("Latitude", value: $latitude, format: .latitude)
                    .frame(width: 200)
                    .labelsHidden()
                    .padding()
                    .focused($isFocused)
            }

            LabeledContent("Longitude:") {
                TextField("Longitude", value: $longitude, format: .longitude)
                    .frame(width: 200)
                    .labelsHidden()
                    .padding()
                    .focused($isFocused)
            }

            LabeledContent("City:") {
                Text(image.metadata.city ?? "?")
                    .frame(width: 200, alignment: .leading)
            }

            LabeledContent("State:") {
                Text(image.metadata.state ?? "?")
                    .frame(width: 200, alignment: .leading)
            }

            LabeledContent("Country:") {
                Text(image.metadata.country ?? "?")
                    .frame(width: 200, alignment: .leading)
            }

            LabeledContent("Country Code:") {
                Text(image.metadata.countryCode ?? "?")
                    .frame(width: 200, alignment: .leading)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onExitCommand {
            loadCoordinates()
            isFocused = false
        }
        .onSubmit {
            if commitLocation() {
                isFocused = false
            }
        }
        .onChange(of: coordFormat) {
            loadCoordinates()
        }
        .onChange(of: isFocused) {
            store.send(.textfieldFocusChanged(isFocused), undoable: false)
            if !isFocused {
                commitLocation()
            }
        }
        .onChange(of: image.id) {
            // Switching images: lock in typed coordinates before
            // the fields reload with the new image's values.
            commitLocation()
            loadCoordinates()
        }
        .task(id: image.metadata.location) {
            commitLocation()
            loadCoordinates()
        }
        .onChange(of: latitude) { liveCommitLocation() }
        .onChange(of: longitude) { liveCommitLocation() }
        .onDisappear { closeUndoGroup() }
    }

    // set state variables from image location

    private func loadCoordinates() {
        if let location = image.metadata.location {
            latitude = location.latitude
            longitude = location.longitude
        } else {
            latitude = nil
            longitude = nil
        }
        loadedLatitude = latitude
        loadedLongitude = longitude
        editTarget = store.selection
        editImageID = image.id
    }

    // check that latitude and longitude are non-nil and in appropriate range

    private func validateLocation() -> Bool {
        if let latitude,
            let longitude,
            (0 ... 90).contains(latitude.magnitude),
            (0 ... 180).contains(longitude.magnitude)
        {
            return true
        }
        return false
    }

    // Send the typed coordinates if they form a complete, valid,
    // changed pair, addressed to the images they were typed for —
    // the event carries the target IDs explicitly, so a selection
    // change in the meantime can't redirect the coordinates onto
    // other images. Returns the images they were sent to. Sends
    // within one editing session form a single undo group.
    private func sendLocationChange() -> Set<ImageData.ID>? {
        guard validateLocation(),
              let latitude, let longitude,
              latitude != loadedLatitude || longitude != loadedLongitude
        else { return nil }
        let targets = editTarget.isEmpty ? store.selection : editTarget
        guard !targets.isEmpty else { return nil }
        if !undoGroupOpen {
            store.beginUndoGroup(description: "update location")
            undoGroupOpen = true
        }
        loadedLatitude = latitude
        loadedLongitude = longitude
        store.send(.locationChanged(targets,
                                    Coords(latitude: latitude,
                                           longitude: longitude)),
                   description: "update location")
        return targets
    }

    // Live transfer while typing: the table updates as soon as a
    // valid pair is typed. The reverse geocode is debounced so
    // it runs once the coordinates settle, not on every keystroke.
    private func liveCommitLocation() {
        if let targets = sendLocationChange() {
            scheduleGeocode(targets: targets)
        }
    }

    // Settle the edit (Return, focus loss, image switch): flush
    // any pending pair, close the undo group, and geocode right
    // away instead of waiting for the debounce.
    @discardableResult
    private func commitLocation() -> Bool {
        let hadSession = undoGroupOpen
        let targets = sendLocationChange()
        closeUndoGroup()
        geocodeTask?.cancel()
        geocodeTask = nil
        if let targets {
            geocodeNow(targets: targets)
            return true
        }
        if hadSession {
            let sessionTargets = editTarget.isEmpty
                ? store.selection : editTarget
            if !sessionTargets.isEmpty {
                geocodeNow(targets: sessionTargets)
            }
            return true
        }
        return false
    }

    private func scheduleGeocode(targets: Set<ImageData.ID>) {
        geocodeTask?.cancel()
        let anchorID = editImageID ?? image.id
        geocodeTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            let address =
            await ReverseLocationFinder.reverseGeocode(store: store,
                                                       id: anchorID)
            if let address {
                store.send(.addressChanged(targets, address),
                           undoable: false)
            }
        }
    }

    private func geocodeNow(targets: Set<ImageData.ID>) {
        let anchorID = editImageID ?? image.id
        Task {
            let address =
            await ReverseLocationFinder.reverseGeocode(store: store,
                                                       id: anchorID)
            if let address {
                store.send(.addressChanged(targets, address),
                           undoable: false)
            }
        }
    }

    private func closeUndoGroup() {
        if undoGroupOpen {
            store.endUndoGroup()
            undoGroupOpen = false
        }
    }
}

// I want my labels in line with the text field.

struct InlineLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            configuration.content
        }
    }
}

extension LabeledContentStyle where Self == InlineLabeledContentStyle {
    static var inline: InlineLabeledContentStyle { InlineLabeledContentStyle() }
}

#Preview {
    Text("""
       Look at **ImageInspectorView**
       to see a preview of this sub-view
       """)
        .multilineTextAlignment(.leading)
        .padding()

}
