import Coords
import ImageData
import Metadata
import Photos
import PhotosUI
import Phototool
import SwiftUI
import UDF

struct ImageTableView: View {
    @Environment(GeoTagStore.self) var store

    @AppStorage(Self.imageTableConfigKey)
    private var columnCustomization: TableColumnCustomization<ImageData>

    @AppStorage(Self.hideInvalidImagesKey) var hideInvalidImages = false

    // Column width limits
    let nameMinWidth = 100.0
    let nameMaxWidth = 300.0
    let timestampMinWidth = 130.0
    let timestampMaxWidth = 150.0
    let coordMinWidth = 120.0
    let coordMaxWidth = 160.0

    @State private var searchActive = false
    @State private var searchText = ""
    @State private var selection: Set<ImageData.ID> = []
    @State private var sortOrder = [KeyPathComparator(\ImageData.name)]
    @AppStorage(Self.fileTypeFilterKey) private var fileTypeFilter = "All files"
    @FocusState private var isFocused: Bool
    @Binding var inspectorPresented: Bool

    private var fileTypes: [String] {
        let standard = Self.standardFileTypes
        let detected = store.imageData.map(\.fileType)
        return Array(Set(standard + detected)).sorted {
            (standard.firstIndex(of: $0) ?? standard.count)
                < (standard.firstIndex(of: $1) ?? standard.count)
        }
    }

    var filteredImages: [ImageData] {
        store.imageData.filter { image in
            let matchesSearch = store.searchText.isEmpty
                || image.name.fuzzy(store.searchText)
            let matchesFileType = fileTypeFilter == "All files"
                || fileTypeFilter == "All types"
                || image.fileType == fileTypeFilter
            let matchesValidity = !hideInvalidImages || image.updatable
            return matchesSearch && matchesFileType && matchesValidity
        }
    }

    // Finder-style status text shown in a bar under the table
    private var selectionStatus: String {
        let total = store.imageData.count
        let selected = store.selection.count
        if selected == 0 {
            return total == 1 ? "1 photo" : "\(total) photos"
        }
        return "\(selected) of \(total) selected"
    }

