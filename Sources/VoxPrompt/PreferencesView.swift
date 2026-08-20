import SwiftUI
import ApplicationServices

/// État partagé entre l'AppDelegate et le panneau de préférences : ce que la vue ne
/// peut pas lire elle-même (statut du moteur de transcription, liste des micros).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Description courte de l'état du moteur, affichée sous le modèle.
    @Published var engineStatus: String = "Chargement…"
    /// true tant que le moteur n'est pas prêt (chargement, téléchargement, échec).
    @Published var engineBusy: Bool = true
    /// Micros disponibles, rafraîchis à l'ouverture du panneau.
    @Published var inputDevices: [AudioRecorder.InputDevice] = []
}

struct PreferencesView: View {
    let onHotkeyChange: (HotkeyBinding) -> Void
    var onModelChange: (String) -> Void = { _ in }
    var onQuit: () -> Void = { NSApp.terminate(nil) }

    @ObservedObject private var permissions = PermissionMonitor.shared
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var updates = UpdateChecker.shared

    @State private var selectedHotkey: HotkeyBinding = Settings.shared.hotkey
    @State private var selectedModel: String = Settings.shared.modelIdentifier
    @State private var selectedPasteMode: PasteMode = Settings.shared.pasteMode
    @State private var selectedInputUID: String = Settings.shared.preferredInputUID ?? ""
    @State private var glossary: String = Settings.shared.glossary
    @State private var launchAtLogin: Bool = LoginItem.isEnabled
    @State private var loginNeedsApproval: Bool = LoginItem.requiresApproval
    @State private var streamingEnabled: Bool = Settings.shared.streamingEnabled
    @State private var updateCheckEnabled: Bool = Settings.shared.updateCheckEnabled
    @State private var copiedHint: String? = nil

