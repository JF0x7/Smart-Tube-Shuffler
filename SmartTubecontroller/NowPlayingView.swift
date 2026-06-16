//
//  NowPlayingView.swift
//  SmartTubecontroller
//

import SwiftUI

// MARK: - Now Playing (detail) — Liquid Glass media surface

struct NowPlayingView: View {
    @ObservedObject var vm: SmartTubeControllerViewModel
    @State private var videoText = ""
    @State private var seekValue: Double = 0
    @State private var isDraggingSeek = false
    @State private var volume: Double = 0.8
    @State private var isDraggingVolume = false
    @State private var playerVolume: Double = 1.0
    @State private var isDraggingPlayerVolume = false
    @State private var subwooferLevel: Double = 8
    @State private var rearLevel: Double = 8
    @State private var immersiveAE = false
    @State private var soundMode: SmartTubeSoundMode = .cinema
    @State private var controlsExpanded = false
    @State private var titlebarHeight: CGFloat = 0
    @State private var searchDebounce: Task<Void, Never>?
    @Namespace private var controlsGlassNamespace

    private var isEmpty: Bool { self.videoText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 14) {
            self.stage
            self.playBar
        }
        .padding(16)
        // The split-view detail reports no top safe-area inset on macOS 26, so the
        // content would otherwise draw beneath the Liquid Glass toolbar. Measure the
        // titlebar+toolbar height from the window and pad the card down past it.
        .padding(.top, self.titlebarHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .platformTitlebarReader(height: self.$titlebarHeight)
        .onChange(of: self.vm.positionMs) { _, newValue in
            if !self.isDraggingSeek { self.seekValue = Double(newValue) }
        }
        .onChange(of: self.vm.theater?.volume) { _, newValue in
            if !self.isDraggingVolume, let tv = newValue { self.volume = Double(tv) / 100.0 }
        }
        .onChange(of: self.vm.player?.volume) { _, newValue in
            if !self.isDraggingPlayerVolume, let v = newValue { self.playerVolume = min(max(v, 0), 1) }
        }
        .onChange(of: self.vm.cec) { _, newValue in self.syncLevels(newValue) }
        .onAppear {
            self.volume = Double(self.vm.theater?.volume ?? 50) / 100.0
            self.syncLevels(self.vm.cec)
        }
    }

    private func syncLevels(_ cec: SmartTubeCECState?) {
        if let sub = cec?.subwooferLevel { self.subwooferLevel = Double(sub) }
        if let rear = cec?.rearLevel { self.rearLevel = Double(rear) }
        if let immersive = cec?.immersiveAEEnabled { self.immersiveAE = immersive }
        if let mode = cec?.soundMode { self.soundMode = mode }
    }

