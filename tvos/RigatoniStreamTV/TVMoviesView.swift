import SwiftUI

// Load category shelves on demand rather than downloading the entire movie catalog.
struct TVMoviesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var categories: [CatalogCategory] = []
    @State private var featured: CatalogItem?
    @State private var playing: CatalogItem?
    @State private var count = 4
    @State private var loading = false
    @State private var error = ""
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 42) {
                    StreamHeading(title: "Movies", subtitle: "Make tonight a movie night.")
                    if !categories.isEmpty { categoryStrip }
                    if let featured { hero(featured) }
                    else if loading { ProgressView("Loading movies…").padding(40) }
                    if !model.providerReady { Text("Save your provider in Settings to browse movies.").foregroundStyle(.secondary) }
                    if !error.isEmpty {
                        HStack { Text(error); Button("Retry") { retry += 1 } }.foregroundStyle(.secondary)
                    }
                    ForEach(Array(categories.prefix(count))) { category in
                        TVMovieShelf(category: category) { playing = $0 }
                    }
                    if count < categories.count {
                        Button("More categories") { count += 4 }.buttonStyle(.bordered)
                    }
                }.padding(.horizontal, 64).padding(.vertical, 40)
            }
            .background { StreamBackdrop() }
            .task(id: "\(model.libraryRevision)-\(retry)") {
                categories = []; featured = nil; count = 4; error = ""
                guard model.signedIn, model.providerReady else { return }
                loading = true; defer { loading = false }
                do {
                    let loaded = try await catalog.categories(kind: .movies, model: model)
                    try Task.checkCancellation(); categories = loaded
                    if let first = loaded.first {
                        let items = try await catalog.items(kind: .movies, category: first.id, model: model)
                        try Task.checkCancellation(); featured = items.first { $0.poster != nil } ?? items.first
                    }
                    if loaded.isEmpty { error = "No movie categories are available." }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .fullScreenCover(item: $playing) { TVPlayerView(item: $0, provider: model.provider) }
        }
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(categories) { category in
                    NavigationLink { TVCatalogBrowser(kind: .movies, allowPins: false, initialCategoryID: category.id) } label: {
                        Text(category.name).font(.headline).padding(.horizontal, 22).padding(.vertical, 12)
                    }.buttonStyle(.bordered)
                }
            }.padding(.vertical, 12)
        }
    }

    private func hero(_ item: CatalogItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            ProviderPoster(url: item.poster, kind: .movies)
            LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 18) {
                Text("IN THE SPOTLIGHT").font(.caption.weight(.semibold)).tracking(4)
                Text(item.name).font(.system(size: 48, weight: .bold)).lineLimit(2)
                Button { playing = item } label: { Label("Watch movie", systemImage: "play.fill").padding(.horizontal, 22) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            }.padding(40)
        }.frame(height: 490).clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

private struct TVMovieShelf: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    let category: CatalogCategory
    let play: (CatalogItem) -> Void
    @State private var items: [CatalogItem] = []
    @State private var loading = true
    @State private var error = ""
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(category.name).font(.title2.bold()).lineLimit(1)
                Spacer()
                NavigationLink { TVCatalogBrowser(kind: .movies, allowPins: false, initialCategoryID: category.id) } label: {
                    Label("See all", systemImage: "chevron.right").font(.callout)
                }.buttonStyle(.bordered)
            }
            if loading { ProgressView().padding(24) }
            else if !error.isEmpty {
                HStack { Text(error).foregroundStyle(.secondary); Button("Retry") { retry += 1 } }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(items) { item in
                        Button { play(item) } label: { TVCatalogCard(item: item) }.buttonStyle(.card)
                    }
                }.padding(.vertical, 20).padding(.horizontal, 12)
            }
        }
        .task(id: "\(category.id)-\(model.libraryRevision)-\(retry)") {
            loading = true; error = ""; items = []
            defer { loading = false }
            do {
                let loaded = try await catalog.items(kind: .movies, category: category.id, model: model)
                try Task.checkCancellation(); items = Array(loaded.prefix(20))
                if items.isEmpty { error = "No movies in this category." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
