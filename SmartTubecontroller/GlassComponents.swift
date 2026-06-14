//
//  GlassComponents.swift
//  SmartTubecontroller
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    static func decoded(from data: Data) -> PlatformImage? {
        #if os(macOS)
        NSImage(data: data)
        #else
        UIImage(data: data)
        #endif
    }
}

// A 0...1 fraction rendered as a whole-number percent ("0"..."100"), the readout
// shared by the TV/player volume capsules and the collapsed control-island button.
func percentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))"
}

// The whole-number percent (0...100) for a 0...1 fraction, used when committing a
// scrub value back to the view model.
func percentValue(_ fraction: Double) -> Int {
    Int((fraction * 100).rounded())
}

// The LIVE-vs-duration decision shared by the queue/recommendation rows and the
// search-results rows. The two call sites render the result differently (an
// overlay badge vs. trailing text), so this only unifies which label to show.
enum VideoDurationLabel: Equatable {
    case live
    case duration(String)

    init?(_ item: QueueItem) {
        if item.isLive == true {
            self = .live
        } else if let ms = item.durationMs, ms > 0 {
            self = .duration(SmartTubeControllerViewModel.formatTime(ms))
        } else {
            return nil
        }
    }
}

enum PlayerGlassButtonSize {
    case secondary
    case primary
    case play

    var diameter: CGFloat {
        switch self {
        case .secondary: 48
        case .primary: 62
        case .play: 88
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .secondary: 17
        case .primary: 23
        case .play: 36
        }
    }

    var iconWeight: Font.Weight {
        switch self {
        case .secondary: .semibold
        case .primary, .play: .bold
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .secondary: 8
        case .primary: 11
        case .play: 15
        }
    }

    var fillOpacity: Double {
        switch self {
        case .secondary: 0.05
        case .primary: 0.08
        case .play: 0.10
        }
    }

    var glassTintOpacity: Double {
        switch self {
        case .secondary: 0.02
        case .primary: 0.045
        case .play: 0.065
        }
    }
}

struct PlayerGlassButtonStyle: ButtonStyle {
    let size: PlayerGlassButtonSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: self.size.iconSize, weight: self.size.iconWeight))
            .foregroundStyle(.white)
            .frame(width: self.size.diameter, height: self.size.diameter)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? self.size.fillOpacity + 0.05 : self.size.fillOpacity))
            }
            .glassEffect(.clear.interactive().tint(.white.opacity(configuration.isPressed ? self.size.glassTintOpacity + 0.05 : self.size.glassTintOpacity)), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.62 : 0.38), lineWidth: 1.1)
            }
            .overlay(alignment: .top) {
                Circle()
                    .trim(from: 0.07, to: 0.43)
                    .stroke(.white.opacity(configuration.isPressed ? 0.18 : 0.42), lineWidth: 1.35)
                    .frame(width: self.size.diameter - 6, height: self.size.diameter - 6)
                    .blur(radius: 0.25)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .trim(from: 0.56, to: 0.80)
                    .stroke(.black.opacity(configuration.isPressed ? 0.06 : 0.16), lineWidth: 1.2)
                    .frame(width: self.size.diameter - 5, height: self.size.diameter - 5)
                    .blur(radius: 0.35)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.38), radius: self.size.shadowRadius, y: self.size.shadowRadius * 0.24)
            .shadow(color: .white.opacity(0.16), radius: 1.5, y: -0.8)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

// Reports the window's titlebar+toolbar height (frame minus contentLayoutRect).
// The split-view detail gets no top safe-area inset on macOS 26, so views that
// shouldn't sit under the glass toolbar pad themselves down by this amount.
#if os(macOS)
struct TitlebarHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.report(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { self.report(view) }
    }

    private func report(_ view: NSView) {
        guard let window = view.window else { return }
        let measured = window.frame.height - window.contentLayoutRect.height
        if abs(measured - self.height) > 0.5 {
            self.height = measured
        }
    }
}
#endif

struct HomeTheaterGlassCapsule: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(.white.opacity(0.035))
            }
            .glassEffect(.clear.interactive().tint(self.tint ?? .white.opacity(0.025)), in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .trim(from: 0.06, to: 0.42)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
                    .padding(2)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.24), radius: 7, y: 2)
    }
}

extension View {
    func homeTheaterGlassCapsule(tint: Color? = nil) -> some View {
        self.modifier(HomeTheaterGlassCapsule(tint: tint))
    }
}

