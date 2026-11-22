import SwiftUI

struct TVHistoryRail: View {
    @EnvironmentObject private var model: AppModel
    var title = "Last watched"
    var onlyInProgress = false
    var hidesWhenEmpty = false
    @State private var records: [TVWatchedRecord] = []
    @State private var playing: CatalogItem?
    @State private var playingKind = "movie"
    @State private var playingProgressID: String?
    @State private var notice = ""
    // Movie detail pushes on the NavigationStack so the player's cover is a
    // single modal level (nested fullScreenCovers silently fail on tvOS).
    @State private var detailItem: CatalogItem?
    @State private var showingDetail = false

    var body: some View {
        if hidesWhenEmpty && records.isEmpty {
            Color.clear.frame(width: 0, height: 0).onAppear { reload() }.onChange(of: model.libraryRevision) { _, _ in reload() }
        } else {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            if records.isEmpty {
                Text("Watch a channel, movie or episode to find it here.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(records) { record in
                            Button { Task { await open(record) } } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    Image(systemName: record.kind == "live" ? "tv" : record.kind == "series" ? "play.tv" : "film")
                                        .font(.system(size: 44)).frame(width: 260, height: 130)
                                        .background(StreamTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                                    TVFocusTitle(title: displayName(record)).lineLimit(2).frame(width: 260, alignment: .leading)
                                }
                            }.buttonStyle(TVCardButtonStyle())
                        }
                    }.padding(.vertical, 14)
                }
            }
            if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
        }
        .onAppear { reload() }
        .onChange(of: model.libraryRevision) { _, _ in reload() }
        .fullScreenCover(item: $playing, onDismiss: { reload() }) { item in
            if playingKind == "series" {
                let progressID = playingProgressID ?? ("series-" + item.id)
                DirectPlayerView(item: item, provider: model.provider(for: item),
                             startSeconds: model.preferences.progress[progressID]?.seconds ?? 0,
                             progressID: progressID)
            } else { CatalogDestination(item: item) }
        }
        .navigationDestination(isPresented: $showingDetail) {
            if let item = detailItem { MovieDetailView(item: item) }
        }
        }
    }

    private func reload() {
        records = TVLastWatched.items(model: model).filter { record in
            let kind: LibraryKind = record.kind == "live" ? .live : .movies
            let visible = record.kind == "series" || model.preferences.visible(CatalogItem(id: record.itemID, name: record.name, kind: kind, fileExtension: record.ext, poster: nil, categoryID: record.categoryID, providerID: record.providerID))
            guard visible else { return false }
            if !onlyInProgress { return true }
            let key = record.progressID ?? (record.kind == "series" ? "series-" + record.itemID : record.itemID)
            return model.preferences.progress[key] != nil
        }
    }

    private func displayName(_ record: TVWatchedRecord) -> String {
        let section: CatalogSection = record.kind == "live" ? .live : (record.kind == "series" ? .series : .movies)
        let id = CatalogItem.namespaced(providerID: record.providerID, id: record.itemID)
        return model.preferences.displayName(raw: record.name, key: LibraryPreferences.renameKey(section: section, role: "item", id: id))
    }

    private func open(_ record: TVWatchedRecord) async {
        let scope = model.preferenceKey
        notice = ""; playingKind = record.kind; playingProgressID = record.progressID
        let kind: LibraryKind = record.kind == "live" ? .live : .movies
        var item = CatalogItem(id: record.itemID, name: record.name, kind: kind, fileExtension: record.ext, poster: nil, categoryID: record.categoryID, providerID: record.providerID)
        do {
            let owner = model.provider(for: item)
            if record.kind == "series" {
                guard owner.kind == .xtream else {
                    notice = "This episode requires an Xtream Codes provider."; return
                }
                item.playbackURL = try SeriesStore.seriesStreamURL(provider: owner, episodeID: item.id, ext: item.fileExtension)
            } else { item = try await model.resolve(item) }
            guard scope == model.preferenceKey else { return }
            if record.kind == "movie" { detailItem = item; showingDetail = true }
            else { playing = item }
        } catch { notice = error.localizedDescription }
    }
}
