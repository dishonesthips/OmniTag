import Coords
import ImageData
import Metadata
import OSLog
import SwiftUI
import UDF
internal import _LocationEssentials

extension GeoTagReducer {
    // Update camera fields and the XMP-dc:Subject film keyword for all
    // selected images.
    func update(_ state: inout GeoTagState,
                cameraMake: String?, cameraModel: String?,
                lensModel: String?, isoSpeedRatings: String?,
                filmStock: String?) {
        let ids = state.selection
        update(&state, ids: ids, cameraMake: cameraMake,
               cameraModel: cameraModel, lensModel: lensModel,
               isoSpeedRatings: isoSpeedRatings, filmStock: filmStock)
    }

    // Update camera fields and the XMP-dc:Subject film keyword for
    // the given images. Used when the target set was captured
    // earlier — e.g. inspector edits locked in after the selection
    // has already moved on to another image.
    func update(_ state: inout GeoTagState, ids: Set<ImageData.ID>,
                cameraMake: String?, cameraModel: String?,
                lensModel: String?, isoSpeedRatings: String?,
                filmStock: String?) {
        for id in ids {
            state[id].metadata.cameraMake = cameraMake
            state[id].metadata.cameraModel = cameraModel
            state[id].metadata.lensModel = lensModel
            state[id].metadata.isoSpeedRatings = isoSpeedRatings
            state[id].metadata.filmStock = filmStock
            if let pairedID = state[id].pairedID, state[pairedID].updatable {
                state[pairedID].metadata.cameraMake = cameraMake
                state[pairedID].metadata.cameraModel = cameraModel
                state[pairedID].metadata.lensModel = lensModel
                state[pairedID].metadata.isoSpeedRatings = isoSpeedRatings
                state[pairedID].metadata.filmStock = filmStock
            }
        }
        state.unsavedChanges = true
    }

    // Apply camera/film values to the selection without touching
    // the lens model — used by paste, whose payload carries no lens.
    func update(_ state: inout GeoTagState,
                cameraMake: String?, cameraModel: String?,
                isoSpeedRatings: String?, filmStock: String?) {
        for id in state.selection {
            state[id].metadata.cameraMake = cameraMake
            state[id].metadata.cameraModel = cameraModel
            state[id].metadata.isoSpeedRatings = isoSpeedRatings
            state[id].metadata.filmStock = filmStock
        }
        state.unsavedChanges = true
    }

    // Merge metadata loaded from a photo's original file into the
    // image, filling only the fields that are still missing. Film
    // fields filled this way are also copied into the original
    // (baseline) metadata, so they do not read as unsaved changes.
    func mergeLoadedMetadata(_ state: inout GeoTagState,
                             id: ImageData.ID, metadata: Metadata) {
        let cameraMakeWasMissing = state[id].metadata.cameraMake == nil
        let cameraModelWasMissing = state[id].metadata.cameraModel == nil
        let lensModelWasMissing = state[id].metadata.lensModel == nil
        let isoWasMissing = state[id].metadata.isoSpeedRatings == nil
        let filmStockWasMissing = state[id].metadata.filmStock == nil
        state[id].metadata.dateTimeCreated =
            state[id].metadata.dateTimeCreated ?? metadata.dateTimeCreated
        state[id].metadata.cameraMake =
            state[id].metadata.cameraMake ?? metadata.cameraMake
        state[id].metadata.cameraModel =
            state[id].metadata.cameraModel ?? metadata.cameraModel
        state[id].metadata.lensModel =
            state[id].metadata.lensModel ?? metadata.lensModel
        state[id].metadata.isoSpeedRatings =
            state[id].metadata.isoSpeedRatings ?? metadata.isoSpeedRatings
        state[id].metadata.filmStock =
            state[id].metadata.filmStock ?? metadata.filmStock
        state[id].metadata.location =
            state[id].metadata.location ?? metadata.location
        state[id].metadata.elevation =
            state[id].metadata.elevation ?? metadata.elevation
        if var baseline = state[id].original {
            if cameraMakeWasMissing {
                baseline.cameraMake = state[id].metadata.cameraMake
            }
            if cameraModelWasMissing {
                baseline.cameraModel = state[id].metadata.cameraModel
            }
            if lensModelWasMissing {
                baseline.lensModel = state[id].metadata.lensModel
            }
            if isoWasMissing {
                baseline.isoSpeedRatings =
                    state[id].metadata.isoSpeedRatings
            }
            if filmStockWasMissing {
                baseline.filmStock = state[id].metadata.filmStock
            }
            state[id].original = baseline
        }
        state.loadedFilmMetadata.insert(id)
    }