// A thick, draggable capsule track used for the scrubber and the volume bar.
// Reports the drag fraction live (onScrub) and on release (onCommit).
// `markers` (0...1 fractions) renders chapter tick gaps along the track.
struct GlassTrack: View {
    var progress: Double
    var markers: [Double] = []
    var onScrub: (Double) -> Void
    var onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(self.progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule().fill(.white).frame(width: geo.size.width * clamped)
                ForEach(self.markers.filter { $0 > 0 && $0 < 1 }, id: \.self) { fraction in
                    // Dark notch so it reads on both the played and unplayed side.
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * fraction - 0.75)
                }
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        self.onScrub(min(max(value.location.x / geo.size.width, 0), 1))
                    }
                    .onEnded { value in
                        self.onCommit(min(max(value.location.x / geo.size.width, 0), 1))
                    }
            )
        }
        .frame(height: 6)
    }
}

// MARK: - Shared building blocks

// A glass capsule hosting a scrubbable track with a trailing numeric readout —
// the shape shared by the TV volume, player volume, and SUB/REAR level rows.
struct GlassSliderCapsule<Leading: View>: View {
    let progress: Double
    let valueText: String
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 12) {
            self.leading()
            GlassTrack(progress: self.progress, onScrub: self.onScrub, onCommit: self.onCommit)
                .frame(maxWidth: .infinity)
            Text(self.valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .homeTheaterGlassCapsule()
    }
}

extension GlassSliderCapsule where Leading == EmptyView {
    init(progress: Double, valueText: String, onScrub: @escaping (Double) -> Void, onCommit: @escaping (Double) -> Void) {
        self.init(progress: progress, valueText: valueText, onScrub: onScrub, onCommit: onCommit) { EmptyView() }
    }
}

// Rounded video thumbnail with a neutral placeholder while loading / on failure.
struct ThumbnailImage: View {
    let urlString: String?
    var width: CGFloat = 92
    var height: CGFloat = 52
    var cornerRadius: CGFloat = 6
    @State private var cachedImage: PlatformImage?

    var body: some View {
        Group {
            if let cachedImage {
                Image(platformImage: cachedImage)
                    .resizable()
                    .scaledToFill()
            } else if self.thumbnailURL != nil {
                self.placeholder
            } else {
                ZStack {
                    self.placeholder
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: self.width, height: self.height)
        .clipShape(RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous))
        .task(id: self.urlString) {
            guard let url = self.thumbnailURL else {
                self.cachedImage = nil
                return
            }
            self.cachedImage = await ThumbnailImageCache.shared.image(for: url)
        }
    }

    private var thumbnailURL: URL? {
        guard let raw = self.urlString, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var placeholder: some View {
        Rectangle().fill(Color(white: 0.15))
    }
}

private final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()

    private init() {
        self.cache.countLimit = 500
        self.cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) async -> PlatformImage? {
        let key = url as NSURL
        if let cached = self.cache.object(forKey: key) {
            return cached
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode)
            else {
                return nil
            }

            guard let image = PlatformImage.decoded(from: data) else { return nil }

            self.cache.setObject(image, forKey: key, cost: data.count)
            return image
        } catch {
            return nil
        }
    }
}

// MARK: - Platform-abstracted modifiers

extension View {
    @ViewBuilder func platformHelp(_ text: String) -> some View {
        #if os(macOS)
        self.help(text)
        #else
        self
        #endif
    }

    @ViewBuilder func platformKeyboardShortcut(_ shortcut: KeyboardShortcut) -> some View {
        #if os(macOS)
        self.keyboardShortcut(shortcut)
        #else
        self
        #endif
    }

    @ViewBuilder func platformKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        #if os(macOS)
        self.keyboardShortcut(key, modifiers: modifiers)
        #else
        self
        #endif
    }

    @ViewBuilder func platformNavigationSubtitle(_ subtitle: String) -> some View {
        #if os(macOS)
        self.navigationSubtitle(subtitle)
        #else
        self
        #endif
    }

    @ViewBuilder func platformOnExitCommand(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }

    @ViewBuilder func platformTitlebarReader(height: Binding<CGFloat>) -> some View {
        #if os(macOS)
        self.background(TitlebarHeightReader(height: height))
        #else
        self
        #endif
    }
}

extension Scene {
    func platformDefaultSize(width: CGFloat, height: CGFloat) -> some Scene {
        #if os(macOS)
        self.defaultSize(width: width, height: height)
        #else
        self
        #endif
    }

    func platformWindowResizability(_ resizability: WindowResizability) -> some Scene {
        #if os(macOS)
        self.windowResizability(resizability)
        #else
        self
        #endif
    }
}
