import AppKit
import ImageData
import Metadata

extension GeoTagReducer {
    func paste(_ state: inout GeoTagState) {
        let pb = NSPasteboard.general
        guard let pasteVal = pb.string(forType: .string) else { return }

        switch state.omniTagMode {
        case .location:
            if let locn = ImageData.decodeStringRep(value: pasteVal) {
                for id in state.selection {
                    update(&state, id: id, location: locn.0, elevation: locn.1)
                }
            }
        case .time:
            state.selection.forEach { id in
                state[id].metadata.dateTimeCreated = pasteVal
            }
            state.unsavedChanges = true
        case .film:
            guard let data = pasteVal.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(FilmClipboardPayload.self,
                                                          from: data) else { return }
            update(&state, cameraMake: payload.make,
                   cameraModel: payload.model,
                   isoSpeedRatings: payload.iso,
                   filmStock: payload.filmStock)
        }
    }

    // Delete clears the metadata of the current mode, mirroring how
    // paste(_:) applies values per mode: location (and its address
    // fields) in location mode, the timestamp in time mode, and the
    // camera/film fields in film mode.
    func delete(_ state: inout GeoTagState) {
        switch state.omniTagMode {
        case .location:
            for id in state.selection
                where state[id].metadata.location != nil {
                update(&state, id: id, location: nil)
                state[id].metadata.city = nil
                state[id].metadata.state = nil
                state[id].metadata.country = nil
                state[id].metadata.countryCode = nil
                if let pairedID = state[id].pairedID, state[pairedID].updatable {
                    state[pairedID].metadata.city = nil
                    state[pairedID].metadata.state = nil
                    state[pairedID].metadata.country = nil
                    state[pairedID].metadata.countryCode = nil
                }
            }
        case .time:
            for id in state.selection
                where state[id].metadata.dateTimeCreated != nil {
                state[id].metadata.dateTimeCreated = nil
                state.unsavedChanges = true
            }
        case .film:
            update(&state, cameraMake: nil, cameraModel: nil,
                   lensModel: nil, isoSpeedRatings: nil, filmStock: nil)
        }
    }

    func selectAll(_ state: inout GeoTagState) {
        let selection = Set(state.imageData.map { $0.id })
        selectionChanged(&state, selection: selection)
    }
}

struct FilmClipboardPayload: Codable {
    let make: String?
    let model: String?
    let iso: String?
    let filmStock: String?
}
