import SwiftUI

// Design tokens mirrored from the web app's theme.css so the TV build
// looks like Rigatoni Stream: dark background, off-white text, red accent.
enum TVTheme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.043) // #09090b
    static let panel = Color(red: 0.090, green: 0.090, blue: 0.106)      // #17171b
    static let text = Color(red: 0.980, green: 0.980, blue: 0.980)       // #fafafa
    static let red = Color(red: 0.898, green: 0.035, blue: 0.078)        // #e50914
    static let muted = Color.gray
    static let corner: CGFloat = 16
}
