import Cocoa
import SwiftUI
import Combine

enum HUDState: Equatable {
    case idle
    /// `pending` : dictées déjà relâchées qui attendent encore d'être transcrites ou
    /// collées. Non nul quand l'utilisateur enchaîne un vocal sans attendre le précédent.
    case recording(pending: Int)
    case transcribing(pending: Int)
    /// Telechargement du modele Whisper au premier usage ou apres un changement de modele.
    /// Progression de 0 a 1, ou nil quand la taille totale n'est pas connue.
    case downloading(progress: Double?)
    case done
    /// Le texte est bien transcrit mais n'a pas pu etre colle : il attend dans le
    /// presse-papier. Ce n'est PAS une erreur, l'utilisateur n'a qu'a faire Cmd+V.
    case clipboard(reason: String)
    case error(message: String)
}

@MainActor
final class HUDController {
    private var window: NSPanel?
    private let state = CurrentValueSubject<HUDState, Never>(.idle)
    let levelSubject = CurrentValueSubject<Float, Never>(0)
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Etat a retrouver quand un message ephemere expire. Sans lui, le HUD se cache apres
    /// un « Colle » alors qu'une autre dictee est encore en file : le travail en cours
    /// devenait invisible. `nil` = plus rien a montrer, on cache.
    private var background: HUDState?

    /// Definit l'etat de fond SANS l'afficher tout de suite. Un message ephemere en cours
    /// garde la main jusqu'a son expiration, puis cede la place a ce fond.
    func setBackground(_ state: HUDState?) {
        background = state
        // Aucun message ephemere en attente : le fond prend effet immediatement.
        if hideTask == nil {
            if let state { show(state: state, asBackground: true) } else { hide() }
        }
    }

    func bindLevels(_ publisher: AnyPublisher<Float, Never>) {
        publisher.receive(on: RunLoop.main).sink { [weak self] in
            self?.levelSubject.send($0)
        }.store(in: &cancellables)
    }

    func show(state newState: HUDState) {
        show(state: newState, asBackground: false)
    }

    private func show(state newState: HUDState, asBackground: Bool) {
        hideTask?.cancel()
        hideTask = nil
        if asBackground { background = newState }
        if window == nil { buildWindow() }
        state.send(newState)

        guard let window else { return }
        resize(window, to: newState.preferredWidth)
        positionAtBottomCenter(window)
        window.orderFrontRegardless()

        // Un message que l'utilisateur doit lire reste plus longtemps qu'un simple
        // accuse de reception. Le telechargement, lui, ne se cache jamais tout seul.
        let delay: TimeInterval?
        switch newState {
        case .done: delay = 1.4
        case .error: delay = 2.6
        case .clipboard: delay = 3.4
        case .idle, .recording, .transcribing, .downloading: delay = nil
        }
        if let delay {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.hideTask = nil
                // Retour au travail de fond s'il en reste, sinon on s'efface.
                if let background = self.background {
                    self.show(state: background, asBackground: true)
                } else {
                    self.hide()
                }
            }
        } else {
            background = newState
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        background = nil
        window?.orderOut(nil)
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: HUDState.idle.preferredWidth, height: 52)
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

    private func resize(_ window: NSWindow, to width: CGFloat) {
        guard window.frame.size.width != width else { return }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: false)
        window.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Affiche le HUD sur l'ecran ou se trouve reellement l'utilisateur. `NSScreen.main`
    /// designe l'ecran de la fenetre active : pour une app en `.accessory`, qui n'a jamais
    /// le focus, cela renvoie l'ecran principal, pas celui ou l'on est en train de dicter.
    private func positionAtBottomCenter(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 48
        )
        window.setFrameOrigin(origin)
    }
}

private extension HUDState {
    /// Les etats porteurs d'un message a lire ont besoin de plus de place que
    /// « J'ecoute » ou « Colle ».
    var preferredWidth: CGFloat {
        switch self {
        case .idle, .done: return 240
        case .recording(let pending), .transcribing(let pending): return pending > 0 ? 268 : 240
        case .downloading: return 260
        case .clipboard, .error: return 320
        }
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
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                trailingDetail
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 52)
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
        case .downloading(let progress):
            DownloadIndicator(progress: progress)
                .frame(width: 22, height: 22)
        case .done:
            ZStack {
                Circle().fill(VPPalette.ok.opacity(0.16))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(VPPalette.ok)
            }
            .frame(width: 22, height: 22)
        case .clipboard:
            ZStack {
                Circle().fill(VPPalette.accent.opacity(0.16))
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VPPalette.accent)
            }
            .frame(width: 22, height: 22)
        case .error:
            ZStack {
                Circle().fill(VPPalette.live.opacity(0.16))
                Image(systemName: "exclamationmark")
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
                .truncationMode(.tail)
        }
    }

    private var title: String {
        switch observer.state {
        case .idle: return "VoxPrompt"
        case .recording: return "J'écoute"
        case .transcribing: return "Transcription"
        case .downloading: return "Téléchargement"
        case .done: return "Collé"
        case .clipboard: return "Presse-papier"
        case .error: return "Erreur"
        }
    }

    private var subtitle: String {
        switch observer.state {
        case .idle: return ""
        case .recording(let pending):
            return pending > 0 ? "\(pending) en attente derrière" : "relâche pour transcrire"
        case .transcribing(let pending):
            return pending > 0 ? "\(pending) autre(s) en file" : "whisper"
        case .downloading(let progress):
            guard let progress else { return "modèle Whisper" }
            return "\(Int(progress * 100)) %"
        case .done: return "dans l'app active"
        case .clipboard(let reason): return reason
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

/// Anneau de progression du telechargement. Retombe sur l'indicateur indetermine
/// tant que la taille totale n'est pas connue.
private struct DownloadIndicator: View {
    var progress: Double?

    var body: some View {
        if let progress {
            ZStack {
                Circle()
                    .stroke(VPPalette.accent.opacity(0.18), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(VPPalette.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
            .padding(3)
        } else {
            ProgressIndicator()
        }
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