    var body: some View {
        ZStack {
            VPPalette.background.ignoresSafeArea()
            backgroundAura

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let banner = installationWarning { installationBanner(banner) }
                    section(title: "Autorisations", subtitle: "Ce dont VoxPrompt a besoin pour fonctionner") {
                        permissionsCard
                    }
                    section(title: "Raccourci", subtitle: "Maintiens la touche, parle, relâche") {
                        hotkeyRow
                    }
                    section(title: "Microphone", subtitle: "Entrée utilisée pour la dictée") {
                        inputDeviceRow
                    }
                    section(title: "Modèle", subtitle: "Whisper local, sur votre Mac") {
                        modelRow
                    }
                    section(title: "Dictée en continu", subtitle: "Transcrit pendant que tu parles") {
                        streamingRow
                    }
                    section(title: "Collage", subtitle: "Cascade auto puis AppleScript en secours") {
                        pasteModeRow
                    }
                    section(title: "Glossaire", subtitle: "Noms propres et termes personnels") {
                        glossaryCard
                    }
                    section(title: "Démarrage", subtitle: "Lancer VoxPrompt automatiquement au login") {
                        launchAtLoginRow
                    }
                    section(title: "Mises à jour", subtitle: "Vérification manuelle sur GitHub") {
                        updatesRow
                    }
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.top, 26)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 400, height: 560)
        .preferredColorScheme(.light)
        .onAppear {
            permissions.start()
            appState.inputDevices = AudioRecorder.availableInputDevices()
            selectedInputUID = Settings.shared.preferredInputUID ?? ""
        }
        .onDisappear { permissions.stop() }
    }

    // MARK: Background

    private var backgroundAura: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(VPPalette.accent.opacity(0.08))
                    .frame(width: 320, height: 320)
                    .blur(radius: 100)
                    .offset(x: -geo.size.width * 0.35, y: -geo.size.height * 0.3)
                Circle()
                    .fill(Color(red: 0.95, green: 0.55, blue: 0.85).opacity(0.08))
                    .frame(width: 280, height: 280)
                    .blur(radius: 110)
                    .offset(x: geo.size.width * 0.3, y: geo.size.height * 0.35)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VPPalette.accent, Color(red: 0.88, green: 0.44, blue: 0.90)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .shadow(color: VPPalette.accent.opacity(0.3), radius: 10, y: 4)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("VoxPrompt")
                    .font(VPType.display(18, weight: .semibold))
                    .foregroundStyle(VPPalette.textPrimary)
                Text("Dictée locale · Whisper")
                    .font(VPType.body(11))
                    .foregroundStyle(VPPalette.textSecond)
            }
            Spacer()
            statusPill
        }
    }

    /// Pastille de synthèse : verte seulement si tout ce qui est indispensable est accordé
    /// ET que le moteur est prêt. Une app qui semble prête alors qu'elle ne peut ni écouter
    /// ni coller est exactement le piège qu'on cherche à supprimer.
    private var statusPill: some View {
        let ready = permissions.accessibility == .granted
            && permissions.microphone == .granted
            && !appState.engineBusy
        return HStack(spacing: 6) {
            SoftDot(color: ready ? VPPalette.ok : VPPalette.work, size: 6, pulsing: !ready)
            Text(ready ? "Prêt" : "Config")
                .font(VPType.body(11, weight: .medium))
                .foregroundStyle(ready ? VPPalette.ok : VPPalette.work)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(VPPalette.surface)
                .overlay(Capsule().strokeBorder(VPPalette.border, lineWidth: 1))
        )
    }

    // MARK: Bandeau d'installation

    /// Deux emplacements cassent les autorisations en silence : un bundle en quarantaine
    /// (exécuté depuis un volume temporaire en lecture seule) et un bundle hors
    /// /Applications, que macOS traite comme une app différente à chaque déplacement.
    private var installationWarning: String? {
        if Permissions.isTranslocated {
            return "VoxPrompt s'exécute depuis un emplacement temporaire. Ses autorisations ne seront pas conservées. Déplace l'app dans le dossier Applications avec le Finder, puis relance-la."
        }
        if !Permissions.isInstalledInApplications {
            return "VoxPrompt ne se trouve pas dans le dossier Applications. macOS risque de redemander les autorisations à chaque déplacement."
        }
        return nil
    }

    private func installationBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(VPPalette.work)
                .padding(.top, 1)
            Text(message)
                .font(VPType.body(11))
                .foregroundStyle(VPPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VPPalette.work.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(VPPalette.work.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: Autorisations

    private var permissionsCard: some View {
        VStack(spacing: 8) {
            permissionRow(
                title: "Microphone",
                detail: "Enregistrer ta voix",
                state: permissions.microphone,
                required: true,
                action: { Permissions.openMicrophoneSettings() },
                service: Permissions.Service.microphone
            )
            permissionRow(
                title: "Accessibilité",
                detail: "Capter la touche et coller le texte",
                state: permissions.accessibility,
                required: true,
                action: {
                    _ = Permissions.accessibility(prompt: true)
                    Permissions.openAccessibilitySettings()
                },
                service: Permissions.Service.accessibility
            )
            permissionRow(
                title: "Automatisation",
                detail: "Secours de collage pour certaines apps",
                state: permissions.automation,
                required: false,
                action: {
                    Task { _ = await Permissions.requestAutomationSystemEventsAsync() }
                },
                service: Permissions.Service.automation
            )
            if let hint = copiedHint {
                Text(hint)
                    .font(VPType.mono(10))
                    .foregroundStyle(VPPalette.textTert)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func permissionRow(title: String, detail: String, state: PermissionState,
                               required: Bool, action: @escaping () -> Void,
                               service: String) -> some View {
        card {
            HStack(spacing: 10) {
                SoftDot(color: color(for: state, required: required),
                        size: 8,
                        pulsing: required && state != .granted)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(VPType.body(13, weight: .medium))
                            .foregroundStyle(VPPalette.textPrimary)
                        if !required {
                            Text("optionnelle")
                                .font(VPType.body(9, weight: .medium))
                                .foregroundStyle(VPPalette.textTert)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(VPPalette.surfaceHi))
                        }
                    }
                    Text(state == .granted ? detail : (state.label + " · " + detail))
                        .font(VPType.body(11))
                        .foregroundStyle(VPPalette.textSecond)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                if state != .granted {
                    smallButton("Autoriser", action: action)
                } else {
                    // Autorisation accordée mais inerte : le cas classique d'une entrée TCC
                    // desynchronisee. La commande de reinitialisation est fournie telle quelle.
                    smallButton("Réparer") {
                        let cmd = Permissions.resetHint(for: service)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        copiedHint = "Commande copiée : " + cmd
                    }
                }
            }
        }
    }

    private func color(for state: PermissionState, required: Bool) -> Color {
        switch state {
        case .granted: return VPPalette.ok
        case .denied: return required ? VPPalette.live : VPPalette.work
        case .notDetermined, .unknown: return VPPalette.work
        }
    }

    // MARK: Rows

    private var hotkeyRow: some View {
        card {
            HStack {
                Text(selectedHotkey.label)
                    .font(VPType.body(13, weight: .medium))
                    .foregroundStyle(VPPalette.textPrimary)
                Spacer()
                Picker("", selection: $selectedHotkey) {
                    ForEach(HotkeyCatalog.presets, id: \.self) { binding in
                        Text(binding.label).tag(binding)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(VPPalette.accent)
                .frame(width: 160)
                .onChange(of: selectedHotkey) { _, new in
                    Settings.shared.hotkey = new
                    onHotkeyChange(new)
                }
            }
        }
    }

    private var inputDeviceRow: some View {
        card {
            HStack {
                Text(currentInputLabel)
                    .font(VPType.body(13, weight: .medium))
                    .foregroundStyle(VPPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("", selection: $selectedInputUID) {
                    Text("Entrée par défaut du système").tag("")
                    ForEach(appState.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(VPPalette.accent)
                .frame(width: 180)
                .onChange(of: selectedInputUID) { _, new in
                    Settings.shared.preferredInputUID = new.isEmpty ? nil : new
                }
            }
        }
    }

    private var currentInputLabel: String {
        if selectedInputUID.isEmpty { return "Par défaut" }
        return appState.inputDevices.first { $0.uid == selectedInputUID }?.name ?? "Micro absent"
    }

    private var modelRow: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(currentModelLabel)
                        .font(VPType.body(13, weight: .medium))
                        .foregroundStyle(VPPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Picker("", selection: $selectedModel) {
                        ForEach(ModelCatalog.entries, id: \.identifier) { entry in
                            // Un modele absent du cache devra etre telecharge : autant le dire
                            // avant le clic plutot que de laisser l'utilisateur devant une
                            // barre de progression inattendue.
                            Text(Transcriber.isModelDownloaded(entry.identifier)
                                 ? entry.label
                                 : entry.label + " · à télécharger")
                                .tag(entry.identifier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(VPPalette.accent)
                    .frame(width: 160)
                    .onChange(of: selectedModel) { _, new in
                        Settings.shared.modelIdentifier = new
                        onModelChange(new)
                    }
                }
                HStack(spacing: 6) {
                    SoftDot(color: appState.engineBusy ? VPPalette.work : VPPalette.ok,
                            size: 6, pulsing: appState.engineBusy)
                    Text(appState.engineStatus)
                        .font(VPType.body(11))
                        .foregroundStyle(VPPalette.textSecond)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var pasteModeRow: some View {
        card {
            HStack {
                Text(selectedPasteMode.label)
                    .font(VPType.body(13, weight: .medium))
                    .foregroundStyle(VPPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Picker("", selection: $selectedPasteMode) {
                    ForEach(PasteMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(VPPalette.accent)
                .frame(width: 180)
                .onChange(of: selectedPasteMode) { _, new in
                    Settings.shared.pasteMode = new
                }
            }
        }
    }

    private var glossaryCard: some View {
        card(padding: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $glossary)
                    .scrollContentBackground(.hidden)
                    .font(VPType.body(12))
                    .foregroundStyle(VPPalette.textPrimary)
                    .tint(VPPalette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .onChange(of: glossary) { _, new in
                        Settings.shared.glossary = new
                    }
                if glossary.isEmpty {
                    Text("Gandy, Kwanko, Shopify, Théodore…")
                        .font(VPType.body(12))
                        .foregroundStyle(VPPalette.textTert)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 80)
        }
    }

    private var streamingRow: some View {
        card {
            HStack(spacing: 10) {
                SoftDot(color: streamingEnabled ? VPPalette.ok : VPPalette.textFaint, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(streamingEnabled ? "Activée" : "Désactivée")
                        .font(VPType.body(13, weight: .medium))
                        .foregroundStyle(VPPalette.textPrimary)
                    Text(streamingEnabled
                         ? "Le texte est prêt quasi instantanément au relâchement"
                         : "Transcription en une fois après le relâchement")
                        .font(VPType.body(11))
                        .foregroundStyle(VPPalette.textSecond)
                }
                Spacer()
                Toggle("", isOn: $streamingEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(VPPalette.accent)
                    .onChange(of: streamingEnabled) { _, new in
                        Settings.shared.streamingEnabled = new
                    }
            }
        }
    }

    private var launchAtLoginRow: some View {
        card {
            HStack(spacing: 10) {
                SoftDot(color: launchAtLogin ? VPPalette.ok : VPPalette.textFaint, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(launchAtLogin ? "Activé" : "Désactivé")
                        .font(VPType.body(13, weight: .medium))
                        .foregroundStyle(VPPalette.textPrimary)
                    if loginNeedsApproval {
                        Text("Validation requise dans Réglages > Éléments d'ouverture")
                            .font(VPType.body(11))
                            .foregroundStyle(VPPalette.work)
                    } else {
                        Text(launchAtLogin ? "VoxPrompt se lance au démarrage" : "Lancement manuel uniquement")
                            .font(VPType.body(11))
                            .foregroundStyle(VPPalette.textSecond)
                    }
                }
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(VPPalette.accent)
                    .onChange(of: launchAtLogin) { _, new in
                        _ = LoginItem.setEnabled(new)
                        // Resync : l'OS peut refuser ou exiger une approbation user.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            launchAtLogin = LoginItem.isEnabled
                            loginNeedsApproval = LoginItem.requiresApproval
                        }
                    }
            }
        }
    }

    private var updatesRow: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SoftDot(color: updateCheckEnabled ? VPPalette.ok : VPPalette.textFaint, size: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(updateCheckEnabled ? "Activée" : "Désactivée")
                            .font(VPType.body(13, weight: .medium))
                            .foregroundStyle(VPPalette.textPrimary)
                        Text(updateCheckEnabled
                             ? "Une requête GitHub par jour, rien n'est installé tout seul"
                             : "Aucune connexion réseau hors téléchargement du modèle")
                            .font(VPType.body(11))
                            .foregroundStyle(VPPalette.textSecond)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $updateCheckEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(VPPalette.accent)
                        .onChange(of: updateCheckEnabled) { _, new in
                            Settings.shared.updateCheckEnabled = new
                            if new { Task { await updates.checkNow() } }
                        }
                }
                HStack(spacing: 8) {
                    smallButton("Vérifier maintenant") {
                        Task { await updates.checkNow() }
                    }
                    if let latest = updates.latest {
                        smallButton("Version \(latest.version) disponible") {
                            updates.openLatest()
                        }
                    } else if let error = updates.lastError {
                        Text(error)
                            .font(VPType.body(10))
                            .foregroundStyle(VPPalette.live)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if updates.lastCheck != nil {
                        Text("À jour")
                            .font(VPType.body(11))
                            .foregroundStyle(VPPalette.textTert)
                    }
                    Spacer()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Local · hors ligne · zéro télémétrie")
                .font(VPType.body(11))
                .foregroundStyle(VPPalette.textTert)
            Spacer()
            Button(action: onQuit) {
                Text("Quitter")
                    .font(VPType.body(11, weight: .medium))
                    .foregroundStyle(VPPalette.textSecond)
            }
            .buttonStyle(.plain)
            Text("·").foregroundStyle(VPPalette.textFaint)
            Text("v\(UpdateChecker.currentVersion)")
                .font(VPType.mono(10))
                .foregroundStyle(VPPalette.textFaint)
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(VPType.body(12, weight: .medium))
                .foregroundStyle(VPPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(VPPalette.surfaceHi)
                        .overlay(Capsule().strokeBorder(VPPalette.borderHi, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(VPType.display(13, weight: .semibold))
                    .foregroundStyle(VPPalette.textPrimary)
                Text(subtitle)
                    .font(VPType.body(11))
                    .foregroundStyle(VPPalette.textSecond)
            }
            content()
        }
    }

    private func card<Content: View>(padding: CGFloat = 12, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VPPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(VPPalette.border, lineWidth: 1)
                    )
            )
    }

    private var currentModelLabel: String {
        ModelCatalog.entries.first { $0.identifier == selectedModel }?.label ?? selectedModel
    }
}
