import SwiftUI

// X1-style hero banner shared by the Movies and TV Shows tabs: wide art
// with a theme-aware gradient, big title, subtitle line and a white Play
// button. Providers only supply poster art (no backdrops), so the poster
// is cropped wide under the gradient — an honest approximation.
struct TVHeroBanner: View {
    let title: String
    let subtitle: String
    let badge: String?
    let poster: URL?
    let posterKind: LibraryKind
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    ZStack {
                        TVTheme.card
                        if let poster {
                            ProviderPoster(url: poster, kind: posterKind)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))

                LinearGradient(
                    colors: [TVTheme.background.opacity(0.92),
                             TVTheme.background.opacity(0.55),
                             .clear],
                    startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))

                VStack(alignment: .leading, spacing: 16) {
                    if let badge {
                        Text(badge)
                            .font(.caption.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(TVTheme.accent)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    Text(title)
                        .font(.system(size: 64, weight: .bold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(TVTheme.muted)
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                        Text("View details")
                            .font(.headline)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
                    .background(.white)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                }
                .padding(56)
            }
            .frame(height: 440)
        }
        .buttonStyle(.card)
    }
}
