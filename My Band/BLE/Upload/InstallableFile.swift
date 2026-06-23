import Foundation
import Compression

// MARK: - InstallableFile
//
// A user-supplied file destined for the band: a watch face (binary) or a quick app (RPK = zip).
// Detection mirrors GadgetBridge XiaomiFWHelper:
//   • Watch face: header magic 0x5A 0xA5; numeric id is a NUL-terminated ASCII string at 0x28,
//     name at 0x68. Firmware (magic 0x60 0x5A 0x5A … 0x7E) is deliberately NOT accepted here.
//   • App (RPK): a zip containing manifest.json with package / name / versionCode.

enum InstallableKind { case watchface, app }

struct InstallableFile {
    let kind: InstallableKind
    let id: String          // watch face numeric id, or RPK package name
    let name: String
    let versionCode: Int    // RPK manifest versionCode; 1 for watch faces
    let bytes: Data

    static func parse(_ data: Data) -> InstallableFile? {
        parseWatchface(data) ?? parseRpk(data)
    }

    // MARK: - Watch face

    private static func parseWatchface(_ data: Data) -> InstallableFile? {
        guard data.count > 0x70 else { return nil }
        let b = data.startIndex
        guard data[b] == 0x5A, data[b + 1] == 0xA5 else { return nil }
        guard let id = nulTerminatedASCII(data, at: 0x28),
              id.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
        // 0x68 is 0xFFFFFFFF for translatable names — fall back to the id in that case.
        let name = nulTerminatedASCII(data, at: 0x68).flatMap { $0.isEmpty ? nil : $0 } ?? id
        return InstallableFile(kind: .watchface, id: id, name: name, versionCode: 1, bytes: data)
    }

    private static func nulTerminatedASCII(_ data: Data, at offset: Int) -> String? {
        let start = data.index(data.startIndex, offsetBy: offset)
        guard start < data.endIndex else { return nil }
        var bytes: [UInt8] = []
        var i = start
        while i < data.endIndex {
            let byte = data[i]
            if byte == 0 { break }
            guard byte >= 0x20, byte < 0x7F else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
            i = data.index(after: i)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - App (RPK)

    private static func parseRpk(_ data: Data) -> InstallableFile? {
        guard let manifest = MiniZip.extract(entry: "manifest.json", from: data),
              let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let pkg = json["package"] as? String, !pkg.isEmpty else { return nil }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pkg
        let versionCode = (json["versionCode"] as? Int) ?? 1
        return InstallableFile(kind: .app, id: pkg, name: name, versionCode: versionCode, bytes: data)
    }
}

// MARK: - MiniZip
//
// Minimal read-only zip extractor — Foundation can't read individual zip entries on iOS. Parses
// the End-Of-Central-Directory record and central directory to locate one entry, then inflates it
// (stored or raw-deflate via the Compression framework). Enough for RPK manifest.json.

enum MiniZip {

    static func extract(entry name: String, from zip: Data) -> Data? {
        guard let eocd = findEOCD(zip) else { return nil }
        let cdOffset = u32(zip, eocd + 16)
        let cdCount  = u16(zip, eocd + 10)

        var p = cdOffset
        for _ in 0..<cdCount {
            guard p + 46 <= zip.count, u32(zip, p) == 0x0201_4b50 else { return nil }
            let method     = u16(zip, p + 10)
            let compSize   = u32(zip, p + 20)
            let uncompSize = u32(zip, p + 24)
            let nameLen    = u16(zip, p + 28)
            let extraLen   = u16(zip, p + 30)
            let commentLen = u16(zip, p + 32)
            let localOff   = u32(zip, p + 42)
            let entryName  = ascii(zip, p + 46, nameLen)
            if entryName == name {
                return readLocal(zip, localOffset: localOff, method: method,
                                 compSize: compSize, uncompSize: uncompSize)
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return nil
    }

    private static func readLocal(_ zip: Data, localOffset: Int, method: Int,
                                  compSize: Int, uncompSize: Int) -> Data? {
        guard localOffset + 30 <= zip.count, u32(zip, localOffset) == 0x0403_4b50 else { return nil }
        let nameLen  = u16(zip, localOffset + 26)
        let extraLen = u16(zip, localOffset + 28)
        let dataStart = localOffset + 30 + nameLen + extraLen
        guard dataStart + compSize <= zip.count else { return nil }
        let s = zip.index(zip.startIndex, offsetBy: dataStart)
        let e = zip.index(s, offsetBy: compSize)
        let comp = zip.subdata(in: s..<e)
        switch method {
        case 0: return comp                                   // stored
        case 8: return inflateRaw(comp, expectedSize: uncompSize)
        default: return nil
        }
    }

    private static func inflateRaw(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty, expectedSize > 0 else { return Data() }
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    private static func findEOCD(_ zip: Data) -> Int? {
        guard zip.count >= 22 else { return nil }
        let lower = max(0, zip.count - (22 + 0xFFFF))
        var off = zip.count - 22
        while off >= lower {
            if u32(zip, off) == 0x0605_4b50 { return off }
            off -= 1
        }
        return nil
    }

    // Absolute-offset readers (offsets are file-relative; startIndex handles sliced Data).
    private static func u16(_ d: Data, _ off: Int) -> Int {
        let b = d.startIndex
        guard off >= 0, off + 2 <= d.count else { return 0 }
        return Int(d[b + off]) | (Int(d[b + off + 1]) << 8)
    }
    private static func u32(_ d: Data, _ off: Int) -> Int {
        let b = d.startIndex
        guard off >= 0, off + 4 <= d.count else { return 0 }
        return Int(d[b + off]) | (Int(d[b + off + 1]) << 8) | (Int(d[b + off + 2]) << 16) | (Int(d[b + off + 3]) << 24)
    }
    private static func ascii(_ d: Data, _ off: Int, _ len: Int) -> String? {
        let b = d.startIndex
        guard off >= 0, off + len <= d.count else { return nil }
        return String(data: d.subdata(in: (b + off)..<(b + off + len)), encoding: .utf8)
    }
}
