import AppKit
import Coords
import Foundation
import GpxTrackLog
import ImageData
import Metadata
import SwiftUI

// events that trigger a change of state

enum GeoTagEvent: Equatable {
    case addImage(ImageData)
    case addImages([ImageData])
    case addressChanged(Set<ImageData.ID>, Place)
    case cameraFilmChanged(Set<ImageData.ID>, String?, String?, String?, String?, String?)
    case backupFolderSizeCheck
    case backupURLChanged(URL?)
    case badGpxFile(String)
    case catchUnexpectedError(String?, String?)
    case changeTimeZone
    case clearImagesRequest
    case clearPlaces
    case clearUniqueURLs
    case deleteRequest
    case discardChangesRequest
    case discardTracksRequest
    case duplicateImages
    case findInMap(Bool)
    case finishedAddingTracks
    case goodGpxFile(String)
    case gpxLoadViewClosed
    case imageSaved(ImageData.ID, Metadata)
    case initBackupURL
    case noBackupNotice
    case initPlaces([Place])
    case linkPairedImages(Bool)
    case locationChanged(Set<ImageData.ID>, Coords)
    case locationFromTrack([LocationHelper.LocationById])
    case locationNearestNeighborRequest
    case mainWindowChange(NSWindow?)
    case mostSelectedChanged(ImageData.ID)
    case newThumbnail(Image)
    case newTimestamp(Date, TimeInterval)
    case omniTagModeChanged(OmniTagMode)
    case openCommand
    case openFiles([URL])
    case pasteRequest
    case placeSelection(Place)
    case photosMetadataLoaded(ImageData.ID, Metadata)
    case quitRequested
    case readTrackLog(String, GpxTrackLog?)
    case removeOldFiles
    case saveComplete(SaveHelper.SaveStatus)
    case saveRequest
    case searchActiveChanged(Bool)
    case searchTextChanged(String)
    case selectAllRequest
    case selectionChanged(Set<ImageData.ID>)
    case sheetDismissed
    case sidecarCreated(ImageData.ID)
    case sortOrderChanged([KeyPathComparator<ImageData>])
    case sortUsingCurrentComparator
    case terminateRequest
    case tiffNearestNeighborRequest
    case textfieldFocusChanged(Bool)
    case timeZoneChanged(TimeZone)
    case toggleLogWindow
}

// A description for each event

extension GeoTagEvent: CustomStringConvertible {
    var description: String {
        switch self {
        case .addImage: "addImage"
        case .addImages: "addImages"
        case .addressChanged: "addressChanged"
        case .cameraFilmChanged: "cameraFilmChanged"
        case .backupFolderSizeCheck: "backupFolderSizeCheck"
        case .backupURLChanged: "backupURLChanged"
        case .badGpxFile: "badGpxFile"
        case .catchUnexpectedError: "catchUnexpectedError"
        case .changeTimeZone: "changeTimeZone"
        case .clearImagesRequest: "clearImagesRequest"
        case .clearPlaces: "clearPlaces"
        case .clearUniqueURLs: "clearUniqueURLs"
        case .deleteRequest: "deleteRequest"
        case .discardChangesRequest: "discardChangesRequest"
        case .discardTracksRequest: "discardTracksRequest"
        case .duplicateImages: "duplicateImages"
        case .findInMap: "findInMap"
        case .finishedAddingTracks: "finishedAddingTracks"
        case .goodGpxFile: "goodGpxFile"
        case .gpxLoadViewClosed: "gpxLoadViewClosed"
        case .imageSaved: "imageSaved"
        case .initBackupURL: "initBackupURL"
        case .noBackupNotice: "noBackupNotice"
        case .initPlaces: "initPlaces"
        case .linkPairedImages: "linkPairedImages"
        case .locationChanged: "locationChanged"
        case .locationFromTrack: "locationFromTrack"
        case .locationNearestNeighborRequest: "locationNearestNeighborRequest"
        case .mainWindowChange: "mainWindowChange"
        case .mostSelectedChanged: "mostSelectedChanged"
        case .newThumbnail: "newThumbnail"
        case .newTimestamp: "newTimestamp"
        case .omniTagModeChanged: "omniTagModeChanged"
        case .openCommand: "openCommand"
        case .openFiles: "openFiles"
        case .pasteRequest: "pasteRequest"
        case .placeSelection: "placeSelection"
        case .photosMetadataLoaded: "photosMetadataLoaded"
        case .quitRequested: "quitRequested"
        case .readTrackLog: "readTrackLog"
        case .removeOldFiles: "removeOldFiles"
        case .saveComplete: "saveComplete"
        case .saveRequest: "saveReqest"
        case .searchActiveChanged: "searchActiveChanged"
        case .searchTextChanged: "searchTextChanged"
        case .selectAllRequest: "selectAllRequest"
        case .selectionChanged: "selectionChanged"
        case .sheetDismissed: "sheetDismissed"
        case .sidecarCreated: "sidecarCreated"
        case .sortOrderChanged: "sortOrderChanged"
        case .sortUsingCurrentComparator: "sortUsingCurrentComparator"
        case .terminateRequest: "terminateRequest"
        case .tiffNearestNeighborRequest: "tiffNearestNeighborRequest"
        case .textfieldFocusChanged: "textfieldFocusChanged"
        case .timeZoneChanged: "timeZoneChanged"
        case .toggleLogWindow: "toggleLogWindow"
        }
    }
}
