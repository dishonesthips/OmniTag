import ImageData
import SwiftUI
import UDF

struct ImageInspectorForm: View {
    var image: ImageData

    let notice: LocalizedStringKey = """
        Latitude and Longitude updates are applied as you type.
        """

    var body: some View {
        Form {
            Section("Date and Time") {
                DateTimeSectionView(image: image)
            }
            Section("Location") {
                LatLonSectionView(image: image)
            }
            Section("Camera and Film") {
                CameraFilmSectionView(image: image)
            }
            Section("Notice") {
                Text(notice)
            }
        }
    }
}

#Preview {
    Text("""
       Look at **ImageInspectorView**
       to see a preview of this sub-view
       """)
        .multilineTextAlignment(.leading)
        .padding()

}
