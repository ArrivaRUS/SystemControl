import Foundation
import IOKit

// Чтение температурных ключей SMC (AppleSMC IOService).
// На Apple Silicon HID-сенсоры не отдают GPU, а SMC-ключи "Tg*" — отдают.
// Раскладка SMCParamStruct повторяет C-структуру из классического smc.h
// (включая явный padding — у Swift иная упаковка вложенных структур).
final class SMCReader: @unchecked Sendable {

    struct TempKey {
        let key: UInt32
        let name: String     // например "Tg0f"
        let dataType: UInt32
        let dataSize: UInt32
    }

    private var connection: io_connect_t = 0
    private(set) var tempKeys: [TempKey] = []

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdKeyFromIndex: UInt8 = 8
    private static let cmdKeyInfo: UInt8 = 9

    private static let typeFLT = fourCC("flt ")
    private static let typeSP78 = fourCC("sp78")
    private static let typeUI8 = fourCC("ui8 ")
    private static let typeUI16 = fourCC("ui16")

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS, connection != 0 else { return nil }
        discoverTempKeys()
        if tempKeys.isEmpty {
            IOServiceClose(connection)
            return nil
        }
    }

    /// Набор SMC-ключей динамический: датчики обесточенных доменов (например,
    /// простаивающего GPU) исчезают и появляются. Позволяет переобнаружить.
    func rediscover() {
        tempKeys.removeAll()
        discoverTempKeys()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Публичное

    /// Все температурные ключи с текущими значениями.
    /// Внимание: ~300+ ключей × ~1мс на YPC-вызов — дорого, не дёргать каждый тик.
    func readAll() -> [(name: String, value: Double)] {
        read(keys: tempKeys)
    }

    func read(keys: [TempKey]) -> [(name: String, value: Double)] {
        var result: [(String, Double)] = []
        result.reserveCapacity(keys.count)
        for k in keys {
            guard let v = readValue(k), v > 1, v < 130 else { continue }
            result.append((k.name, v))
        }
        return result
    }

    // MARK: - Обнаружение ключей (один раз при старте)

    private func discoverTempKeys() {
        guard let countKey = keyInfo(Self.fourCC("#KEY")),
              var raw = readBytes(key: Self.fourCC("#KEY"), size: countKey.dataSize) else { return }
        let total = raw.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        raw.removeAll()

        for index in 0..<min(total, 4096) {
            guard let key = keyAtIndex(index) else { continue }
            let name = Self.fourCCString(key)
            // Температурные ключи начинаются с 'T'
            guard name.hasPrefix("T") else { continue }
            guard let info = keyInfo(key) else { continue }
            let supported = [Self.typeFLT, Self.typeSP78, Self.typeUI8, Self.typeUI16]
                .contains(info.dataType)
            guard supported, info.dataSize <= 4, info.dataSize > 0 else { continue }
            tempKeys.append(TempKey(
                key: key, name: name,
                dataType: info.dataType, dataSize: info.dataSize
            ))
        }
    }

    // MARK: - SMC plumbing

    private func callSMC(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection, Self.kSMCHandleYPCEvent,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private func keyAtIndex(_ index: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        input.data8 = Self.cmdKeyFromIndex
        input.data32 = index
        guard let out = callSMC(&input), out.key != 0 else { return nil }
        return out.key
    }

    private func keyInfo(_ key: UInt32) -> (dataType: UInt32, dataSize: UInt32)? {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = Self.cmdKeyInfo
        guard let out = callSMC(&input) else { return nil }
        return (out.keyInfo.dataType, out.keyInfo.dataSize)
    }

    private func readBytes(key: UInt32, size: UInt32) -> Data? {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = Self.cmdReadKey
        input.keyInfo.dataSize = size
        guard let out = callSMC(&input) else { return nil }
        let mirror = [
            out.bytes.0, out.bytes.1, out.bytes.2, out.bytes.3,
        ]
        return Data(mirror.prefix(Int(size)))
    }

    private func readValue(_ k: TempKey) -> Double? {
        guard let data = readBytes(key: k.key, size: k.dataSize) else { return nil }
        switch k.dataType {
        case Self.typeFLT:
            guard data.count >= 4 else { return nil }
            return Double(data.withUnsafeBytes { $0.load(as: Float32.self) })
        case Self.typeSP78:
            guard data.count >= 2 else { return nil }
            let raw = Int16(data[0]) << 8 | Int16(data[1])
            return Double(raw) / 256.0
        case Self.typeUI8:
            guard data.count >= 1 else { return nil }
            return Double(data[0])
        case Self.typeUI16:
            guard data.count >= 2 else { return nil }
            return Double(UInt16(data[0]) << 8 | UInt16(data[1]))
        default:
            return nil
        }
    }

    // MARK: - FourCC

    private static func fourCC(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for ch in s.utf8.prefix(4) {
            result = result << 8 | UInt32(ch)
        }
        return result
    }

    private static func fourCCString(_ v: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - C-совместимая структура запроса

struct SMCParamStruct {
    struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0 // выравнивание до C-раскладки
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
