import Foundation
import IOKit.hid
import HyperMugCore

/// Watches the physical Caps Lock key through IOHIDManager (keyboard usage page 0x07, usage 0x39), so it works whether
/// macOS maps Caps Lock to "No Action" (the key then produces no CGEvents) or leaves it as Caps Lock.
/// Open only while a Caps Lock modifier mode and its event tap are active. Needs Input Monitoring.
/// When to open or close is decided by Core's `CapsMonitorPolicy`; this class only talks to IOKit.
final class CapsKeyMonitor {
    /// (down, monotonic nanoseconds)
    var onCapsChange: ((Bool, UInt64) -> Void)?
    var onKeyboardRemoved: (() -> Void)?

    private let log: LogSink
    private var manager: IOHIDManager?
    private var policy = CapsMonitorPolicy()

    init(log: @escaping LogSink) {
        self.log = log
    }

    /// Idempotent; called on every engine sync.
    func setEnabled(_ on: Bool) {
        switch policy.setEnabled(on, isOpen: manager != nil, access: inputMonitoringAccess()) {
        case .none: break
        case .open: open()
        case .close: close()
        }
    }

    func shutdown() {
        setEnabled(false)
    }

    private func open() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices: [String: Int] = [
            kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
            kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Keyboard),
        ]
        let elements: [String: Int] = [
            kIOHIDElementUsagePageKey: Int(kHIDPage_KeyboardOrKeypad),
            kIOHIDElementUsageKey: Int(kHIDUsage_KeyboardCapsLock),
        ]
        IOHIDManagerSetDeviceMatching(manager, devices as CFDictionary)
        // Only Caps Lock values are delivered; other keys never reach this process through the manager.
        IOHIDManagerSetInputValueMatching(manager, elements as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, capsValueCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, capsDeviceRemovedCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if let line = policy.openFinished(code: result) {
            log(.info, line)
            DebugLog.write(line)
        }
        if result == kIOReturnSuccess {
            self.manager = manager
        } else {
            release(manager)
        }
    }

    private func close() {
        guard let manager else { return }
        self.manager = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        release(manager)
        DebugLog.write("caps hid closed")
    }

    private func release(_ manager: IOHIDManager) {
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    fileprivate func valueChanged(_ value: IOHIDValue) {
        onCapsChange?(IOHIDValueGetIntegerValue(value) != 0, DispatchTime.now().uptimeNanoseconds)
    }
}

private func capsValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context else { return }
    Unmanaged<CapsKeyMonitor>.fromOpaque(context).takeUnretainedValue().valueChanged(value)
}

private func capsDeviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<CapsKeyMonitor>.fromOpaque(context).takeUnretainedValue().onKeyboardRemoved?()
}
