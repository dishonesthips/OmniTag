import Exiftool
import ImageData
import Imagetool
import Metadata
import OSLog
import Photos
import Phototool
import SwiftUI
import UDF

@MainActor
enum SaveHelper {
    enum SaveStatus {
        case saveOK                     // All changes saved
        case saveError                  // Save issue, tell user
        case saveErrorSupressWarning    // Save issue, user knows
    }

    @discardableResult
    static func save(_ store: GeoTagStore) -> Task<Void, Never> {
        // capture the data needed to update images
        let libraryImages =
            Dictionary(uniqueKeysWithValues: store.libraryImages.map {
                (store.imageData[$0].id, store.imageData[$0].metadata)
            })
        // True when any of the five camera/film fields differ from
        // the image's original (loaded) metadata.
        func filmFieldsChanged(_ image: ImageData) -> Bool {
            image.metadata.cameraMake != image.original?.cameraMake ||
            image.metadata.cameraModel != image.original?.cameraModel ||
            image.metadata.lensModel != image.original?.lensModel ||
            image.metadata.isoSpeedRatings != image.original?.isoSpeedRatings ||
            image.metadata.filmStock != image.original?.filmStock
        }
        // store.libraryImages holds indices into imageData (see
        // Reducer+saveItems.save), but saveToLibrary looks images up
        // by ImageData.ID, so this set is built from the images'
        // real IDs.
        // Note: this must stay a `let` with explicit generic types.
        // A mutated `var` set trips Swift 6 region isolation when it is
        // passed to saveToLibrary inside the Task below ("sending risks
        // causing data races"), and an unannotated Set(compactMap)
        // leaves the compiler unable to infer the element type.
        let libraryFilmMetadataIDs: Set<ImageData.ID> = Set(
            store.libraryImages.compactMap { index -> ImageData.ID? in
                let image = store.imageData[index]
                return filmFieldsChanged(image) ? image.id : nil
            })
        let fileImages =
            Dictionary(uniqueKeysWithValues: store.fileImages.map {
                (store.imageData[$0].id, store.imageData[$0].metadata)
            })
        let xmpImages =
            Dictionary(uniqueKeysWithValues: store.xmpImages.map {
                (store.imageData[$0].id, store.imageData[$0].metadata)
            })
        // Do the save in the background, report when done.
        let task = Task {
            async let libUpdated = saveToLibrary(
                store, libraryImages, filmMetadataIDs: libraryFilmMetadataIDs)
            async let imgUpdated = saveToImage(store, fileImages)
            async let xmpUpdated = saveToImage(store, xmpImages, xmp: true)

            let status = await [libUpdated, imgUpdated, xmpUpdated]

            let sendStatus: SaveStatus =
                if status.allSatisfy({ $0 == .saveOK }) {
                    .saveOK
                } else if status.contains(.saveErrorSupressWarning) {
                    .saveErrorSupressWarning
                } else {
                    .saveError
                }
            store.send(.saveComplete(sendStatus), undoable: false)
        }
        return task
    }

    /// Export selected Photos assets as ordinary files with the current
    /// camera/film metadata written into EXIF/XMP. Photos originals remain
    /// untouched; only selected assets are downloaded.
    static func exportSelectedPhotos(_ store: GeoTagStore) async {
        let selected = store.selection.compactMap { id -> (ImageData.ID, Metadata, PHAsset)? in
            let metadata = store[id].metadata
            guard case .photos(_, let asset) = metadata.source, let asset else {
                return nil
            }
            return (id, metadata, asset)
        }
        guard !selected.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        _ = folder.startAccessingSecurityScopedResource()
        defer { folder.stopAccessingSecurityScopedResource() }

        for (_, metadata, asset) in selected {
            _ = await withTaggedTemporaryCopy(metadata: metadata,
                                              asset: asset,
                                              timeZone: store.timeZone) { temporaryURL in
                let outputURL = uniqueURL(in: folder,
                                          named: Phototool.name(from: asset))
                try FileManager.default.copyItem(at: temporaryURL,
                                                 to: outputURL)
                return true
            }
        }
    }

