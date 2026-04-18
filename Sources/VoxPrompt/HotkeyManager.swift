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
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var binding: HotkeyBinding = .defaultBinding
    private var isHeld = false

    func start(binding: HotkeyBinding) {
        self.binding = binding
        self.isHeld = false
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
                    self.onPress?()
                } else if !pressed && self.isHeld {
                    self.isHeld = false
                    self.onRelease?()
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
                    self.onPress?()
                }
            }
            let up: (NSEvent) -> Void = { [weak self] event in
                guard let self else { return }
                guard event.keyCode == self.binding.keyCode else { return }
                if self.isHeld {
                    self.isHeld = false
                    self.onRelease?()
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
