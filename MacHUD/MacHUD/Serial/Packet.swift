import Foundation

/// Packet framing as described in PROTOCOL.md.
enum MsgType: UInt8 {
    case hello = 0x01
    case ping = 0x02
    case frame = 0x10
    case displayOn = 0x11
    case displayOff = 0x12
    case helloReply = 0x81
    case pong = 0x82
    case ack = 0x90
}

enum AckStatus: UInt8 {
    case ok = 0, badCRC = 1, tooLarge = 2, decodeFailed = 3, displayOff = 4, unknownType = 5
}

struct Packet {
    var type: UInt8
    var seq: UInt8
    var payload: Data

    static let magic: [UInt8] = [0xA5, 0x5A]

    func encoded() -> Data {
        var out = Data(capacity: payload.count + 12)
        out.append(contentsOf: Self.magic)
        var body = Data(capacity: payload.count + 6)
        body.append(type)
        body.append(seq)
        let len = UInt32(payload.count)
        body.append(contentsOf: [UInt8(len & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len >> 16 & 0xFF), UInt8(len >> 24)])
        body.append(payload)
        let crc = CRC32.checksum(body)
        out.append(body)
        out.append(contentsOf: [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)])
        return out
    }
}

/// Incremental parser. Feed it bytes and it hands back complete, CRC-checked packets.
struct PacketParser {
    let maxPayload = 1 << 20
    private var buf = [UInt8]()

    mutating func reset() { buf.removeAll(keepingCapacity: true) }

    mutating func feed(_ bytes: UnsafeRawBufferPointer) -> [Packet] {
        buf.append(contentsOf: bytes)
        var packets = [Packet]()
        var i = 0
        while true {
            // Hunt for magic.
            while i + 1 < buf.count, !(buf[i] == 0xA5 && buf[i + 1] == 0x5A) { i += 1 }
            guard i + 8 <= buf.count else { break }
            let len = Int(buf[i + 4]) | Int(buf[i + 5]) << 8 | Int(buf[i + 6]) << 16 | Int(buf[i + 7]) << 24
            if len > maxPayload { i += 1; continue }
            guard i + 12 + len <= buf.count else { break }
            let crcStart = i + 8 + len
            let got = UInt32(buf[crcStart]) | UInt32(buf[crcStart + 1]) << 8
                | UInt32(buf[crcStart + 2]) << 16 | UInt32(buf[crcStart + 3]) << 24
            let calc = buf.withUnsafeBufferPointer { CRC32.checksum(UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: $0[(i + 2)..<crcStart]))) }
            if got == calc {
                packets.append(Packet(type: buf[i + 2], seq: buf[i + 3], payload: Data(buf[(i + 8)..<crcStart])))
                i = crcStart + 4
            } else {
                i += 1   // bad packet: resync on the next magic
            }
        }
        // Keep a dangling 0xA5 that might be the start of the next magic.
        if i >= buf.count - 1, buf.last != 0xA5 { i = buf.count }
        buf.removeFirst(min(i, buf.count))
        return packets
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { checksum($0) }
    }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}
