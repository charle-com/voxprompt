import SwiftUI
import ApplicationServices

struct PreferencesView: View {
    let onHotkeyChange: (HotkeyBinding) -> Void
    var onQuit: () -> Void = { NSApp.terminate(nil) }

    @State private var selectedHotkey: HotkeyBinding = Settings.shared.hotkey
    @State private var selectedModel: String = Settings.shared.modelIdentifier
    @State private var glossary: String = Settings.shared.glossary
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()

    var body: some View {
        ZStack {
            VPPalette.background.ignoresSafeArea()
            backgroundAura

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    section(title: "Raccourci", subtitle: "Maintiens la touche, parle, relâche") {
                        hotkeyRow
                    }
                    section(title: "Modèle", subtitle: "Whisper local, Neural Engine") {
                        modelRow
                    }
                    section(title: "Glossaire", subtitle: "Noms propres et termes personnels") {
                        glossaryCard
                    }
                    section(title: "Accessibilité", subtitle: "Pour capter la touche et coller le texte") {
                        accessibilityRow
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
            accessibilityGranted = AXIsProcessTrusted()
        }
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

    private var statusPill: some View {
        HStack(spacing: 6) {
            SoftDot(color: accessibilityGranted ? VPPalette.ok : VPPalette.work,
                    size: 6, pulsing: !accessibilityGranted)
            Text(accessibilityGranted ? "Prêt" : "Config")
                .font(VPType.body(11, weight: .medium))
                .foregroundStyle(accessibilityGranted ? VPPalette.ok : VPPalette.work)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(VPPalette.surface)
                .overlay(Capsule().strokeBorder(VPPalette.border, lineWidth: 1))
        )
    }

    // MARK: Section helper

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

    private var modelRow: some View {
        card {
            HStack {
                Text(currentModelLabel)
                    .font(VPType.body(13, weight: .medium))
                    .foregroundStyle(VPPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("", selection: $selectedModel) {
                    ForEach(ModelCatalog.entries, id: \.identifier) { entry in
                        Text(entry.label).tag(entry.identifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(VPPalette.accent)
                .frame(width: 160)
                .onChange(of: selectedModel) { _, new in
                    Settings.shared.modelIdentifier = new
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

    private var accessibilityRow: some View {
        card {
            HStack(spacing: 10) {
                SoftDot(color: accessibilityGranted ? VPPalette.ok : VPPalette.work, size: 8,
                        pulsing: !accessibilityGranted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(accessibilityGranted ? "Autorisée" : "Action requise")
                        .font(VPType.body(13, weight: .medium))
                        .foregroundStyle(VPPalette.textPrimary)
                    Text(accessibilityGranted ? "VoxPrompt capte la touche et colle le texte" : "Ajoute VoxPrompt dans les Réglages")
                        .font(VPType.body(11))
                        .foregroundStyle(VPPalette.textSecond)
                }
                Spacer()
                Button(action: openAccessibilityPane) {
                    Text("Ouvrir")
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
        }
    }

    private var footer: some View {
        HStack {
            Text("Local · offline · zéro télémétrie")
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
            Text("v0.1.0")
                .font(VPType.mono(10))
                .foregroundStyle(VPPalette.textFaint)
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

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

    private func openAccessibilityPane() {
        let prompt: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
