import SwiftUI

struct TVHistoryRail: View {
    @EnvironmentObject private var model: AppModel
    @State private var records: [TVWatchedRecord] = []
    @State private var playing: CatalogItem?
    @State private var playingKind = "movie"
    @State private var notice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Last watched").font(.title2.bold())
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
                                    TVFocusTitle(title: record.name).lineLimit(2).frame(width: 260, alignment: .leading)
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
                DirectPlayerView(item: item, provider: model.provider,
                             startSeconds: model.preferences.progress["series-" + item.id]?.seconds ?? 0,
                             progressID: "series-" + item.id)
            } else { CatalogDestination(item: item) }
        }
    }

    private func reload() {
        records = TVLastWatched.items(model: model).filter {
            let kind: LibraryKind = $0.kind == "live" ? .live : .movies
            return $0.kind == "series" || model.preferences.visible(CatalogItem(id: $0.itemID, name: $0.name, kind: kind, fileExtension: $0.ext, poster: nil, categoryID: $0.categoryID))
        }
    }

    private func open(_ record: TVWatchedRecord) async {
        let scope = model.preferenceKey
        notice = ""; playingKind = record.kind
        let kind: LibraryKind = record.kind == "live" ? .live : .movies
        var item = CatalogItem(id: record.itemID, name: record.name, kind: kind, fileExtension: record.ext, poster: nil, categoryID: record.categoryID)
        do {
            if record.kind == "series" {
                guard model.provider.kind == .xtream else {
                    notice = "This episode requires an Xtream Codes provider."; return
                }
                item.playbackURL = try SeriesStore.seriesStreamURL(provider: model.provider, episodeID: item.id, ext: item.fileExtension)
            } else { item = try await model.resolve(item) }
            guard scope == model.preferenceKey else { return }
            playing = item
        } catch { notice = error.localizedDescription }
    }
}
