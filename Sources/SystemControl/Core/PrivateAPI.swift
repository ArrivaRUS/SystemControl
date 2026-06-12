import Foundation
import CoreFoundation

// Обёртки над приватными символами macOS, загружаемыми через dlsym.
// IOHIDEventSystemClient* — единственный способ читать температуры SoC
// на Apple Silicon без root (тот же путь используют Stats, macmon и т.п.).

enum PrivateAPI {

    // MARK: - IOHID (термосенсоры)

    typealias ClientCreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    typealias GetFloatValueFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    static let hidClientCreate: ClientCreateFn? = load(ioKit, "IOHIDEventSystemClientCreate")
    static let hidSetMatching: SetMatchingFn? = load(ioKit, "IOHIDEventSystemClientSetMatching")
    static let hidCopyServices: CopyServicesFn? = load(ioKit, "IOHIDEventSystemClientCopyServices")
    static let hidCopyProperty: CopyPropertyFn? = load(ioKit, "IOHIDServiceClientCopyProperty")
    static let hidCopyEvent: CopyEventFn? = load(ioKit, "IOHIDServiceClientCopyEvent")
    static let hidGetFloatValue: GetFloatValueFn? = load(ioKit, "IOHIDEventGetFloatValue")

    static let kIOHIDEventTypeTemperature: Int64 = 15
    static var temperatureField: Int32 { Int32(kIOHIDEventTypeTemperature << 16) }

    // MARK: - Responsibility (группировка хелперов под родительское приложение)

    typealias ResponsiblePidFn = @convention(c) (pid_t) -> pid_t

    static let responsiblePid: ResponsiblePidFn? = load(selfHandle, "responsibility_get_pid_responsible_for_pid")

    // MARK: - dlsym plumbing

    private static let ioKit: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let selfHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)

    private static func load<T>(_ handle: UnsafeMutableRawPointer?, _ symbol: String) -> T? {
        guard let handle, let sym = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
