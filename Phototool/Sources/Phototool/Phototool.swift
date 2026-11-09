import Exiftool
import Metadata
import OSLog
import Photos
import PhotosUI
import SwiftUI
import ImageIO

public struct Phototool {
    public static func metadata(from item: PhotosPickerItem, asset: PHAsset?) -> Metadata {
        var metadata = Metadata(source: .photos(item, asset))
        if let asset {
            metadata.dateTimeCreated = if let date = asset.creationDate {
                Metadata.timestamp(from: date)
            } else {
                nil
            }
            metadata.location = asset.location?.coordinate
            metadata.elevation = asset.location?.altitude
        }
        // no city/state/country in a PHAsset
        return metadata
    }

    /// Read camera metadata for a Photos item. When the asset's
    /// original is on disk it is parsed in place (see the
    /// originalURL variant); otherwise the original bytes are
    /// fetched through Photos.
    public static func metadata(fromPhotoItem item: PhotosPickerItem,
                                asset: PHAsset?) async -> Metadata {
        let url = asset.flatMap { Self.originalFileURL(for: $0) }
        return await metadata(fromPhotoItem: item, asset: asset,
                              originalURL: url)
    }

    /// Read camera metadata for a Photos item whose on-disk
    /// original the caller already resolved (on the main actor —
    /// PHAsset file-URL access is not safe from concurrent worker
    /// threads). A non-nil originalURL is parsed directly with
    /// ImageIO + ExifTool: no Photos data transfer and no temporary
    /// copy of a multi-megabyte original. A nil originalURL falls
    /// back to fetching the original bytes through Photos; in that
    /// case pass a pre-resolved resource too, so the fetch never
    /// queries the asset from a worker thread.
    public static func metadata(fromPhotoItem item: PhotosPickerItem,
                                asset: PHAsset?,
                                originalURL: URL?,
                                resource: PHAssetResource? = nil) async -> Metadata {
        guard let originalURL else {
            return await metadataFromData(fromPhotoItem: item, asset: asset,
                                          resource: resource)
        }
        return metadataByParsingFile(at: originalURL,
                                     into: Self.metadata(from: item,
                                                         asset: asset))
    }

    /// Parse the image file at the given URL in place — ImageIO
    /// properties plus an ExifTool read of the file — and merge
    /// the results into the given base metadata. Every input is
    /// Sendable and no PHAsset is touched, so this is safe to call
    /// from concurrent worker threads; it is the worker half of
    /// metadata(fromPhotoItem:asset:originalURL:resource:), whose
    /// base metadata must be built on the main actor.
    public static func metadataByParsingFile(at url: URL,
                                             into base: Metadata) -> Metadata {
        var metadata = base
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [String: Any] {
            applyImageIOProperties(properties, to: &metadata)
        }
        let parsed = Exiftool.helper.metadata(from: nil,
                                              primaryURL: url,
                                              overriding: nil,
                                              useGpsStatus: false)
        mergeExifTool(parsed, into: &metadata)
        return metadata
    }