    var body: some View {
        Table(of: ImageData.self,
              selection: $selection,
              sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \.name) { image in
                NameView(image: image, isSelected: image.id == store.mostSelected)
            }
            .width(min: nameMinWidth, max: nameMaxWidth)
            .customizationID("Name")

            TableColumn("Timestamp", value: \.metadata.timestamp) { image in
                TimestampView(image: image)
            }
            .width(min: timestampMinWidth, max: timestampMaxWidth)
            .customizationID("Timestamp")

            if store.omniTagMode == .location {
                TableColumn("Latitude", value: \.metadata.formattedLatitude) { image in
                    LatitudeView(image: image)
                }
                .width(min: coordMinWidth, max: coordMaxWidth)
                .customizationID("Latitude")

                TableColumn("Longitude", value: \.metadata.formattedLongitude) { image in
                    LongitudeView(image: image)
                }
                .width(min: coordMinWidth, max: coordMaxWidth)
                .customizationID("Longitude")
            } else if store.omniTagMode == .film {
                TableColumn("Make") { image in
                    FilmMetadataView(
                        value: image.metadata.cameraMake,
                        color: image.filmMetadataTextColor(\.cameraMake)
                    )
                }
                .width(min: nameMinWidth, max: nameMaxWidth)
                .customizationID("Make")

                TableColumn("Model") { image in
                    FilmMetadataView(
                        value: image.metadata.cameraModel,
                        color: image.filmMetadataTextColor(\.cameraModel)
                    )
                }
                .width(min: nameMinWidth, max: nameMaxWidth)
                .customizationID("Model")

                TableColumn("Film Stock") { image in
                    FilmMetadataView(
                        value: image.metadata.filmStock,
                        color: image.filmMetadataTextColor(\.filmStock)
                    )
                }
                .width(min: nameMinWidth, max: nameMaxWidth)
                .customizationID("Film Stock")

                TableColumn("ISO") { image in
                    FilmMetadataView(
                        value: image.metadata.isoSpeedRatings,
                        color: image.filmMetadataTextColor(\.isoSpeedRatings)
                    )
                }
                .width(min: 80, max: 120)
                .customizationID("ISO")
            }
        } rows: {
            ForEach(filteredImages) { image in
                TableRow(image)
                    .contextMenu {
                        ContextMenuView(context: image.id,
                                        inspectorPresented: $inspectorPresented)
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text(selectionStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.bar)
        }
        .focused($isFocused)
        .contextMenu {
            ContextMenuView(context: nil,
                            inspectorPresented: $inspectorPresented)
        }
        .onChange(of: selection) {
            if selection != store.selection {
                store.send(.selectionChanged(selection), undoable: false)
            }
        }
        .onChange(of: store.selection) {
            if selection != store.selection {
                selection = store.selection
            }
        }
        .onChange(of: sortOrder) {
            if sortOrder != store.sortOrder {
                store.send(.sortOrderChanged(sortOrder), undoable: false)
            }
        }
        .searchable(text: $searchText, isPresented: $searchActive,
                    placement: .automatic, prompt: "image name")
        .onChange(of: store.searchActive) {
            if searchActive != store.searchActive {
                searchActive = store.searchActive
            }
        }
        .onChange(of: searchActive) {
            store.send(.textfieldFocusChanged(searchActive), undoable: false)
            if searchActive != store.searchActive {
                store.send(.searchActiveChanged(searchActive),
                           undoable: false)
            }
        }
        .onChange(of: searchText) {
            store.send(.searchTextChanged(searchText))
        }
        .onChange(of: store.textfieldActive) {
            if !store.textfieldActive {
                isFocused = true
            }
        }
        .task(id: store.omniTagMode) {
            await loadFilmMetadata()
        }
        .onAppear {
            if fileTypeFilter == "All types" {
                fileTypeFilter = "All files"
            }
            selection = store.selection
            sortOrder = store.sortOrder
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(OmniTagMode.allCases) { mode in
                        Button {
                            store.send(.omniTagModeChanged(mode), undoable: false)
                        } label: {
                            HStack {
                                Image(systemName: store.omniTagMode == mode
                                      ? "checkmark" : "")
                                    .frame(width: 16)
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Text(store.omniTagMode.title)
                        .padding(.horizontal, 10)
                }
                .help("Choose which metadata is shown and copied")
            }

            if store.omniTagMode == .time {
                ToolbarItem {
                    Button("TIFF nearest neighbour",
                           systemImage: "clock.arrow.2.circlepath") {
                        store.send(.tiffNearestNeighborRequest,
                                   description: "set TIFF timestamps from nearest neighbours")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(store.imageData.isEmpty)
                    .help("Fill timestamps from neighbours")
                }
            }

            if store.omniTagMode == .location {
                ToolbarItem {
                    Button("Location nearest neighbour",
                           systemImage: "location.circle") {
                        store.send(.locationNearestNeighborRequest,
                                   description: "set missing locations from nearest neighbours")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(store.imageData.isEmpty)
                    .help("Fill locations from neighbours")
                }
            }

            ToolbarItem {
                Menu {
                    Button("All files") { fileTypeFilter = "All files" }
                    Divider()
                    ForEach(fileTypes, id: \.self) { fileType in
                        Button(fileType) { fileTypeFilter = fileType }
                    }
                } label: {
                    Text(fileTypeFilter)
                }
                .help("Show only files of a selected type")
            }
        }
    }

    private func loadFilmMetadata() async {
        guard store.omniTagMode == .film else { return }
        // Build the background jobs here, on the main actor: PHAsset
        // access (building the base metadata, the file-URL probe in
        // originalFileURL) is not safe from concurrent worker
        // threads. Workers receive only Sendable values — an ID, a
        // base Metadata, and a file URL — and never touch PHAssets.
        var jobs: [(id: ImageData.ID, base: Metadata, url: URL)] = []
        for image in store.imageData {
            guard image.fileType == "TIFF",
                  !store.loadedFilmMetadata.contains(image.id),
                  case .photos(let item, let asset) = image.metadata.source,
                  let asset else { continue }
            if let url = Phototool.originalFileURL(for: asset) {
                jobs.append((id: image.id,
                             base: Phototool.metadata(from: item,
                                                      asset: asset),
                             url: url))
            } else {
                // No on-disk original (e.g. not yet downloaded):
                // the fetch path needs the asset and its resource,
                // which cannot be handed to a worker, so load this
                // one here, one by one as before.
                let metadata = await Phototool.metadata(
                    fromPhotoItem: item, asset: asset,
                    originalURL: nil,
                    resource: Phototool.originalResource(for: asset))
                store.send(.photosMetadataLoaded(image.id, metadata),
                           undoable: false)
            }
        }
        guard !jobs.isEmpty else { return }

        // Parse the on-disk originals concurrently, off the main
        // actor; results are sent to the store when the batch
        // returns.
        let results = await Self.loadFilmMetadataFiles(jobs)
        guard !Task.isCancelled else { return }
        for (id, metadata) in results {
            store.send(.photosMetadataLoaded(id, metadata), undoable: false)
        }
    }

    // Parse a batch of on-disk originals concurrently, at most
    // six at a time, off the main actor. Mirrors
    // SaveHelper.filmUpdateTasks: the jobs arrive as a parameter
    // and every value in them is Sendable, so they can be handed
    // to the task group freely. (Handing it PHAssets instead is a
    // Swift 6 region-isolation error — and unsafe besides, since
    // PHAsset access is backed by Photos' Core Data context.)
    @concurrent nonisolated private static func loadFilmMetadataFiles(
        _ jobs: [(id: ImageData.ID, base: Metadata, url: URL)]
    ) async -> [(ImageData.ID, Metadata)] {
        func loadOne(_ job: (id: ImageData.ID, base: Metadata, url: URL))
            -> (ImageData.ID, Metadata) {
            let metadata = Phototool.metadataByParsingFile(at: job.url,
                                                           into: job.base)
            return (job.id, metadata)
        }

        return await withTaskGroup(of: (ImageData.ID, Metadata).self) { group in
            var results: [(ImageData.ID, Metadata)] = []
            var next = 0
            let limit = min(jobs.count, 6)
            while next < limit {
                let job = jobs[next]
                next += 1
                group.addTask { loadOne(job) }
            }
            for await result in group {
                results.append(result)
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { loadOne(job) }
                }
            }
            return results
        }
    }
}

// ImageTableView AppStorage keys

extension ImageTableView {
    static let imageTableConfigKey = "ImageTableConfig"
    static let hideInvalidImagesKey = "HideInvalidImages"
    static let fileTypeFilterKey = "PhotoLibraryFileTypeFilter"
    static let standardFileTypes = [
        "TIFF", "JPEG", "DNG", "NEF", "RW2", "HEIC", "HEIF", "PNG"
    ]
}

#Preview(traits: .store) {
    ImageTableView(inspectorPresented: .constant(false))
        .frame(width: 600, height: 1000)
}