    func updateTiffNearestNeighbors(_ state: inout GeoTagState) {
        let images = state.imageData
        var changed = false

        for index in images.indices where images[index].fileType == "TIFF" {
            var nearest: ImageData?
            var distance = Int.max

            for candidate in images.indices where images[candidate].fileType != "TIFF" {
                let candidateDistance = abs(candidate - index)
                if candidateDistance < distance {
                    distance = candidateDistance
                    nearest = images[candidate]
                }
            }

            if let nearest,
               !nearest.metadata.timestamp.isEmpty {
                state.imageData[index].metadata.dateTimeCreated =
                    nearest.metadata.dateTimeCreated
                changed = true
            }
        }

        if changed {
            state.unsavedChanges = true
        }
    }

    // Fill only images without a location from the nearest already-located
    // image in album order. Existing locations are never overwritten.
    func updateLocationNearestNeighbors(_ state: inout GeoTagState) {
        let images = state.imageData
        var changed = false

        for index in images.indices where images[index].metadata.location == nil {
            var nearest: ImageData?
            var distance = Int.max

            for candidate in images.indices
                where images[candidate].metadata.location != nil {
                let candidateDistance = abs(candidate - index)
                if candidateDistance < distance {
                    distance = candidateDistance
                    nearest = images[candidate]
                }
            }

            if let nearest, let location = nearest.metadata.location {
                update(&state, id: images[index].id, location: location,
                       elevation: nearest.metadata.elevation)
                changed = true
            }
        }

        if changed {
            state.unsavedChanges = true
        }
    }

    // Update all selected images with the given coords

    func update(_ state: inout GeoTagState, coords: Coords) {
        let ids = state.selection
        update(&state, ids: ids, coords: coords)
    }

    // Update the given images with the given coords. Used when the
    // target set was captured earlier — e.g. inspector edits locked
    // in after the selection has already moved on.

    func update(_ state: inout GeoTagState, ids: Set<ImageData.ID>,
                coords: Coords) {
        for id in ids {
            update(&state, id: id, location: coords)
        }
    }

    // update a specific image with the given location

    func update(_ state: inout GeoTagState, id: ImageData.ID,
                location: Coords?, elevation: Double? = nil) {
        func logFormat(_ location: Coords?, elevation: Double?) -> String {
            var formatted = "none"
            if let location {
                formatted = "\(location.latitude), \(location.longitude)"
                if let elevation {
                    formatted += ", \(elevation)"
                }
            }
            return formatted
        }

        let logImg = state[id]
        logger.notice("""
            \(logImg.name, privacy: .public)
                \(logFormat(logImg.metadata.location,
                            elevation: logImg.metadata.elevation), privacy: .public) -> \
            \(logFormat(location, elevation: elevation), privacy: .public)
            """)

        state[id].metadata.location = location
        state[id].metadata.elevation = elevation
        if let pairedID = state[id].pairedID, state[pairedID].updatable {
            state[pairedID].metadata.location = location
            state[pairedID].metadata.elevation = elevation
        }
        state.unsavedChanges = true
    }

    // update a specific image with reverse geocode information

    func update(_ state: inout GeoTagState, selected: Set<ImageData.ID>,
                address: Place) {
        for id in selected {
            state[id].metadata.city = address.city
            state[id].metadata.state = address.state
            state[id].metadata.country = address.country
            state[id].metadata.countryCode = address.countryCode
            if let pairedID = state[id].pairedID, state[pairedID].updatable {
                state[pairedID].metadata.city = address.city
                state[pairedID].metadata.state = address.state
                state[pairedID].metadata.country = address.country
                state[pairedID].metadata.countryCode = address.countryCode
            }
        }
    }

    // adjust the timestamp of all selected images by the given amount
    // If the image did not have an original timestamp assign the given date

    func update(_ state: inout GeoTagState,
                date: Date, adjustment: TimeInterval) {
        for id in state.selection {
            let updatedDate: Date
            if state[id].metadata.dateTimeCreated == nil {
                updatedDate = date
            } else {
                let originalDate = state[id].metadata.date(timeZone: state.timeZone)
                updatedDate = Date(timeInterval: adjustment,
                                   since: originalDate)
            }
            state[id].metadata.dateTimeCreated =
                Metadata.timestamp(from: updatedDate)
        }
        state.unsavedChanges = true
    }
}
