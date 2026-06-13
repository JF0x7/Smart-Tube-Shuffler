//
//  QueueSidebar.swift
//  SmartTubecontroller
//

import SwiftUI

// MARK: - Queue sidebar

struct QueueSidebar: View {
    @ObservedObject var vm: SmartTubeControllerViewModel

    private enum Feed: String, CaseIterable {
        case recommended = "Recommended"
        case related = "Related"
    }

    @AppStorage("smarttube.upnext.feed") private var feedRaw = Feed.recommended.rawValue
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?
    private var feed: Feed { Feed(rawValue: self.feedRaw) ?? .recommended }
    private var trimmedSearch: String { self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasSearch: Bool { !self.trimmedSearch.isEmpty }
    private var searchLooksPlayable: Bool { Self.looksLikeVideo(self.trimmedSearch) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: self.vm.isSearching ? "magnifyingglass" : "magnifyingglass.circle")
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    TextField("Search YouTube", text: self.$searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { self.submitSearchField() }
                    if self.hasSearch {
                        Button {
                            self.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if self.hasSearch {
                    HStack(spacing: 8) {
                        if self.searchLooksPlayable {
                            Button {
                                self.openSearchText()
                            } label: {
                                Label("Open", systemImage: "play.fill")
                            }
                        } else {
                            Button {
                                self.searchNow()
                            } label: {
                                Label("Search", systemImage: "magnifyingglass")
                            }
                            .disabled(self.vm.isSearching)
                        }
                        Menu {
                            Button("Add to Queue") { self.queueSearchText(next: false) }
                            Button("Play Next") { self.queueSearchText(next: true) }
                        } label: {
                            Label("Queue", systemImage: "text.badge.plus")
                        }
                        .disabled(!self.searchLooksPlayable)
                    }
                    .controlSize(.small)
                }

                if self.vm.isSearching && self.vm.searchResults.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else if let error = self.vm.searchError, self.hasSearch {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if self.hasSearch && !self.searchLooksPlayable && self.vm.searchResults.isEmpty {
                    Text("Type a query, then choose a result to play or queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(self.vm.searchResults) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        VideoRow(item: item)

                        HStack(spacing: 8) {
                            Button {
                                self.playSearchResult(item)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }

                            Button {
                                if let id = item.videoId { Task { await self.vm.playNext(id) } }
                            } label: {
                                Label("Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }

                            Button {
                                if let id = item.videoId { Task { await self.vm.addToQueue(id) } }
                            } label: {
                                Label("Queue", systemImage: "plus")
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        self.playSearchResultButton(item)
                        self.playNextButton(item)
                        Button("Add to Queue", systemImage: "plus") {
                            if let id = item.videoId { Task { await self.vm.addToQueue(id) } }
                        }
                    }
                }
            } header: {
                Text("Search")
            }

            // Up Next: toggle between Home recommendations and the current
            // video's related list. Both play by video ID on the backend.
            Section {
                Picker("Feed", selection: self.$feedRaw) {
                    ForEach(Feed.allCases, id: \.rawValue) { feed in
                        Text(feed.rawValue).tag(feed.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let items = self.feed == .recommended ? self.vm.recommended : self.vm.suggestions
                if items.isEmpty {
                    Text(self.feed == .recommended ? "No recommendations yet" : "Play a video to see related")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            Task {
                                if self.feed == .recommended {
                                    await self.vm.playRecommended(item)
                                } else {
                                    await self.vm.playSuggestion(item, at: index)
                                }
                            }
                        } label: {
                            VideoRow(
                                item: item,
                                highlighted: item.videoId != nil && item.videoId == self.vm.player?.video?.videoId
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            self.playNextButton(item)
                            Button("Add to Queue", systemImage: "plus") {
                                if let id = item.videoId { Task { await self.vm.addToQueue(id) } }
                            }
                        }
                    }
                }
            } header: {
                Text("Up Next")
            }

            if !self.vm.queue.isEmpty {
                Section("Queue") {
                    ForEach(self.vm.queue) { item in
                        VideoRow(item: item)
                            .contextMenu {
                                self.playNextButton(item)
                                self.removeButton(item)
                            }
                            .swipeActions {
                                self.removeButton(item)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: self.searchText) { _, value in self.scheduleSearch(value) }
        .onDisappear {
            self.searchDebounce?.cancel()
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    Task {
                        await self.vm.refreshFast()
                        await self.vm.refreshSuggestions()
                        await self.vm.refreshRecommended()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh recommendations and queue")
                Button {
                    Task { await self.vm.clearQueue() }
                } label: {
                    Label("Clear Queue", systemImage: "trash")
                }
                .help("Clear the entire queue")
                .disabled(self.vm.queue.isEmpty)
            }
        }
    }

    private func scheduleSearch(_ value: String) {
        self.searchDebounce?.cancel()
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.looksLikeVideo(text) else {
            self.vm.clearSearchResults()
            return
        }
        self.searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self.vm.search(text)
        }
    }

    private func searchNow() {
        self.searchDebounce?.cancel()
        let text = self.trimmedSearch
        guard !text.isEmpty, !Self.looksLikeVideo(text) else { return }
        Task { await self.vm.search(text) }
    }

    private func submitSearchField() {
        if self.searchLooksPlayable {
            self.openSearchText()
        } else {
            self.searchNow()
        }
    }

    private func openSearchText() {
        let text = self.trimmedSearch
        guard !text.isEmpty else { return }
        Task { await self.vm.openVideo(text) }
    }

    private func queueSearchText(next: Bool) {
        let text = self.trimmedSearch
        guard !text.isEmpty, Self.looksLikeVideo(text) else { return }
        Task { next ? await self.vm.playNext(text) : await self.vm.addToQueue(text) }
    }

    private func clearSearch() {
        self.searchDebounce?.cancel()
        self.searchText = ""
        self.vm.clearSearchResults()
    }

    private func playSearchResult(_ item: QueueItem) {
        Task { await self.vm.playSearchResult(item) }
    }

    private func playSearchResultButton(_ item: QueueItem) -> some View {
        Button("Play", systemImage: "play.fill") {
            self.playSearchResult(item)
        }
    }

    private func playNextButton(_ item: QueueItem) -> some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            if let id = item.videoId { Task { await self.vm.playNext(id) } }
        }
    }

    private func removeButton(_ item: QueueItem) -> some View {
        Button("Remove", systemImage: "trash", role: .destructive) {
            Task { await self.vm.removeQueueItem(item) }
        }
    }

    private static func looksLikeVideo(_ text: String) -> Bool {
        if text.contains("youtube.com") || text.contains("youtu.be") || text.contains("/") { return true }
        return text.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

// Rich video row: thumbnail with duration badge, title, channel.
// `highlighted` overrides the server's is_current flag for lists that don't
// carry it (related/recommended), matching against the playing video instead.
private struct VideoRow: View {
    let item: QueueItem
    var highlighted: Bool?

    private var isNowPlaying: Bool { self.highlighted ?? (self.item.isCurrent == true) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailImage(urlString: self.item.thumbnailUrl)

                switch VideoDurationLabel(self.item) {
                case .live:
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                case .duration(let text):
                    Text(text)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                case .none:
                    EmptyView()
                }

                if self.isNowPlaying {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: 92, height: 52)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if self.isNowPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(self.item.title ?? self.item.videoId ?? "Untitled")
                        .font(.callout.weight(self.isNowPlaying ? .semibold : .regular))
                        .lineLimit(2)
                }
                if let author = self.item.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(self.isNowPlaying ? 0.14 : 0))
        )
        .padding(.horizontal, -5)
    }
}
