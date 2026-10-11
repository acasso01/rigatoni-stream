import SwiftUI

struct TVLiveView: View {
    var body: some View {
        TVCatalogBrowser(kind: .live, allowPins: true)
    }
}
