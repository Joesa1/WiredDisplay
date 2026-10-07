import AppKit
import ApplicationServices
import CoreAudio

final class TouchBarHardware {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    deinit { if let library = library { dlclose(library) } }

    private func outputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private func read<T>(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, initial: T) -> T? {
        var address = address(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }
    private func settable(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var value: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &value) == noErr && value.boolValue
    }
    private func write<T>(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, value: T) -> Bool {
        guard settable(device, selector: selector) else { return false }
        var address = address(selector)
        var value = value
        return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr }
    }
    private func brightness() -> (CGDirectDisplayID, Float)? {
        guard let library = library, let symbol = dlsym(library, "DisplayServicesGetBrightness"), dlsym(library, "DisplayServicesSetBrightness") != nil else { return nil }
        let get = unsafeBitCast(symbol, to: GetBrightness.self)
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return nil }
        for display in displays.prefix(Int(count)) where CGDisplayIsBuiltin(display) != 0 {
            var value: Float = 0
            if get(display, &value) == 0, value.isFinite, (0...1).contains(value) { return (display, value) }
        }
        return nil
    }

    func snapshot() -> [String: Any] {
        var state: [String: Any] = ["volumeAvailable": false, "brightnessAvailable": false, "accessibility": AXIsProcessTrusted(), "message": "快捷键需要辅助功能权限；亮度仅支持兼容的内置屏幕"]
        if let device = outputDevice() {
            if let volume: Float = read(device, selector: kAudioDevicePropertyVolumeScalar, initial: Float(0)), volume.isFinite, settable(device, selector: kAudioDevicePropertyVolumeScalar) { state["volume"] = Double(volume * 100); state["volumeAvailable"] = true }
            if let muted: UInt32 = read(device, selector: kAudioDevicePropertyMute, initial: UInt32(0)), settable(device, selector: kAudioDevicePropertyMute) { state["muted"] = muted != 0 }
        }
        if let (_, value) = brightness() { state["brightnessAvailable"] = true; state["brightness"] = Double(value * 100) }
        return state
    }

    func perform(_ action: String, value: Double?) -> (Bool, String) {
        var success = false
        switch action {
        case "volume.set":
            if let value = value, value.isFinite, (0...100).contains(value), let device = outputDevice() { success = write(device, selector: kAudioDevicePropertyVolumeScalar, value: Float(value / 100)) }
        case "volume.mute":
            if let device = outputDevice(), let muted: UInt32 = read(device, selector: kAudioDevicePropertyMute, initial: UInt32(0)) { success = write(device, selector: kAudioDevicePropertyMute, value: UInt32(muted == 0 ? 1 : 0)) }
        case "brightness.set":
            if let value = value, value.isFinite, (0...100).contains(value), let (display, _) = brightness(), let library = library, let symbol = dlsym(library, "DisplayServicesSetBrightness") {
                success = unsafeBitCast(symbol, to: SetBrightness.self)(display, Float(value / 100)) == 0
            }
        case "key.escape", "key.desktop", "key.search":
            guard AXIsProcessTrusted() else { return (false, "请在 Mac 系统设置 → 隐私与安全性 → 辅助功能中授权") }
            let code: CGKeyCode = action == "key.escape" ? 53 : (action == "key.search" ? 49 : 103)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return (false, "无法创建快捷键事件") }
            // Command-Space opens Spotlight; F11 uses the system's configured Show Desktop shortcut.
            if action == "key.search" { down.flags = .maskCommand; up.flags = .maskCommand }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return (true, "已发送快捷键；效果取决于 Mac 快捷键设置")
        default: return (false, "未知系统操作")
        }
        return (success, success ? "已调整" : "当前设备不支持此控制或系统拒绝了操作")
    }
}
