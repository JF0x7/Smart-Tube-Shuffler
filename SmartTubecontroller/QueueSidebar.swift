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
    private var feed: Feed { Feed(rawValue: self.feedRaw) ?? .recommended }

    var body: some View {
        List {
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

                if self.item.isLive == true {
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                } else if let ms = self.item.durationMs, ms > 0 {
                    Text(SmartTubeControllerViewModel.formatTime(ms))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
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