    /// Create metadata-tagged copies of selected Photos assets and import
    /// those copies back into Photos. The original assets are untouched.
    static func addTaggedCopiesToPhotos(_ store: GeoTagStore) async {
        let selected = store.selection.compactMap { id -> (Metadata, PHAsset)? in
            let metadata = store[id].metadata
            guard case .photos(_, let asset) = metadata.source, let asset else {
                return nil
            }
            return (metadata, asset)
        }
        guard !selected.isEmpty else { return }

        var added = 0
        for (metadata, asset) in selected {
            if await addTaggedCopy(metadata: metadata, asset: asset,
                                   timeZone: store.timeZone) {
                added += 1
            }
        }

        let message = added == selected.count
            ? "Added \(added) tagged cop\(added == 1 ? "y" : "ies") to Photos."
            : "Added \(added) of \(selected.count) tagged copies to Photos."
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Photos import complete"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Download an asset's original data to a temporary file, embed
    /// the given metadata into it with ExifTool, and hand the file to
    /// `body`. The temporary file is removed before returning.
    /// Returns whatever `body` returns, or false when the original
    /// could not be downloaded or written.
    private static func withTaggedTemporaryCopy(
        metadata: Metadata, asset: PHAsset, timeZone: TimeZone?,
        body: (URL) async throws -> Bool
    ) async -> Bool {
        guard let data = await Phototool.originalData(for: asset) else {
            return false
        }

        let originalName = Phototool.name(from: asset)
        let extensionName = URL(fileURLWithPath: originalName).pathExtension
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(extensionName.isEmpty ? "dat" : extensionName)

        do {
            try data.write(to: temporaryURL)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try await Exiftool.helper.update(image: temporaryURL,
                                             from: metadata,
                                             timeZone: timeZone)
            return try await body(temporaryURL)
        } catch {
            return false
        }
    }

    private static func addTaggedCopy(metadata: Metadata,
                                      asset: PHAsset,
                                      timeZone: TimeZone?) async -> Bool {
        await withTaggedTemporaryCopy(metadata: metadata,
                                      asset: asset,
                                      timeZone: timeZone) { temporaryURL in
            await Phototool.addImage(at: temporaryURL)
        }
    }

    /// Write camera/film metadata into a Photos asset's original file,
    /// in place inside the library bundle, using ExifTool, rather
    /// than importing a tagged copy on save. (The tagged-copy path
    /// remains available
    /// as the explicit "Add tagged copies to Photos…" menu action.)
    ///
    /// Safety rules, in order:
    /// 1. A pristine backup copy of the original file is made first —
    ///    in the backup folder when one is configured, otherwise in
    ///    Application Support/OmniTag/InPlaceBackups. No backup, no
    ///    write.
    /// 2. ExifTool rewrites the file in place.
    /// 3. The file is re-read and the film fields are verified against
    ///    what was intended. On any mismatch the backup is restored
    ///    over the file and the save reports an error.
    ///
    /// The Photos database is not updated. For edited assets the
    /// rendered JPEG inside the library is updated as well (see
    /// updateRenderInPlace), since viewers read camera info from
    /// the render for edited assets. The file URL is resolved by
    /// the caller on the main actor (see saveToLibrary) because
    /// the PHAsset access it
    /// requires is not safe from concurrent workers; an original
    /// that has not been downloaded to this Mac, or an unwritable
    /// file (e.g. a sandboxed build), fails the save instead of
    /// guessing.
    nonisolated private static func updateOriginalInPlace(metadata: Metadata,
                                              fileURL: URL,
                                              backupURL: URL?,
                                              timeZone: TimeZone?,
                                              hasRender: Bool) async -> Bool {
        let logger = Logger(subsystem: "org.snafu.GeoTag",
                            category: "SaveHelper")
        guard FileManager.default.isWritableFile(atPath: fileURL.path) else {
            logger.error("In-place update: file not writable: \(fileURL.path, privacy: .public)")
            return false
        }

        let backupFileURL: URL
        do {
            backupFileURL = try makeInPlaceBackup(of: fileURL,
                                                  backupURL: backupURL)
        } catch {
            logger.error("In-place update: backup failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        logger.info("In-place update: backed up to \(backupFileURL.path, privacy: .public)")

        do {
            try await Exiftool.helper.update(image: fileURL,
                                             from: metadata,
                                             timeZone: timeZone)
        } catch {
            logger.error("In-place update: ExifTool write failed: \(error.localizedDescription, privacy: .public)")
            restoreInPlaceBackup(backupFileURL, to: fileURL)
            return false
        }

        let written = Exiftool.helper.metadata(from: nil,
                                               primaryURL: fileURL,
                                               useGpsStatus: false)
        guard filmFieldsMatch(written, metadata) else {
            logger.error("In-place update: verify mismatch for \(fileURL.path, privacy: .public) — written \(filmFieldSummary(written), privacy: .public) vs intended \(filmFieldSummary(metadata), privacy: .public)")
            restoreInPlaceBackup(backupFileURL, to: fileURL)
            return false
        }
        logger.info("In-place update: wrote film metadata to \(fileURL.path, privacy: .public)")
        if hasRender {
            await updateRenderInPlace(metadata: metadata,
                                      originalURL: fileURL,
                                      backupURL: backupURL,
                                      logger: logger)
        }
        return true
    }

    /// Write the film fields into the rendered JPEG Photos keeps
    /// for an edited asset. Viewers read camera info from the
    /// render for edited assets, so the render is updated along
    /// with the original. Same discipline as
    /// the original: backup first, verify after, restore on
    /// mismatch. A render problem is logged but never fails the
    /// save — the original is the canonical file, and Photos will
    /// regenerate the render from it in time.
    nonisolated private static func updateRenderInPlace(
        metadata: Metadata, originalURL: URL, backupURL: URL?,
        logger: Logger) async {
        guard let renderURL = locateRender(forOriginal: originalURL) else {
            logger.error("In-place update: asset has a render resource but no render file was found for \(originalURL.path, privacy: .public)")
            return
        }
        guard FileManager.default.isWritableFile(atPath: renderURL.path) else {
            logger.error("In-place update: render not writable: \(renderURL.path, privacy: .public)")
            return
        }
        let backupFileURL: URL
        do {
            backupFileURL = try makeInPlaceBackup(of: renderURL,
                                                  backupURL: backupURL)
        } catch {
            logger.error("In-place update: render backup failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try await Exiftool.helper.updateFilmMetadata(image: renderURL,
                                                         from: metadata)
        } catch {
            logger.error("In-place update: render write failed: \(error.localizedDescription, privacy: .public)")
            restoreInPlaceBackup(backupFileURL, to: renderURL)
            return
        }
        let written = Exiftool.helper.metadata(from: nil,
                                               primaryURL: renderURL,
                                               useGpsStatus: false)
        guard filmFieldsMatch(written, metadata) else {
            logger.error("In-place update: render verify mismatch for \(renderURL.path, privacy: .public)")
            restoreInPlaceBackup(backupFileURL, to: renderURL)
            return
        }
        logger.info("In-place update: wrote film metadata to render \(renderURL.path, privacy: .public)")
    }

    /// Find the rendered JPEG for an edited library asset. The
    /// render's file name (or its folder's name) carries the
    /// asset's UUID, like the original's name, with a JPEG
    /// extension; it sits either beside the original or somewhere
    /// under the bundle's resources folder. Pure file search —
    /// safe on worker threads, and only called for assets known
    /// to have a render, so unedited assets never pay for it.
    nonisolated private static func locateRender(
        forOriginal originalURL: URL) -> URL? {
        let fileManager = FileManager.default
        let uuid = originalURL.deletingPathExtension().lastPathComponent
        func isRender(_ url: URL) -> Bool {
            guard url != originalURL else { return false }
            let ext = url.pathExtension.lowercased()
            guard ext == "jpeg" || ext == "jpg" else { return false }
            return url.lastPathComponent.contains(uuid) ||
                url.deletingLastPathComponent()
                    .lastPathComponent.contains(uuid)
        }
        let originalsDir = originalURL.deletingLastPathComponent()
        if let siblings = try? fileManager.contentsOfDirectory(
            at: originalsDir, includingPropertiesForKeys: nil),
           let hit = siblings.first(where: isRender) {
            return hit
        }
        let bundle = originalsDir.deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesDir = bundle.appendingPathComponent("resources")
        if let walker = fileManager.enumerator(
            at: resourcesDir, includingPropertiesForKeys: nil) {
            while let item = walker.nextObject() as? URL {
                if isRender(item) { return item }
            }
        }
        return nil
    }

    // The five film fields as one slash-separated string, for log
    // messages: make/model/lens/iso/film stock.
    nonisolated private static func filmFieldSummary(_ metadata: Metadata) -> String {
        [metadata.cameraMake, metadata.cameraModel, metadata.lensModel,
         metadata.isoSpeedRatings, metadata.filmStock]
            .map { $0 ?? "nil" }
            .joined(separator: "/")
    }

    nonisolated private static func filmFieldsMatch(_ written: Metadata,
                                        _ intended: Metadata) -> Bool {
        func isoMatches() -> Bool {
            if written.isoSpeedRatings == intended.isoSpeedRatings {
                return true
            }
            guard let writtenISO = written.isoSpeedRatings,
                  let intendedISO = intended.isoSpeedRatings,
                  let writtenValue = Int(writtenISO),
                  let intendedValue = Int(intendedISO) else {
                return false
            }
            return writtenValue == intendedValue
        }
        return written.cameraMake == intended.cameraMake &&
            written.cameraModel == intended.cameraModel &&
            written.lensModel == intended.lensModel &&
            written.filmStock == intended.filmStock &&
            isoMatches()
    }

    /// Copy an original file into the backup folder (or the app's
    /// InPlaceBackups folder when no backup folder is configured),
    /// uniquifying the name. Returns the backup file URL.
    nonisolated private static func makeInPlaceBackup(of fileURL: URL,
                                          backupURL: URL?) throws -> URL {
        let fileManager = FileManager.default
        let folder: URL
        if let backupURL {
            folder = backupURL
        } else {
            folder = try fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true)
                .appendingPathComponent(OmniTagBranding.appName,
                                        isDirectory: true)
                .appendingPathComponent("InPlaceBackups",
                                        isDirectory: true)
        }
        try fileManager.createDirectory(at: folder,
                                        withIntermediateDirectories: true)
        _ = folder.startAccessingSecurityScopedResource()
        defer { folder.stopAccessingSecurityScopedResource() }

        var destination = folder.appendingPathComponent(fileURL.lastPathComponent)
        var index = 1
        while fileManager.fileExists(atPath: destination.path) {
            let base = fileURL.deletingPathExtension().lastPathComponent
            let ext = fileURL.pathExtension
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            destination = folder.appendingPathComponent(name)
            index += 1
        }
        try fileManager.copyItem(at: fileURL, to: destination)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Put a backup copy back over an original file after a failed
    /// in-place update. Best effort: if this fails, the backup file
    /// itself is still on disk for manual recovery.
    nonisolated private static func restoreInPlaceBackup(_ backupFileURL: URL,
                                             to fileURL: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: fileURL)
            try fileManager.copyItem(at: backupFileURL, to: fileURL)
        } catch {
            // Nothing more can be done here; the backup copy remains
            // on disk for manual recovery.
        }
    }

    private static func uniqueURL(in folder: URL, named name: String) -> URL {
        let fileManager = FileManager.default
        let original = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: original.path) else {
            return original
        }

        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var index = 1
        while true {
            let candidateName = ext.isEmpty
                ? "\(base)-\(index)"
                : "\(base)-\(index).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    static func saveToLibrary(_ store: GeoTagStore,
                              _ info: [ImageData.ID: Metadata],
                              filmMetadataIDs: Set<ImageData.ID> = []) async -> SaveStatus {
        // Collect the Photos assets first so their date/location
        // updates go out as ONE batched library transaction instead
        // of one performChanges round-trip per image.
        var entries: [(id: ImageData.ID, metadata: Metadata, asset: PHAsset)] = []
        for (id, metadata) in info {
            if case .photos(_, let asset) = metadata.source, let asset {
                entries.append((id: id, metadata: metadata, asset: asset))
            }
        }
        let libraryResults = await Phototool.update(
            entries.map { entry in
                (asset: entry.asset,
                 timestamp: entry.metadata.date(),
                 location: entry.metadata.clLocation(nil))
            })

        // Resolve the Photos file URLs HERE, on the main actor:
        // Phototool.originalFileURL reaches the file through PHAsset
        // and its private KVC keys, which are not safe to call from
        // concurrent workers. The task group workers only ever touch
        // plain file URLs, never PHAssets.
        var filmItems: [(id: ImageData.ID, metadata: Metadata, fileURL: URL, hasRender: Bool)] = []
        var unresolvedFilmIDs: Set<ImageData.ID> = []
        for entry in entries where filmMetadataIDs.contains(entry.id) {
            if let fileURL = Phototool.originalFileURL(for: entry.asset) {
                // Edited assets carry a rendered JPEG inside the
                // library (a .fullSizePhoto resource), and viewers
                // read camera info from the render for them — not
                // from the original. Note here, on the main actor,
                // whether this asset has a render; the render file
                // itself is located and written on the worker (see
                // updateOriginalInPlace).
                let hasRender = PHAssetResource
                    .assetResources(for: entry.asset)
                    .contains { $0.type == .fullSizePhoto }
                filmItems.append((id: entry.id, metadata: entry.metadata,
                                  fileURL: fileURL, hasRender: hasRender))
            } else {
                unresolvedFilmIDs.insert(entry.id)
            }
        }
        // The in-place film updates run in parallel in a task group
        // (bounded like the file save task groups). Each image keeps
        // its own backup + verify + restore safeguards.
        var filmResults = await filmUpdateTasks(filmItems,
                                                backupURL: store.backupURL,
                                                timeZone: store.timeZone)
        for id in unresolvedFilmIDs {
            filmResults[id] = false
        }

        var saveStatus: SaveStatus = .saveOK
        for (index, entry) in entries.enumerated() {
            let filmOK = filmResults[entry.id] ?? true
            if libraryResults[index] && filmOK {
                store.send(.imageSaved(entry.id, entry.metadata),
                           undoable: false)
            } else {
                saveStatus = .saveError
            }
        }
        return saveStatus
    }

    // Run the in-place film updates for a batch of Photos images in
    // parallel, following the saveToImageTasks task group pattern.
    // Returns one result per image ID.
    @concurrent nonisolated static func filmUpdateTasks(
        _ items: [(id: ImageData.ID, metadata: Metadata, fileURL: URL,
                   hasRender: Bool)],
        backupURL: URL?,
        timeZone: TimeZone?
    ) async -> [ImageData.ID: Bool] {
        guard !items.isEmpty else { return [:] }

        func runOne(_ item: (id: ImageData.ID, metadata: Metadata,
                             fileURL: URL,
                             hasRender: Bool)) async -> (ImageData.ID, Bool) {
            let ok = await updateOriginalInPlace(metadata: item.metadata,
                                                 fileURL: item.fileURL,
                                                 backupURL: backupURL,
                                                 timeZone: timeZone,
                                                 hasRender: item.hasRender)
            return (item.id, ok)
        }

        var results: [ImageData.ID: Bool] = [:]
        await withTaskGroup(of: (ImageData.ID, Bool).self) { group in
            var limit = min(items.count, GeoTagApp.maxConcurrentTasks)
            for ix in 0..<limit {
                let item = items[ix]
                group.addTask { await runOne(item) }
            }
            for await (id, ok) in group {
                results[id] = ok
                if limit < items.count {
                    let item = items[limit]
                    group.addTask { await runOne(item) }
                    limit += 1
                }
            }
        }
        return results
    }

    // pass copy of MainActor related data to a nonisolated function
    // that will perform updates in parallel

    static func saveToImage(_ store: GeoTagStore,
                            _ info: [ImageData.ID: Metadata],
                            xmp: Bool = false) async -> SaveStatus {
        @AppStorage(GeoTagApp.doNotBackupKey) var doNotBackup = false
        @AppStorage(SettingsView.addTagsKey) var addTags = false
        @AppStorage(SettingsView.finderTagKey) var finderTag = OmniTagBranding.appName
        @AppStorage(SettingsView.createSidecarFilesKey) var createSidecarFiles = false

        // make sure there is something to do
        guard !info.isEmpty else { return .saveOK }

        // make sure backups are disabled or we have a backup folder
        guard doNotBackup || store.backupURL != nil else {
            store.send(.noBackupNotice, undoable: false)
            return .saveErrorSupressWarning
        }
        let backupURL = doNotBackup ? nil : store.backupURL
        let tagName = finderTag.isEmpty ? OmniTagBranding.appName : finderTag

        // common work done, image vs xmp updates are slightly different
        if xmp {
            return await saveToXmpTasks(store, info, backupURL, store.timeZone,
                                        addTags, tagName)
        }
        return await saveToImageTasks(store, info, createSidecarFiles,
                                      backupURL, store.timeZone,
                                      addTags, tagName)
    }

    // Update the items in the info dictionary in a task group

    @concurrent nonisolated static
    // swiftlint:disable:next function_parameter_count
    func saveToImageTasks(_ store: GeoTagStore,
                          _ info: [ImageData.ID: Metadata],
                          _ createSidecarFiles: Bool,
                          _ backupURL: URL?,
                          _ timeZone: TimeZone?,
                          _ tagFiles: Bool,
                          _ tagName: String) async -> SaveStatus {
        struct TaskInfo {
            let id: ImageData.ID
            let metadata: Metadata
            let sidecarCreated: Bool
            let status: Bool
        }

        var taskInfos: [TaskInfo] = []
        var saveStatus: SaveStatus = .saveOK

        func buildTaskInfo(id: ImageData.ID) async -> TaskInfo {
            let metadata = info[id]!
            guard case .image(let imageURL) = metadata.source else {
                return TaskInfo(id: id, metadata: metadata,
                                sidecarCreated: false, status: false)
            }

            var sidecarCreated = false
            do {
                let sandbox = try Sandbox(for: imageURL)
                if createSidecarFiles {
                    try sandbox.makeSidecarFile()
                    sidecarCreated = true
                }
                if let backupURL {
                    try await sandbox.makeBackupFile(backupFolder: backupURL)
                }
                try await sandbox.saveChanges(from: metadata,
                                              timeZone: timeZone)
                if tagFiles {
                    try await sandbox.setTag(name: tagName)
                }
                return TaskInfo(id: id, metadata: metadata,
                                sidecarCreated: sidecarCreated,
                                status: true)
            } catch {
                return TaskInfo(id: id, metadata: metadata,
                                sidecarCreated: sidecarCreated,
                                status: false)
            }
        }

        await withTaskGroup(of: TaskInfo.self) { group in
            let ids = Array(info.keys)
            var limit = min(ids.count, GeoTagApp.maxConcurrentTasks)
            for ix in 0..<limit {
                group.addTask { return await buildTaskInfo(id: ids[ix]) }
            }

            for await taskInfo in group {
                taskInfos.append(taskInfo)
                if limit < ids.count {
                    let id = ids[limit]
                    limit += 1
                    group.addTask { return await buildTaskInfo(id: id) }
                }
            }
        }
        // Update state from the created TaskInfo on MainActor
        await MainActor.run {
            for taskInfo in taskInfos {
                if taskInfo.sidecarCreated {
                    store.send(.sidecarCreated(taskInfo.id), undoable: false)
                }
                if taskInfo.status {
                    store.send(.imageSaved(taskInfo.id, taskInfo.metadata),
                               undoable: false)
                } else {
                    saveStatus = .saveError
                }
            }
        }
        return saveStatus
    }

    @concurrent nonisolated static
    // swiftlint:disable:next function_parameter_count
    func saveToXmpTasks(_ store: GeoTagStore,
                        _ info: [ImageData.ID: Metadata],
                        _ backupURL: URL?,
                        _ timeZone: TimeZone?,
                        _ tagFiles: Bool,
                        _ tagName: String) async -> SaveStatus {
        struct TaskInfo {
            let id: ImageData.ID
            let metadata: Metadata
            let status: Bool
        }

        var taskInfos: [TaskInfo] = []
        var saveStatus: SaveStatus = .saveOK

        func buildTaskInfo(id: ImageData.ID) async -> TaskInfo {
            let metadata = info[id]!
            guard case .xmp(let imageURL) = metadata.source else {
                return TaskInfo(id: id, metadata: metadata,
                                status: false)
            }

            do {
                let sandbox = try Sandbox(for: imageURL)
                if let backupURL {
                    try await sandbox.makeSidecarBackup(backupURL)
                }
                try await sandbox.saveChanges(from: metadata,
                                              timeZone: timeZone)
                if tagFiles {
                    try await sandbox.setTag(name: tagName)
                }
                return TaskInfo(id: id, metadata: metadata,
                                status: true)
            } catch {
                return TaskInfo(id: id, metadata: metadata,
                                status: false)
            }
        }

        await withTaskGroup(of: TaskInfo.self) { group in
            let ids = Array(info.keys)
            var limit = min(ids.count, GeoTagApp.maxConcurrentTasks)
            for ix in 0..<limit {
                group.addTask { return await buildTaskInfo(id: ids[ix]) }
            }

            for await taskInfo in group {
                taskInfos.append(taskInfo)
                if limit < ids.count {
                    let id = ids[limit]
                    limit += 1
                    group.addTask { return await buildTaskInfo(id: id) }
                }
            }
        }

        // Update state from the created TaskInfo on MainActor
        await MainActor.run {
            for taskInfo in taskInfos {
                if taskInfo.status {
                    store.send(.imageSaved(taskInfo.id, taskInfo.metadata),
                               undoable: false)
                } else {
                    saveStatus = .saveError
                }
            }
        }
        return saveStatus
    }
}
