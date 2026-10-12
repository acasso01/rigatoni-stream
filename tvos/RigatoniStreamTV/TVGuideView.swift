import SwiftUI

// X1-style program guide: channels as rows, 30-minute time slots as
// columns. Program data comes from the Xtream `get_short_epg` endpoint
// (direct providers only). Graceful fallbacks, in order:
//  1. Channel with no EPG -> full-width LIVE block for the slot.
//  2. Provider returns no EPG at all (or a gateway is in use) ->
//     plain channel rows with LIVE badges. The grid is never empty.
// Inspired by the X1 layout language only — no Xfinity/Comcast logos,
// trademarks or copied assets.
struct TVProgram: Identifiable {
    var id: String { channelID + "-" + String(Int(start.timeIntervalSince1970)) }
    let channelID: String
    let title: String
    let start: Date
    let end: Date
}

struct TVGuideView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var selectedCategory = ""
    @State private var epg: [String: [TVProgram]] = [:]
    @State private var epgLoaded = false
    @State private var playing: CatalogItem?
    @FocusState private var focusedCell: String?

    private let slotMinutes = 30
    private let slotCount = 4
    private let maxGuideChannels = 40
    private let channelColumnWidth: CGFloat = 300
    private let slotWidth: CGFloat = 340

    private static let epgDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Xtream providers report EPG times in UTC.
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let slotFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var slotStarts: [Date] {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let minute = (comps.minute ?? 0) / slotMinutes * slotMinutes
        let base = cal.date(from: DateComponents(year: comps.year, month: comps.month,
                                                day: comps.day, hour: comps.hour,
                                                minute: minute)) ?? now
        return (0..<slotCount).map { base.addingTimeInterval(Double($0 * slotMinutes * 60)) }
    }

    private var hasAnyEPG: Bool { epg.values.contains { !$0.isEmpty } }

    var body: some View {
        Group {
            if let store { content(store) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(TVTheme.background)
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: .live, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        if !model.providerReady {
            Text("Save your provider in Settings to browse the guide.")
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.loading && store.categories.isEmpty {
            ProgressView("Loading guide…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Guide")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 48)
                    .padding(.top, 40)

                categoryChips(store)
                    .padding(.top, 16)

                if !epgLoaded {
                    ProgressView("Loading program data…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasAnyEPG {
                    guideGrid(Array(store.items.prefix(maxGuideChannels)))
                } else {
                    fallbackRows(Array(store.items.prefix(maxGuideChannels)))
                }

                if store.items.count > maxGuideChannels {
                    Text("Showing the first \(maxGuideChannels) channels — use Live TV to browse them all.")
                        .font(.caption)
                        .foregroundStyle(TVTheme.muted)
                        .padding(.horizontal, 48)
                        .padding(.bottom, 24)
                }
            }
            .foregroundStyle(TVTheme.text)
        }
        .task(id: model.libraryRevision) {
            await store.loadCategories()
            if selectedCategory.isEmpty {
                selectedCategory = store.categories.first?.id ?? ""
            }
        }
        .task(id: selectedCategory) {
            guard !selectedCategory.isEmpty else { return }
            await store.loadItems(categoryID: selectedCategory)
            await loadEPG(for: store.items)
        }
        .fullScreenCover(item: $playing) { item in
            TVPlayerView(item: item, provider: model.provider, channels: store.items)
        }
    }

    // MARK: - Category chips

    private func categoryChips(_ store: TVLibraryStore) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(store.categories) { category in
                    Button { selectedCategory = category.id } label: {
                        Text(category.name)
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedCategory == category.id ? TVTheme.accent : TVTheme.muted)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 8)
        }
    }

    // MARK: - EPG loading

    private func loadEPG(for channels: [CatalogItem]) async {
        epgLoaded = false
        // The HTTPS gateway has no EPG endpoint: fall back to LIVE rows.
        guard !model.provider.requiresGateway else { epgLoaded = true; return }
        let targets = Array(channels.prefix(maxGuideChannels))
        var result: [String: [TVProgram]] = [:]
        await withTaskGroup(of: (String, [TVProgram]).self) { group in
            for channel in targets {
                group.addTask { (channel.id, await fetchEPG(channelID: channel.id)) }
            }
            for await (id, programs) in group {
                result[id] = programs
            }
        }
        epg = result
        epgLoaded = true
    }

    private func fetchEPG(channelID: String) async -> [TVProgram] {
        do {
            var components = URLComponents(
                url: try model.provider.apiURL(action: "get_short_epg"),
                resolvingAgainstBaseURL: false)!
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "stream_id", value: channelID))
            components.queryItems = items
            guard let url = components.url else { return [] }
            let data = try await BoundedTransfer(limit: 4 * 1024 * 1024, timeout: 15).fetch(url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let listings = root["epg_listings"] as? [[String: Any]] else { return [] }
            return listings.compactMap { row -> TVProgram? in
                guard let title = row["title"] as? String, !title.isEmpty,
                      let s = row["start"] as? String,
                      let e = row["end"] as? String,
                      let start = Self.epgDateFormatter.date(from: s),
                      let end = Self.epgDateFormatter.date(from: e),
                      end > start else { return nil }
                return TVProgram(channelID: channelID, title: title, start: start, end: end)
            }
            .sorted { $0.start < $1.start }
        } catch {
            return []
        }
    }

    // MARK: - Time-slot grid

    private func guideGrid(_ channels: [CatalogItem]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: channelColumnWidth, height: 44)
                    ForEach(slotStarts, id: \.self) { slot in
                        Text(Self.slotFormatter.string(from: slot))
                            .font(.headline)
                            .foregroundStyle(TVTheme.muted)
                            .frame(width: slotWidth, alignment: .leading)
                    }
                }
                .padding(.vertical, 12)

                ForEach(channels) { channel in
                    guideRow(channel)
                        .focusSection()
                }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 48)
        }
    }

    private func guideRow(_ channel: CatalogItem) -> some View {
        HStack(spacing: 0) {
            Button { playing = channel } label: {
                HStack(spacing: 16) {
                    TVChannelLogo(item: channel)
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(width: channelColumnWidth, height: 96)
                .background(TVTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .focused($focusedCell, equals: "ch-\(channel.id)")
            .padding(.trailing, 8)

            ForEach(slotStarts, id: \.self) { slot in
                programCell(channel: channel, slot: slot)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func programCell(channel: CatalogItem, slot: Date) -> some View {
        let programs = epg[channel.id] ?? []
        let slotEnd = slot.addingTimeInterval(Double(slotMinutes * 60))
        if let program = programs.first(where: { $0.start < slotEnd && $0.end > slot }) {
            let overlap = min(program.end, slotEnd).timeIntervalSince(max(program.start, slot))
            let width = max(140, slotWidth * CGFloat(overlap / Double(slotMinutes * 60)))
            let isLive = program.start <= Date() && program.end > Date()
            let focused = focusedCell == program.id
            Button { playing = channel } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(program.title)
                        .font(.headline)
                        .lineLimit(2)
                    if isLive {
                        Text("LIVE NOW")
                            .font(.caption2.bold())
                            .foregroundStyle(TVTheme.accent)
                    }
                }
                .padding(.horizontal, 16)
                .frame(width: width, height: 96, alignment: .leading)
                .background(isLive ? TVTheme.accent.opacity(0.25) : TVTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(focused ? TVTheme.accent : Color.clear, lineWidth: 4)
                )
            }
            .buttonStyle(.plain)
            .focused($focusedCell, equals: program.id)
        } else {
            // No EPG for this slot: full-width LIVE block.
            Button { playing = channel } label: {
                Text("LIVE")
                    .font(.caption.bold())
                    .foregroundStyle(TVTheme.accent)
                    .frame(width: slotWidth, height: 96, alignment: .leading)
                    .padding(.horizontal, 16)
                    .background(TVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .focused($focusedCell, equals: "live-\(channel.id)-\(Int(slot.timeIntervalSince1970))")
        }
    }

    // MARK: - Fallback: channel rows with LIVE badges

    private func fallbackRows(_ channels: [CatalogItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(channels) { channel in
                    Button { playing = channel } label: {
                        HStack(spacing: 20) {
                            TVChannelLogo(item: channel)
                            Text(channel.name)
                                .font(.title3)
                                .lineLimit(1)
                            Spacer()
                            Text("LIVE")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(TVTheme.accent)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(TVTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.card)
                    .focused($focusedCell, equals: "fb-\(channel.id)")
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
        }
    }
}
