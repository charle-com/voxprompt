import Cocoa
import SwiftUI
import Combine

enum HUDState: Equatable {
    case idle
    case recording
    case transcribing
    case done
    case error(message: String)
}

@MainActor
final class HUDController {
    private var window: NSPanel?
    private let state = CurrentValueSubject<HUDState, Never>(.idle)
    let levelSubject = CurrentValueSubject<Float, Never>(0)
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func bindLevels(_ publisher: AnyPublisher<Float, Never>) {
        publisher.receive(on: RunLoop.main).sink { [weak self] in
            self?.levelSubject.send($0)
        }.store(in: &cancellables)
    }

    func show(state newState: HUDState) {
        hideTask?.cancel()
        if window == nil { buildWindow() }
        state.send(newState)

        guard let window else { return }
        positionAtBottomCenter(window)
        window.orderFrontRegardless()

        switch newState {
        case .done, .error:
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if !Task.isCancelled { self?.hide() }
            }
        default: break
        }
    }

    func hide() { window?.orderOut(nil) }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 240, height: 52)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: HUDView(stateStream: state, levelStream: levelSubject))
        hosting.frame = rect
        panel.contentView = hosting
        window = panel
    }

    private func positionAtBottomCenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 48
        )
        window.setFrameOrigin(origin)
    }
}

private struct HUDView: View {
    @StateObject private var observer: HUDObserver
    @StateObject private var levels: LevelObserver

    init(stateStream: CurrentValueSubject<HUDState, Never>,
         levelStream: CurrentValueSubject<Float, Never>) {
        _observer = StateObject(wrappedValue: HUDObserver(stream: stateStream))
        _levels = StateObject(wrappedValue: LevelObserver(stream: levelStream))
    }

    var body: some View {
        ZStack {
            // Fond capsule unique, propre
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(VPPalette.hudFill))
                .overlay(Capsule().strokeBorder(VPPalette.hudBorder, lineWidth: 1))

            HStack(spacing: 12) {
                stateIndicator
                Text(title)
                    .font(VPType.body(13, weight: .medium))
                    .foregroundStyle(VPPalette.textPrimary)
                Spacer(minLength: 8)
                trailingDetail
            }
            .padding(.horizontal, 18)
        }
        .frame(width: 240, height: 52)
        .clipShape(Capsule())  // clip dur pour éviter tout débordement
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .animation(.easeOut(duration: 0.25), value: observer.state)
    }

    // MARK: Left indicator

    @ViewBuilder private var stateIndicator: some View {
        switch observer.state {
        case .recording:
            waveform
                .frame(width: 22, height: 22)
        case .transcribing:
            ProgressIndicator()
                .frame(width: 22, height: 22)
        case .done:
            ZStack {
                Circle().fill(VPPalette.ok.opacity(0.16))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(VPPalette.ok)
            }
            .frame(width: 22, height: 22)
        case .error:
            ZStack {
                Circle().fill(VPPalette.live.opacity(0.16))
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(VPPalette.live)
            }
            .frame(width: 22, height: 22)
        case .idle:
            Circle()
                .fill(VPPalette.textFaint)
                .frame(width: 8, height: 8)
                .frame(width: 22, height: 22)
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                WaveBar(level: levels.value, index: i)
            }
        }
        .frame(maxHeight: 18)
    }

    // MARK: Trailing

    @ViewBuilder private var trailingDetail: some View {
        switch observer.state {
        case .recording:
            Text(subtitle)
                .font(VPType.mono(10))
                .foregroundStyle(VPPalette.textTert)
        case .idle:
            EmptyView()
        default:
            Text(subtitle)
                .font(VPType.body(12))
                .foregroundStyle(VPPalette.textSecond)
                .lineLimit(1)
        }
    }

    private var title: String {
        switch observer.state {
        case .idle: return "VoxPrompt"
        case .recording: return "J'écoute"
        case .transcribing: return "Transcription"
        case .done: return "Collé"
        case .error: return "Erreur"
        }
    }

    private var subtitle: String {
        switch observer.state {
        case .idle: return ""
        case .recording: return "relâche pour transcrire"
        case .transcribing: return "whisper"
        case .done: return "dans le presse-papier"
        case .error(let m): return m
        }
    }
}

private struct WaveBar: View {
    var level: Float
    var index: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            let offset = sin(time * 6 + Double(index) * 0.8)
            let base = CGFloat(max(0.08, level))
            let variation = CGFloat(offset) * 0.35 * base
            let h = max(3, min(16, 4 + (base + variation) * 12))
            Capsule()
                .fill(VPPalette.hudBar)
                .frame(width: 2.5, height: h)
        }
    }
}

private struct ProgressIndicator: View {
    @State private var rotation: Double = 0
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                LinearGradient(colors: [VPPalette.accent, VPPalette.accent.opacity(0.1)],
                               startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .padding(3)
    }
}

@MainActor
private final class HUDObserver: ObservableObject {
    @Published var state: HUDState = .idle
    private var cancellable: AnyCancellable?
    init(stream: CurrentValueSubject<HUDState, Never>) {
        cancellable = stream.receive(on: RunLoop.main).sink { [weak self] in self?.state = $0 }
    }
}

@MainActor
private final class LevelObserver: ObservableObject {
    @Published var value: Float = 0
    private var cancellable: AnyCancellable?
    init(stream: CurrentValueSubject<Float, Never>) {
        cancellable = stream.receive(on: RunLoop.main).sink { [weak self] in self?.value = $0 }
    }
}
