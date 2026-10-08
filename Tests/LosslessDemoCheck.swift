import Foundation

@main enum LosslessDemoCheck {
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { }
    }

    static func replacing<T: FixedWidthInteger>(_ data: Data, at offset: Int, with value: T) -> Data {
        var result = data, bytes = Data()
        Wire.append(value, to: &bytes)
        result.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        return result
    }

    static func main() throws {
        let width = 640, height = 480
        var raw = Data(count: try RawFrame.byteCount(width: width, height: height))
        raw = replacing(raw, at: 0, with: UInt64(1))
        for regions in [false, true] {
            var original = raw
            let first = try LosslessDemoFrame.encode(original, previous: nil, width: width, height: height, regions: regions)
            precondition(first[16] == 1 && first.count < original.count)
            var decoded = try LosslessDemoFrame.decode(first, previous: nil, width: width, height: height, regions: regions)
            precondition(decoded == original)
            let retainedFirst = decoded
            var transmitted = original
            // Includes two edits from captures that were never sent, then a cursor-shaped edit.
            for sequence in [UInt64(2), 5, 6, 9] {
                original = replacing(original, at: 0, with: sequence)
                if sequence == 2 {
                    for row in 20..<30 { for column in 10..<(10 + row - 19) {
                        original[8 + (row * width + column) * 4] = 255
                    } }
                } else if sequence == 5 {
                    original[8 + (100 * width + 100) * 4] = 17
                    original[8 + (120 * width + 120) * 4] = 42
                } else if sequence == 9 {
                    for index in 8..<original.count { original[index] = UInt8(truncatingIfNeeded: index * 31) }
                }
                let packet = try LosslessDemoFrame.encode(original, previous: transmitted, width: width, height: height, regions: regions)
                if regions && sequence == 6 { precondition(packet.count == LosslessDemoFrame.headerSize) }
                decoded = try LosslessDemoFrame.decode(packet, previous: decoded, width: width, height: height, regions: regions)
                precondition(decoded == original)
                precondition(retainedFirst == raw)
                if regions && sequence == 2 {
                    rejects { _ = try LosslessDemoFrame.decode(packet, previous: nil, width: width, height: height, regions: true) }
                    rejects { _ = try LosslessDemoFrame.decode(packet, previous: transmitted, width: width, height: height, regions: false) }
                    rejects { _ = try LosslessDemoFrame.decode(replacing(packet, at: 8, with: UInt64(99)), previous: transmitted, width: width, height: height, regions: true) }
                }
                transmitted = original
            }
            for bad in [Data(first.prefix(36)), Data(first.dropLast()), first + Data([0]),
                        replacing(first, at: 17, with: UInt32.max), replacing(first, at: 25, with: UInt32.max),
                        replacing(first, at: 33, with: UInt32.max), replacing(first, at: 16, with: UInt8(2)),
                        replacing(first, at: 0, with: UInt64(0))] {
                rejects { _ = try LosslessDemoFrame.decode(bad, previous: nil, width: width, height: height, regions: regions) }
            }
            // Valid region metadata must not allow compressed output to exceed its declared size.
            var bomb = replacing(first, at: 8, with: UInt64(1))
            bomb = replacing(bomb, at: 0, with: UInt64(2))
            bomb = replacing(bomb, at: 25, with: UInt32(320))
            bomb = replacing(bomb, at: 29, with: UInt32(240))
            bomb = replacing(bomb, at: 33, with: UInt32(320 * 240 * 4))
            rejects { _ = try LosslessDemoFrame.decode(bomb, previous: raw, width: width, height: height, regions: true) }
            // Reconnection resets ancestry and accepts a new sequence-one keyframe.
            precondition(try! LosslessDemoFrame.decode(first, previous: nil, width: width, height: height, regions: regions) == raw)
        }
        // Incompressible full-screen content takes the raw fallback without changing pixels.
        var random = raw, seed: UInt64 = 0x123456789abcdef
        for index in 8..<random.count {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            random[index] = UInt8(truncatingIfNeeded: seed)
        }
        let packet = try LosslessDemoFrame.encode(random, previous: nil, width: width, height: height, regions: false)
        precondition(packet[16] == 0)
        precondition(try! LosslessDemoFrame.decode(packet, previous: nil, width: width, height: height, regions: false) == random)
        for mode in TransmissionMode.allCases {
            var budget = FrameBudget(limit: mode.frameLimit)
            for _ in 0..<mode.frameLimit { precondition(budget.reserve(now: 0) != nil) }
            precondition(budget.reserve(now: 0) == nil)
            _ = try budget.acknowledge(UInt64(mode.frameLimit), now: 1)
            precondition(budget.reserve(now: 2) != nil)
        }
        precondition(TransmissionMode.lossless.frameLimit == 1 && TransmissionMode.demo1.frameLimit == 2 && TransmissionMode.demo2.frameLimit == 2)
        print("PASS: demo exact pixels, sparse/skipped/cursor/unchanged/full updates, raw fallback, immutable baseline, reset, bounded budgets, corrupt ancestry/length/LZ4 rejection")
    }
}
