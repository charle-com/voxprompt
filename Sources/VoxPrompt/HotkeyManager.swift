import Cocoa
import Carbon.HIToolbox

struct HotkeyBinding: Codable, Equatable, Hashable {
    enum Kind: String, Codable, Hashable { case key, modifier }
    var kind: Kind
    var keyCode: UInt16          // virtual keyCode ou flag brut selon kind
    var label: String            // libellé humain (ex "Right Option")

    static let defaultBinding = HotkeyBinding(
        kind: .modifier,
        keyCode: UInt16(NX_DEVICERALTKEYMASK),
        label: "Right Option"
    )
}

final class HotkeyManager {
    /// Appelé au keyDown du hotkey. Le `NSRunningApplication?` est l'app frontmost capturée
    /// au moment du press : c'est la cible où on collera le texte transcrit.
    var onPress: ((NSRunningApplication?) -> Void)?
    /// Appelé au keyUp du hotkey. Reçoit la cible capturée au press (peut différer de la
    /// frontmost actuelle si l'utilisateur a switché d'app pendant qu'il parlait).
    var onRelease: ((NSRunningApplication?) -> Void)?

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var binding: HotkeyBinding = .defaultBinding
    private var isHeld = false
    private var capturedFrontApp: NSRunningApplication?

    func start(binding: HotkeyBinding) {
        self.binding = binding
        self.isHeld = false
        self.capturedFrontApp = nil
        stop()

        switch binding.kind {
        case .modifier:
            let handler: (NSEvent) -> Void = { [weak self] event in
                guard let self else { return }
                let flagBit = UInt(self.binding.keyCode)
                let raw = UInt(event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue))
                let pressed = (raw & flagBit) != 0
                if pressed && !self.isHeld {
                    self.isHeld = true
                    let app = NSWorkspace.shared.frontmostApplication
                    self.capturedFrontApp = app
                    VPLog.log("hotkey down (modifier), captured frontApp=\(app?.localizedName ?? "?") pid=\(app?.processIdentifier ?? -1)")
                    self.onPress?(app)
                } else if !pressed && self.isHeld {
                    self.isHeld = false
                    let app = self.capturedFrontApp
                    self.capturedFrontApp = nil
                    self.onRelease?(app)
                }
            }
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
            VPLog.log("hotkey monitor installed (modifier) keyCode=\(binding.keyCode) label=\(binding.label)")

        case .key:
            let down: (NSEvent) -> Void = { [weak self] event in
                guard let self else { return }
                guard event.keyCode == self.binding.keyCode else { return }
                if !event.isARepeat && !self.isHeld {
                    self.isHeld = true
                    let app = NSWorkspace.shared.frontmostApplication
                    self.capturedFrontApp = app
                    VPLog.log("hotkey down (key), captured frontApp=\(app?.localizedName ?? "?") pid=\(app?.processIdentifier ?? -1)")
                    self.onPress?(app)
                }
            }
            let up: (NSEvent) -> Void = { [weak self] event in
                guard let self else { return }
                guard event.keyCode == self.binding.keyCode else { return }
                if self.isHeld {
                    self.isHeld = false
                    let app = self.capturedFrontApp
                    self.capturedFrontApp = nil
                    self.onRelease?(app)
                }
            }
            keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: down)
            keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: up)
            VPLog.log("hotkey monitor installed (key) keyCode=\(binding.keyCode) label=\(binding.label)")
        }
    }

    func stop() {
        [flagsMonitor, keyDownMonitor, keyUpMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        flagsMonitor = nil
        keyDownMonitor = nil
        keyUpMonitor = nil
    }
}

enum HotkeyCatalog {
    static let presets: [HotkeyBinding] = [
        .defaultBinding,
        HotkeyBinding(kind: .modifier, keyCode: UInt16(NX_DEVICELALTKEYMASK), label: "Left Option"),
        HotkeyBinding(kind: .modifier, keyCode: UInt16(NX_DEVICERCTLKEYMASK), label: "Right Control"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F13), label: "F13"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F14), label: "F14"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F15), label: "F15"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F16), label: "F16"),
    ]
}
