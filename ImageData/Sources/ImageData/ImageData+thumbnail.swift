import Imagetool
import Phototool
import PhotosUI
import SwiftUI

extension ImageData {
    public func makeThumbnail(scale: CGFloat) async -> Image {
        var image: Image?
        switch metadata.source {
        case .image(let url), .xmp(let url):
            if let nsImage = Imagetool.imageThumbnail(url: url, scale: scale) {
                image = Image(nsImage: nsImage)
            }
        case .photos(let pickerItem, let asset):
            // Ask Photos for a small rendered preview instead of
            // loading the full original — very slow for large RAW
            // files such as RW2. Uses the same 1024 * scale cap as
            // the file path (Imagetool.imageThumbnail). Falls back
            // to the full load when there is no asset or Photos
            // can not provide a preview.
            if let asset,
               let thumbnail = await Phototool.thumbnailImage(
                   for: asset, maxPixelSize: 1024.0 * scale) {
                image = thumbnail
            } else if let thumbnail = await Phototool.image(from: pickerItem) {
                image = thumbnail
            }
        default:
            break
        }
        if image == nil {
            // try to create an image of noImageView for proper
            // opacity
            await MainActor.run {
                let renderer = ImageRenderer(content: noImageView())
                renderer.scale = scale
                if let nsImage = renderer.nsImage {
                    image = Image(nsImage: nsImage)
                }
            }
        }
        if let image {
            return image
        }
        return Image(systemName: "photo.badge.exclamationmark")
    }

    func noImageView() -> some View {
        VStack {
            Image(systemName: "photo.badge.exclamationmark")
                .resizable()
                .scaledToFit()
                .opacity(0.18)
        }
        .frame(width: 1024, height: 1024)
    }
}
