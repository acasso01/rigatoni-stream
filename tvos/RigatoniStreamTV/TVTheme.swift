import SwiftUI

// Design tokens mirrored from the web app's theme.css so the TV build
// looks like Rigatoni Stream: dark background, off-white text, red accent.
enum TVTheme {
    static let background = StreamTheme.background // #09090b
    static let panel = StreamTheme.panel      // #17171b
    static let text = Color(red: 0.980, green: 0.980, blue: 0.980)       // #fafafa
    static let red = Color(red: 0.898, green: 0.035, blue: 0.078)        // #e50914
    static let muted = Color.gray
    static let corner: CGFloat = 18
}

// Observe mutations inside the reference store held by each tab.
struct TVObservedStore<Content: View>: View {
    @ObservedObject var store: TVLibraryStore
    @ViewBuilder var content: (TVLibraryStore) -> Content
    var body: some View { content(store) }
}
