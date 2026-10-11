import SwiftUI

struct TVMoviesView: View {
    var body: some View {
        TVCatalogBrowser(kind: .movies, allowPins: false)
    }
}