    private static func applyImageIOProperties(_ properties: [String: Any],
                                               to metadata: inout Metadata) {
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String]
            as? [String: Any] {
            metadata.cameraMake = tiff[kCGImagePropertyTIFFMake as String] as? String
            metadata.cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
        }
        if let exif = properties[kCGImagePropertyExifDictionary as String]
            as? [String: Any] {
            metadata.lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? NSNumber {
                metadata.isoSpeedRatings = iso.stringValue
            } else if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String]
                        as? [NSNumber] {
                metadata.isoSpeedRatings = isos.map(\.stringValue).joined(separator: ", ")
            }
        }
    }

    private static func mergeExifTool(_ parsed: Metadata,
                                      into metadata: inout Metadata) {
        metadata.cameraMake = parsed.cameraMake ?? metadata.cameraMake
        metadata.cameraModel = parsed.cameraModel ?? metadata.cameraModel
        metadata.lensModel = parsed.lensModel ?? metadata.lensModel
        metadata.isoSpeedRatings = parsed.isoSpeedRatings ?? metadata.isoSpeedRatings
        metadata.filmStock = parsed.filmStock
    }

    /// Read camera metadata from the original bytes returned by PhotosPicker.
    /// PHAsset exposes date and location, but not the embedded EXIF fields.
    private static func metadataFromData(fromPhotoItem item: PhotosPickerItem,
                                asset: PHAsset?,
                                resource: PHAssetResource?) async -> Metadata {
        var metadata = Self.metadata(from: item, asset: asset)
        let data = if let asset {
            if let resource {
                await originalData(for: resource)
            } else {
                await originalData(for: asset)
            }
        } else {
            try? await item.loadTransferable(type: Data.self)
        }
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any] else {
            return metadata
        }

        applyImageIOProperties(properties, to: &metadata)

        // ExifTool handles RAW makers' metadata and embedded XMP more
        // completely than ImageIO, especially for Nikon NEF files.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: Self.name(from: asset))
                .pathExtension.isEmpty ? "dat" : URL(fileURLWithPath: Self.name(from: asset)).pathExtension)
        if (try? data.write(to: temporaryURL)) != nil {
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let parsed = Exiftool.helper.metadata(from: nil,
                                                  primaryURL: temporaryURL,
                                                  overriding: nil,
                                                  useGpsStatus: false)
            mergeExifTool(parsed, into: &metadata)
        }
        return metadata
    }

    /// The resource holding the asset's original image data. RAW and
    /// TIFF resources are preferred when an asset has several.
    public static func originalResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: {
            $0.originalFilename.lowercased().hasSuffix(".nef") ||
            $0.originalFilename.lowercased().hasSuffix(".dng") ||
            $0.originalFilename.lowercased().hasSuffix(".rw2") ||
            $0.originalFilename.lowercased().hasSuffix(".tif") ||
            $0.originalFilename.lowercased().hasSuffix(".tiff")
        }) ?? resources.first
    }

    /// The on-disk URL of the asset's original file inside the Photos
    /// library bundle.
    ///
    /// There is no public API for this. PHAssetResource does not
    /// respond to the KVC "fileURL" key on macOS 27, but PHAsset
    /// itself responds to "mainFileURL" and
    /// returns the authoritative URL, so that is used first (with an
    /// existence check — the URL is also returned for originals that
    /// have not been downloaded to this Mac). As a fallback the path
    /// is constructed from the library layout: originals live at
    /// `<library>/originals/<first UUID char>/<UUID>.<ext>`, where the
    /// UUID is the first component of the asset's localIdentifier and
    /// the library is the default
    /// ~/Pictures/Photos Library.photoslibrary. That construction is
    /// unreliable in practice (it does not resolve every asset),
    /// which is why it is only the fallback.
    ///
    /// Used by the in-place EXIF update path and by the
    /// film-metadata read path (the originalURL variant of
    /// metadata(fromPhotoItem:asset:originalURL:)). Writing to this
    /// file modifies the library's original in place, bypassing the
    /// Photos database: Photos may keep showing the camera info it
    /// cached at import time, and a sandboxed build
    /// cannot write inside the library bundle at all (its home
    /// directory is the app container, so even locating the file
    /// this way fails there).
    public static func originalFileURL(for asset: PHAsset) -> URL? {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PhotoTool",
                            category: "Phototool")
        if asset.responds(to: NSSelectorFromString("mainFileURL")),
           let url = asset.value(forKey: "mainFileURL") as? URL,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let resource = originalResource(for: asset) else {
            logger.error("originalFileURL: asset has no resources")
            return nil
        }
        if resource.responds(to: NSSelectorFromString("fileURL")),
           let url = resource.value(forKey: "fileURL") as? URL,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let url = constructedOriginalURL(for: asset,
                                               resource: resource) else {
            logger.error("originalFileURL: could not locate original file on disk")
            return nil
        }
        logger.info("originalFileURL: constructed \(url.path, privacy: .public)")
        return url
    }

    /// Construct the on-disk path of an asset's original file from
    /// the Photos library layout (see originalFileURL). Verifies the
    /// file exists before returning it.
    private static func constructedOriginalURL(for asset: PHAsset,
                                               resource: PHAssetResource) -> URL? {
        let fileManager = FileManager.default
        guard let uuid = asset.localIdentifier
            .split(separator: "/").first.map(String.init),
              let firstChar = uuid.first else {
            return nil
        }
        let folder = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary",
                                    isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(String(firstChar), isDirectory: true)
        // Exact name first: <UUID>.<original extension> (either case).
        let ext = (resource.originalFilename as NSString).pathExtension
        if !ext.isEmpty {
            for candidate in ["\(uuid).\(ext)",
                              "\(uuid).\(ext.lowercased())"] {
                let url = folder.appendingPathComponent(candidate)
                if fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        // Otherwise scan the (small) per-character folder for the UUID.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first {
            $0.deletingPathExtension().lastPathComponent.lowercased() ==
                uuid.lowercased()
        }
    }

    /// Download the original resource for a single asset. This is intentionally
    /// public so export workflows can fetch only the assets the user selected.
    public static func originalData(for asset: PHAsset) async -> Data? {
        guard let resource = originalResource(for: asset) else {
            return nil
        }
        return await originalData(for: resource)
    }

    /// Download a pre-resolved resource. Safe to call from any
    /// thread: it never queries the asset itself.
    public static func originalData(for resource: PHAssetResource) async -> Data? {
        return await withCheckedContinuation { continuation in
            let accumulator = DataAccumulator()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in accumulator.append(data) },
                completionHandler: { error in
                    continuation.resume(returning: error == nil ? accumulator.data : nil)
                })
        }
    }

    private final class DataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func append(_ data: Data) {
            lock.lock()
            value.append(data)
            lock.unlock()
        }
    }

    private final class CreationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return flag
            }
            set {
                lock.lock()
                flag = newValue
                lock.unlock()
            }
        }
    }

    /// Bookkeeping for a PHImageManager thumbnail request. The
    /// result handler can fire several times and the surrounding
    /// task can be cancelled at any point; this box guarantees the
    /// continuation is resumed exactly once, and that cancellation
    /// cancels the Photos request.
    private final class ThumbnailRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHImageRequestID = PHInvalidImageRequestID
        private var continuation: CheckedContinuation<Image?, Never>?
        private var finished = false

        func begin(_ continuation: CheckedContinuation<Image?, Never>) {
            lock.lock()
            if finished {
                // the task was cancelled before the request started
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func setRequestID(_ id: PHImageRequestID) {
            lock.lock()
            requestID = id
            let alreadyFinished = finished
            lock.unlock()
            if alreadyFinished {
                PHImageManager.default().cancelImageRequest(id)
            }
        }

        func complete(_ image: Image?) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: image)
        }

        func cancel() {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let id = requestID
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            if id != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(id)
            }
            continuation?.resume(returning: nil)
        }
    }

    // return an image from the photos library

    public static func image(from item: PhotosPickerItem) async -> Image? {
        // Data -> NSImage -> Image dance needed to get proper orientation of
        // HEIC images.
        if let data = try? await item.loadTransferable(type: Data.self),
            let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        let name: String
        if let id = item.itemIdentifier {
            let asset = await Self.assets(for: id)
            name = Self.name(from: asset)
        } else {
            name = "unknown item"
        }
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "PhotoTool",
               category: "Phototool")
            .error("Can not extract image for item \(name, privacy: .public)")
        return nil
    }

    /// Return a small preview image for a Photos asset, rendered by
    /// Photos itself at the requested size. Unlike image(from:) this
    /// never loads the full original data — important for large RAW
    /// files (e.g. RW2), where loadTransferable + NSImage(data:) pays
    /// for a full-size transfer and decode just to show a small
    /// preview. PHImageManager serves a cached derivative instead,
    /// and the request is cancelled when the caller's task is
    /// cancelled (e.g. the selection moved on to another photo).
    public static func thumbnailImage(for asset: PHAsset,
                                      maxPixelSize: CGFloat) async -> Image? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let targetSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let box = ThumbnailRequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.begin(continuation)
                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options) { nsImage, info in
                        // Opportunistic delivery may report degraded
                        // (placeholder) images first; a final image
                        // follows, so only complete on non-degraded
                        // results. A cancelled or failed request also
                        // lands here, with a nil image.
                        let degraded = (info?[PHImageResultIsDegradedKey]
                                        as? Bool) ?? false
                        if degraded { return }
                        box.complete(nsImage.map { Image(nsImage: $0) })
                    }
                box.setRequestID(requestID)
            }
        } onCancel: {
            box.cancel()
        }
    }

    public static func assets(for id: String) async -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                         options: nil)
        if let asset = result.firstObject {
            return asset
        }
        return nil
    }

    public static func name(from asset: PHAsset?) -> String {
        if let asset {
            let assetResources = PHAssetResource.assetResources(for: asset)
            return assetResources.first?.originalFilename ?? "unknown"
        }
        return "unknown"
    }

    public static func update(timestamp: Date? = nil,
                              location: CLLocation?,
                              for asset: PHAsset) async -> Bool {
        let library = PHPhotoLibrary.shared()
        do {
            try await library.performChanges {
                let assetChangeReqeust = PHAssetChangeRequest(for: asset)
                // timestamps can only be changed, not deleted
                if let timestamp {
                    assetChangeReqeust.creationDate = timestamp
                }
                assetChangeReqeust.location = location
            }
            return true
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "PhotoTool",
                   category: "Phototool")
                .error("update: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Apply timestamp/location updates to many assets in a single
    /// Photos library transaction, instead of one performChanges call
    /// per asset. Returns one result per update, in the order given.
    /// If the batched transaction fails, falls back to per-asset
    /// updates so one bad asset cannot fail the whole batch (and the
    /// per-asset results still identify which ones failed).
    public static func update(
        _ updates: [(asset: PHAsset, timestamp: Date?, location: CLLocation?)]
    ) async -> [Bool] {
        guard !updates.isEmpty else { return [] }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for entry in updates {
                    let assetChangeRequest =
                        PHAssetChangeRequest(for: entry.asset)
                    // timestamps can only be changed, not deleted
                    if let timestamp = entry.timestamp {
                        assetChangeRequest.creationDate = timestamp
                    }
                    assetChangeRequest.location = entry.location
                }
            }
            return [Bool](repeating: true, count: updates.count)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "PhotoTool",
                   category: "Phototool")
                .error("update(batch): \(error.localizedDescription, privacy: .public); falling back to per-asset updates")
            var results: [Bool] = []
            results.reserveCapacity(updates.count)
            for entry in updates {
                results.append(await update(timestamp: entry.timestamp,
                                            location: entry.location,
                                            for: entry.asset))
            }
            return results
        }
    }

    /// Add a local image file to the Photos library as a new asset.
    /// The file must already contain any metadata that should be imported.
    public static func addImage(at url: URL) async -> Bool {
        // creationRequestForAssetFromImage returns nil when Photos can
        // not create an asset from the file. performChanges does not
        // throw in that case, so track the result explicitly instead of
        // reporting success for an import that never happened.
        let created = CreationFlag()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                created.value = PHAssetChangeRequest
                    .creationRequestForAssetFromImage(atFileURL: url) != nil
            }
            return created.value
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "PhotoTool",
                   category: "Phototool")
                .error("addImage: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
