import AppKit
import ImageData
import Metadata
import Phototool
import SwiftUI
import UDF

struct CameraFilmSectionView: View {
    @Environment(GeoTagStore.self) var store

    var image: ImageData

    @State private var make = ""
    @State private var model = ""
    @State private var lens = ""
    @State private var iso = ""
    @State private var filmStock = ""
    @State private var lastCommitted: FilmValues?
    @State private var editTarget: Set<ImageData.ID> = []
    @State private var undoGroupOpen = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case make, model, lens, iso, filmStock
    }

    private struct FilmValues: Equatable {
        var make: String?
        var model: String?
        var lens: String?
        var iso: String?
        var filmStock: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applies to \(store.selection.count) selected file\(store.selection.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Camera make (EXIF Make)", text: $make)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .make)
            TextField("Camera name (EXIF Model)", text: $model)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .model)
            TextField("Lens (EXIF LensModel)", text: $lens)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .lens)
            TextField("ISO (EXIF ISOSpeedRatings)", text: $iso)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .iso)
            TextField("Film stock (XMP dc:Subject)", text: $filmStock)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .filmStock)
        }
        .help("Edits are applied to the selected files as you type, and are written on save (⌘S). Writes EXIF Make, Model, LensModel, ISOSpeedRatings, and XMP-dc:Subject.")
        .onSubmit { commit() }
        .onChange(of: focusedField) { oldField, _ in
            if oldField != nil {
                commit()
            }
        }
        .onChange(of: store.selection) {
            // Follow the selection while there are no uncommitted
            // edits; with edits pending, editTarget stays with the
            // images they were made on.
            if currentValues == lastCommitted {
                editTarget = store.selection
            }
        }
        .onChange(of: make) { liveCommit() }
        .onChange(of: model) { liveCommit() }
        .onChange(of: lens) { liveCommit() }
        .onChange(of: iso) { liveCommit() }
        .onChange(of: filmStock) { liveCommit() }
        .onDisappear { closeUndoGroup() }
        .task(id: image.id) { await load() }
    }

    private func value(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func load() async {
        // Lock in any uncommitted edits before the fields are
        // overwritten with the newly selected image's values.
        // commit() addresses them to editTarget — the selection
        // they were made on — even though the selection has
        // already moved to the new image.
        if lastCommitted != nil {
            commit()
        }

        var metadata = image.metadata

        if case .photos(let item, let asset) = image.metadata.source {
            let hasCameraMetadata = image.metadata.cameraMake != nil ||
                image.metadata.cameraModel != nil ||
                image.metadata.lensModel != nil ||
                image.metadata.isoSpeedRatings != nil ||
                image.metadata.filmStock != nil

            if !hasCameraMetadata {
                metadata = await Phototool.metadata(fromPhotoItem: item, asset: asset)
            }
        }

        guard !Task.isCancelled else { return }
        make = metadata.cameraMake ?? ""
        model = metadata.cameraModel ?? ""
        lens = metadata.lensModel ?? ""
        iso = metadata.isoSpeedRatings ?? ""
        filmStock = metadata.filmStock ?? ""
        lastCommitted = FilmValues(make: metadata.cameraMake,
                                   model: metadata.cameraModel,
                                   lens: metadata.lensModel,
                                   iso: metadata.isoSpeedRatings,
                                   filmStock: metadata.filmStock)
        editTarget = store.selection
    }

    private var currentValues: FilmValues {
        FilmValues(make: value(make), model: value(model), lens: value(lens),
                   iso: value(iso), filmStock: value(filmStock))
    }

    // Live transfer while typing: every change is sent as it is
    // made, so the table updates (and goes green) immediately.
    // The event carries the target image IDs explicitly, so the
    // edits land on the images they were made on even if the
    // selection has since moved to another image. Only the
    // transferred value is trimmed (empty or whitespace-only
    // fields become nil, i.e. cleared) — the field text itself is
    // left alone until the edit settles (see commit()). Sends
    // within one editing session form a single undo group.
    @discardableResult
    private func liveCommit() -> Bool {
        let values = currentValues
        guard values != lastCommitted else { return false }
        let targets = editTarget.isEmpty ? store.selection : editTarget
        guard !targets.isEmpty else { return false }
        if !undoGroupOpen {
            store.beginUndoGroup(description: "update camera and film metadata")
            undoGroupOpen = true
        }
        lastCommitted = values
        store.send(.cameraFilmChanged(targets, values.make, values.model,
                                      values.lens, values.iso,
                                      values.filmStock),
                   description: "update camera and film metadata")
        return true
    }

    // Settle an edit (Return, leaving a field, switching images):
    // flush any pending change, close the undo group, and rewrite
    // the fields with exactly what was transferred.
    private func commit() {
        liveCommit()
        closeUndoGroup()
        let values = currentValues
        if make != (values.make ?? "") || model != (values.model ?? "") ||
            lens != (values.lens ?? "") || iso != (values.iso ?? "") ||
            filmStock != (values.filmStock ?? "") {
            make = values.make ?? ""
            model = values.model ?? ""
            lens = values.lens ?? ""
            iso = values.iso ?? ""
            filmStock = values.filmStock ?? ""
        }
    }

    private func closeUndoGroup() {
        if undoGroupOpen {
            store.endUndoGroup()
            undoGroupOpen = false
        }
    }

}