    // The artwork "stage": fills all available space, with glass controls floating on top.
    private var stage: some View {
        ZStack {
            self.artworkFill
            LinearGradient(
                colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )
            GeometryReader { proxy in
                let compact = proxy.size.height < 620 || proxy.size.width < 900
                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        self.topControlGroup(maxWidth: proxy.size.width - (compact ? 32 : 44))
                    }

                    Spacer(minLength: compact ? 12 : 24)

                    self.transportCluster
                        .scaleEffect((compact ? 0.86 : 1) * 1.5)

                    Spacer(minLength: compact ? 12 : 24)

                    VStack(spacing: compact ? 8 : 12) {
                        HStack(alignment: .bottom) {
                            self.titleOverlay
                            Spacer(minLength: 24)
                            if !self.vm.chapters.isEmpty {
                                self.chapterMenu
                            }
                        }
                        .padding(.horizontal, compact ? 28 : 44)

                        self.scrubber
                            .padding(.horizontal, compact ? 22 : 30)
                            .padding(.vertical, compact ? 8 : 10)
                            .glassEffect(.clear.interactive().tint(.white.opacity(0.05)), in: .capsule)
                            .overlay {
                                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            }
                            .padding(.horizontal, compact ? 18 : 28)

                    }
                    .padding(.bottom, compact ? 8 : 16)
                }
                .padding(compact ? 16 : 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var titleOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.vm.subtitle.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
            Text(self.vm.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .shadow(color: .black.opacity(0.85), radius: 8, y: 2)
    }

    private func topControlGroup(maxWidth: CGFloat) -> some View {
        let preferred: CGFloat = self.vm.playerVolumeEnabled ? 330 : 306
        let islandWidth = max(220, min(preferred, maxWidth))
        return GlassEffectContainer(spacing: 10) {
            if self.controlsExpanded {
                VStack(alignment: .trailing, spacing: 0) {
                    self.controlIslandHeader
                    VStack(spacing: 9) {
                        controlIslandRow(icon: "speaker.wave.3.fill", label: "TV") {
                            self.volumeCapsule
                        }
                        if self.vm.playerVolumeEnabled {
                            controlIslandRow(icon: "dial.medium", label: "Player") {
                                self.playerVolumeCapsule
                            }
                        }
                        controlIslandRow(icon: "hifispeaker.fill", label: "Subwoofer") {
                            levelCapsule(value: self.$subwooferLevel) { level in
                                await self.vm.setSubwoofer(level)
                            }
                        }
                        controlIslandRow(icon: "speaker.wave.2.circle", label: "Rear") {
                            levelCapsule(value: self.$rearLevel) { level in
                                await self.vm.setRear(level)
                            }
                        }
                        controlIslandRow(icon: "music.note", label: "Mode") {
                            self.soundModeCapsule
                        }
                        controlIslandRow(icon: "airpodspro", label: "Spatial") {
                            self.immersiveCapsule
                        }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 2)
                }
                .frame(width: islandWidth)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 11)
                .background {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.white.opacity(0.018))
                }
                .glassEffect(.clear.interactive().tint(.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .glassEffectID("controls-island", in: self.controlsGlassNamespace)
                .glassEffectTransition(.matchedGeometry)
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .trim(from: 0.04, to: 0.34)
                        .stroke(.white.opacity(0.26), lineWidth: 1)
                        .padding(2)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.30), radius: 16, y: 5)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                    removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing))
                ))
            } else {
                self.controlIslandButton
                    .glassEffectID("controls-island", in: self.controlsGlassNamespace)
                    .glassEffectTransition(.matchedGeometry)
            }
        }
        .glassEffectUnion(id: "controls-union", namespace: self.controlsGlassNamespace)
        .animation(.smooth(duration: 0.26), value: self.controlsExpanded)
    }

    private var controlIslandButton: some View {
        Button {
            self.toggleControlIsland()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                Text(percentText(self.volume))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(0.72)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .homeTheaterGlassCapsule()
        .platformHelp("Expand playback controls")
    }

    private var controlIslandHeader: some View {
        Button {
            self.toggleControlIsland()
        } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(.white.opacity(0.42))
                    .frame(width: 28, height: 3)
                    .padding(.trailing, 3)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                Text("Audio Controls")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                Spacer(minLength: 10)
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .platformHelp("Collapse playback controls")
    }

    private func controlIslandRow<Content: View>(
        icon: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.4)
            }
            .foregroundStyle(.white.opacity(0.62))
            .frame(width: 76, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }

    private func toggleControlIsland() {
        withAnimation(.smooth(duration: 0.24)) {
            self.controlsExpanded.toggle()
        }
    }

    private var artworkFill: some View {
        ZStack {
            Rectangle().fill(.black)
            if let hiRes = self.vm.hiResThumbnailURL {
                // Try maxres (1280×720) first; not all videos have it, so fall back
                // to the API-provided thumbnail on failure.
                AsyncImage(url: hiRes) { phase in
                    if let image = phase.image {
                        self.artworkLayers(image)
                    } else {
                        self.apiArtwork
                    }
                }
            } else {
                self.apiArtwork
            }
        }
    }

    private var apiArtwork: some View {
        Group {
            if let url = self.vm.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        self.artworkLayers(image)
                    } else {
                        self.fallback
                    }
                }
            } else {
                self.fallback
            }
        }
    }

    private func artworkLayers(_ image: Image) -> some View {
        ZStack {
            image.resizable().scaledToFill().blur(radius: 44).opacity(0.55)
            image.resizable().scaledToFit()
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "play.tv")
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.25))
        }
    }

    // Draggable TV / audio-system volume bar (top-right capsule). Drives the TV's
    // actual volume, not the player's internal gain — internal volume is something
    // SmartTube re-applies per video and isn't what a remote should control.
    private var volumeIcon: String {
        if self.vm.theater?.muted == true { return "speaker.slash.fill" }
        return self.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }

    private var volumeCapsule: some View {
        GlassSliderCapsule(
            progress: self.volume,
            valueText: percentText(self.volume),
            onScrub: { fraction in
                self.isDraggingVolume = true
                self.volume = fraction
            },
            onCommit: { fraction in
                self.volume = fraction
                self.isDraggingVolume = false
                Task { await self.vm.setTVVolume(percent: percentValue(fraction)) }
            }
        ) {
            Button {
                Task { await self.vm.toggleTVMute() }
            } label: {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .platformHelp(self.vm.theater?.muted == true ? "Unmute TV" : "Mute TV")
        }
        .platformHelp("TV volume")
    }

    // Optional secondary control: ExoPlayer's internal volume (pre-amp gain).
    // Off by default; enabled via Settings → "Player volume as secondary control".
    private var playerVolumeCapsule: some View {
        GlassSliderCapsule(
            progress: self.playerVolume,
            valueText: percentText(self.playerVolume),
            onScrub: { fraction in
                self.isDraggingPlayerVolume = true
                self.playerVolume = fraction
            },
            onCommit: { fraction in
                self.playerVolume = fraction
                self.isDraggingPlayerVolume = false
                Task { await self.vm.setPlaybackVolume(percent: percentValue(fraction)) }
            }
        )
        .platformHelp("Player volume (internal pre-amp gain)")
    }

    private var soundModeCapsule: some View {
        Menu {
            ForEach(SmartTubeSoundMode.allCases, id: \.self) { mode in
                Button(mode.rawValue.capitalized) {
                    self.soundMode = mode
                    Task { await self.vm.setSoundMode(mode) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(self.soundMode.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .homeTheaterGlassCapsule()
    }

    private var immersiveCapsule: some View {
        Button {
            let next = !self.immersiveAE
            self.immersiveAE = next
            Task { await self.vm.setImmersive(next) }
        } label: {
            self.miniSwitch(on: self.immersiveAE)
        }
        .buttonStyle(.plain)
        .platformHelp(self.immersiveAE ? "Spatial audio on" : "Spatial audio off")
    }

    // A compact iOS-style on/off switch, sized to sit on the right of a control row.
    private func miniSwitch(on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color.accentColor : Color.white.opacity(0.18))
                .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                .frame(width: 42, height: 25)
            Circle()
                .fill(.white)
                .frame(width: 19, height: 19)
                .padding(3)
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
        }
        .animation(.smooth(duration: 0.2), value: on)
    }

    private func levelCapsule(value: Binding<Double>, action: @escaping (Double) async -> Void) -> some View {
        GlassSliderCapsule(
            progress: value.wrappedValue / 12.0,
            valueText: "\(Int(value.wrappedValue))",
            onScrub: { fraction in value.wrappedValue = (fraction * 12).rounded() },
            onCommit: { fraction in
                let level = (fraction * 12).rounded()
                value.wrappedValue = level
                Task { await action(level) }
            }
        )
    }

    private var transportCluster: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                glassButton("backward.end.fill", size: .secondary, help: "Previous") { await self.vm.previous() }
                glassButton("gobackward.10", size: .primary, help: "Back 10 seconds") { await self.vm.seekBy(seconds: -10) }
                Button {
                    Task { await self.vm.togglePlay() }
                } label: {
                    if self.vm.isBuffering {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                    } else {
                        Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .buttonStyle(PlayerGlassButtonStyle(size: .play))
                .platformHelp(self.vm.isBuffering ? "Buffering" : self.vm.isPlaying ? "Pause" : "Play")
                glassButton("goforward.10", size: .primary, help: "Forward 10 seconds") { await self.vm.seekBy(seconds: 10) }
                glassButton("forward.end.fill", size: .secondary, help: "Next") { await self.vm.next() }
            }
            .controlSize(.large)
        }
    }

    private func glassButton(
        _ symbol: String,
        size: PlayerGlassButtonSize,
        help: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(PlayerGlassButtonStyle(size: size))
        .platformHelp(help)
    }

    // Current chapter pill: shows where the playhead is, opens a jump menu.
    private var chapterMenu: some View {
        Menu {
            ForEach(self.vm.chapters) { chapter in
                Button {
                    Task { await self.vm.seek(ms: chapter.startMs) }
                } label: {
                    if chapter.id == self.vm.currentChapter?.id {
                        Label(self.chapterMenuTitle(chapter), systemImage: "speaker.wave.2.fill")
                    } else {
                        Text(self.chapterMenuTitle(chapter))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                Text(self.vm.currentChapter?.title ?? "Chapters")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 220)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .homeTheaterGlassCapsule()
        .platformHelp("Jump to a chapter")
    }

    private func chapterMenuTitle(_ chapter: ChapterItem) -> String {
        "\(SmartTubeControllerViewModel.formatTime(chapter.startMs))   \(chapter.title ?? "Chapter")"
    }

    private var scrubber: some View {
        let duration = Double(max(self.vm.durationMs, 1))
        return HStack(spacing: 12) {
            Text(SmartTubeControllerViewModel.formatTime(Int(self.seekValue)))
                .foregroundStyle(.white.opacity(0.7))
            GlassTrack(
                progress: self.seekValue / duration,
                markers: self.vm.chapters.map { Double($0.startMs) / duration },
                onScrub: { fraction in
                    self.isDraggingSeek = true
                    self.seekValue = fraction * duration
                },
                onCommit: { fraction in
                    self.seekValue = fraction * duration
                    self.isDraggingSeek = false
                    Task { await self.vm.seek(ms: Int(self.seekValue)) }
                }
            )
            Text("−" + SmartTubeControllerViewModel.formatTime(max(self.vm.durationMs - Int(self.seekValue), 0)))
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.caption.monospacedDigit())
    }

    // Single smart field: a URL/ID plays directly; anything else searches as you
    // type and shows a results picker floating above the bar.
    private var playBar: some View {
        HStack(spacing: 10) {
            Image(systemName: self.vm.isSearching ? "magnifyingglass" : "play.circle")
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
            TextField("Play a YouTube URL, video ID, or search…", text: self.$videoText)
                .textFieldStyle(.plain)
                .onSubmit { self.submit() }
            if !self.isEmpty {
                Button {
                    self.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .platformHelp("Clear")
                Button(Self.looksLikeVideo(self.videoText.trimmingCharacters(in: .whitespaces)) ? "Play" : "Search") {
                    self.submit()
                }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                if Self.looksLikeVideo(self.videoText.trimmingCharacters(in: .whitespaces)) {
                    Menu {
                        Button("Add to Queue") { self.queue(next: false) }
                        Button("Play Next") { self.queue(next: true) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .platformHelp("Queue options")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .overlay(alignment: .top) {
            if self.searchPanelVisible {
                self.searchResultsPanel
                    // Anchor the panel's bottom edge just above the bar's top edge,
                    // so it floats over the stage without disturbing layout.
                    .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 10 }
            }
        }
        .onChange(of: self.videoText) { _, text in self.scheduleSearch(text) }
        .platformOnExitCommand { self.clearSearch() }
        .animation(.smooth(duration: 0.2), value: self.searchPanelVisible)
    }

    private var searchPanelVisible: Bool {
        !self.isEmpty && (self.vm.isSearching || !self.vm.searchResults.isEmpty || self.vm.searchError != nil)
    }

    private var searchResultsPanel: some View {
        Group {
            if let error = self.vm.searchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if self.vm.searchResults.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(self.vm.searchResults) { item in
                            SearchResultRow(item: item) {
                                self.playResult(item)
                            } queueAction: { next in
                                guard let id = item.videoId else { return }
                                Task { next ? await self.vm.playNext(id) : await self.vm.addToQueue(id) }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(self.vm.searchResults.count) * 52 + 12, 312))
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func playResult(_ item: QueueItem) {
        guard let id = item.videoId else { return }
        self.clearSearch()
        Task { await self.vm.playVideoId(id) }
    }

    private func clearSearch() {
        self.searchDebounce?.cancel()
        self.videoText = ""
        self.vm.clearSearchResults()
    }

    private func scheduleSearch(_ text: String) {
        self.searchDebounce?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !Self.looksLikeVideo(trimmed) else {
            self.vm.clearSearchResults()
            return
        }
        self.searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self.vm.search(trimmed)
        }
    }

    private func submit() {
        let v = self.videoText.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        Task {
            if Self.looksLikeVideo(v) {
                self.clearSearch()
                await self.vm.openVideo(v)
            } else {
                await self.vm.search(v)
            }
        }
    }

    private func queue(next: Bool) {
        let v = self.videoText.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        self.videoText = ""
        Task { next ? await self.vm.playNext(v) : await self.vm.addToQueue(v) }
    }

    private static func looksLikeVideo(_ text: String) -> Bool {
        if text.contains("youtube.com") || text.contains("youtu.be") || text.contains("/") { return true }
        return text.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

// One row in the search-results picker: thumbnail, title/channel, duration.
// Click plays; right-click (or the hover ellipsis) queues.
private struct SearchResultRow: View {
    let item: QueueItem
    let playAction: () -> Void
    let queueAction: (_ next: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: self.playAction) {
            HStack(spacing: 10) {
                ThumbnailImage(urlString: self.item.thumbnailUrl, width: 71, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.item.title ?? "Untitled")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(self.item.author ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if self.hovering {
                    Menu {
                        self.queueMenuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    switch VideoDurationLabel(self.item) {
                    case .live:
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    case .duration(let text):
                        Text(text)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    case .none:
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.primary.opacity(self.hovering ? 0.08 : 0))
        )
        .onHover { self.hovering = $0 }
        .contextMenu {
            self.queueMenuItems
        }
    }

    @ViewBuilder private var queueMenuItems: some View {
        Button("Add to Queue") { self.queueAction(false) }
        Button("Play Next") { self.queueAction(true) }
    }
}
