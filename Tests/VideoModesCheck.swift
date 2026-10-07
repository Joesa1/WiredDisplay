import AppKit
import AVFoundation
import VideoToolbox
import Network

@main enum VideoModesCheck {
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { }
    }

    @MainActor static func main() async throws {
        let catalog = try JSONDecoder().decode(PanelCatalog.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Resources/DeviceProfiles/apple-thunderbolt-display-catalog.json")))
        for (model, width, height) in [("iMac21,1", 4480, 2520), ("iMac18,2", 4096, 2304),
                                      ("iMac18,3", 5120, 2880), ("iMac14,2", 2560, 1440),
                                      ("MacBookPro18,3", 3024, 1964)] {
            let pixels = catalog.nativePixels(model: model, builtIn: true)!
            precondition(pixels.width == width && pixels.height == height)
            precondition(catalog.nativePixels(model: model, builtIn: false) == nil)
            var panel = DisplayProfile(width: width, height: height, hiDPI: width > 2560, hevc: true, appVersion: nil)
            panel.wideGamut = true
            let native = panel.limited(to4K: false), reduced = panel.limited(to4K: true)
            precondition(native.width == width && native.height == height)
            precondition(reduced.width <= width && reduced.height <= height && reduced.wideGamut)
            precondition(abs(Double(reduced.width) / Double(reduced.height) - Double(width) / Double(height)) < 0.002)
            let frameSize = try RawFrame.byteCount(width: width, height: height)
            precondition(frameSize + 1 < Wire.maximumPacket)
        }
        precondition(catalog.nativePixels(model: "unknown", builtIn: true) == nil)
        rejects { _ = try RawFrame.byteCount(width: Int.max, height: 480) }
        rejects { _ = try RawFrame.byteCount(width: 641, height: 480) }
        rejects { try VideoConfiguration(width: 640, height: 480, hevc: false, parameterSets: [], mode: .fidelity).validate() }

        // Odd row alignment exercises stripping and restoring CoreVideo padding.
        for (width, height) in [(642, 480), (4480, 2520)] {
            var source: CVPixelBuffer?
            try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferBytesPerRowAlignmentKey: 256, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source), "RGB allocation")
            let input = source!
            CVPixelBufferLockBaseAddress(input, [])
            let stride = CVPixelBufferGetBytesPerRow(input)
            let bytes = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<stride { bytes[row * stride + column] = UInt8(truncatingIfNeeded: row * 17 + column * 31) }
            }
            CVPixelBufferUnlockBaseAddress(input, [])
            let packet = try RawFrame.pack(input, sequence: 123)
            precondition(packet.count == 8 + width * height * 4)
            let config = VideoConfiguration(width: width, height: height, hevc: false, parameterSets: [], mode: .lossless, colorSpace: .displayP3)
            let decoder = HardwareDecoder()
            var received = false
            decoder.onImage = { image, sequence in
                precondition(sequence == 123)
                precondition((try! RawFrame.pack(image, sequence: sequence)) == packet)
                let space = CVBufferCopyAttachment(image, kCVImageBufferCGColorSpaceKey, nil) as! CGColorSpace
                precondition(space.name == CGColorSpace.displayP3)
                received = true
            }
            try decoder.configure(try Wire.decode(VideoConfiguration.self, Wire.json(config)))
            try decoder.decode(packet)
            precondition(received)
            rejects { try decoder.decode(Data(packet.dropLast())) }
            rejects { try decoder.decode(packet + Data([0])) }
            decoder.stop()
            rejects { try decoder.decode(packet) }
        }
        print("PASS: panel geometry, mode validation, padded RGB roundtrip, P3 tags, truncated/oversize raw rejection")
        try checkMain10()
        if CommandLine.arguments.contains("--capture") {
            guard CGPreflightScreenCaptureAccess() else { throw WireError.invalid("Screen capture permission is required for --capture") }
            if #available(macOS 14, *) {
                for mode in TransmissionMode.allCases { try await checkCapture(mode) }
            }
        }
    }

    static func checkMain10() throws {
        var encoder: VTCompressionSession?
        try check(VTCompressionSessionCreate(allocator: nil, width: 640, height: 480, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &encoder), "Main10 hardware encoder")
        let session = encoder!
        defer { VTCompressionSessionInvalidate(session) }
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel), "Main10 profile")
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_OutputBitDepth, value: 10 as CFNumber), "10-bit output")
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue), "Realtime")
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), "Frame ordering")
        var source: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source), "10-bit input")
        let input = source!
        CVPixelBufferLockBaseAddress(input, [])
        for plane in 0..<2 {
            let count = CVPixelBufferGetBytesPerRowOfPlane(input, plane) * CVPixelBufferGetHeightOfPlane(input, plane) / 2
            CVPixelBufferGetBaseAddressOfPlane(input, plane)!.assumingMemoryBound(to: UInt16.self).initialize(repeating: 512 << 6, count: count)
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        VideoConfiguration(width: 640, height: 480, hevc: true, parameterSets: [], mode: .fidelity, colorSpace: .displayP3).attachColor(to: input)
        var encoded: CMSampleBuffer?
        try check(VTCompressionSessionEncodeFrame(session, imageBuffer: input, presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60), frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                precondition(status == noErr)
                encoded = sample
            }, "Encode Main10")
        try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "Complete Main10")
        let sample = encoded!, format = CMSampleBufferGetFormatDescription(sample)!
        var sets: [Data] = []
        for index in 0..<3 {
            var pointer: UnsafePointer<UInt8>?, size = 0
            try check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), "Parameter sets")
            sets.append(Data(bytes: pointer!, count: size))
        }
        let decoder = HardwareDecoder()
        var received = false
        decoder.onFailure = { fatalError($0) }
        decoder.onImage = { image, sequence in
            precondition(sequence == 1 && CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            received = true
        }
        try decoder.configure(VideoConfiguration(width: 640, height: 480, hevc: true, parameterSets: sets, mode: .fidelity, colorSpace: .displayP3))
        let block = CMSampleBufferGetDataBuffer(sample)!, count = CMBlockBufferGetDataLength(block)
        var packet = Data()
        Wire.append(UInt64(1), to: &packet)
        packet.append(Data(count: count))
        try packet.withUnsafeMutableBytes { raw in
            try check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: raw.baseAddress!.advanced(by: 8)), "Encoded bytes")
        }
        try decoder.decode(packet)
        decoder.stop()
        precondition(received)
        print("PASS: local hardware HEVC Main10 encode/decode with 10-bit pixel buffers")
    }

    @available(macOS 14, *)
    @MainActor static func checkCapture(_ mode: TransmissionMode) async throws {
        let listener = try NWListener(using: CablePeer.parameters(), on: .any)
        let loopback = CableAddress(name: "lo0", ip: "127.0.0.1", index: if_nametoindex("lo0"))
        let decoder = HardwareDecoder()
        var receiver: CablePeer?
        var received = false
        var failure: String?
        decoder.onImage = { _, _ in Task { @MainActor in received = true } }
        decoder.onFailure = { error in Task { @MainActor in failure = error } }
        listener.newConnectionHandler = { connection in
            let peer = CablePeer(connection: connection, cable: loopback)
            Task { @MainActor in receiver = peer }
            peer.onPacket = { kind, data in
                print("RECEIVE: \(kind) \(data.count)")
                if kind == .configuration {
                    let config = try Wire.decode(VideoConfiguration.self, data)
                    precondition(config.mode == mode && config.width == 640 && config.height == 480)
                    try decoder.configure(config)
                } else if kind == .video { try decoder.decode(data) }
            }
            peer.onClose = { message in print("RECEIVER CLOSE: \(message)") }
            peer.start()
        }
        listener.start(queue: .global())
        defer { listener.cancel(); receiver?.stop(); decoder.stop() }
        for _ in 0..<50 {
            if listener.port != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let port = listener.port else { throw WireError.invalid("Loopback listener timeout") }
        let peer = CablePeer(connection: NWConnection(host: "127.0.0.1", port: port, using: CablePeer.parameters()), cable: loopback)
        peer.start()
        defer { peer.stop() }
        let sender = ScreenSender(peer: peer)
        sender.onStatus = { print("CAPTURE: \($0)") }
        peer.onClose = { message in print("SENDER CLOSE: \(message)") }
        sender.onFailure = { error in Task { @MainActor in failure = error } }
        var profile = DisplayProfile(width: 640, height: 480, hiDPI: false, hevc: true, appVersion: nil)
        profile.wideGamut = true
        do {
            try await sender.start(profile: profile, mirror: true, mode: mode)
            for _ in 0..<100 {
                if received || failure != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            await sender.stop()
            throw error
        }
        await sender.stop()
        guard received, failure == nil else { throw WireError.invalid(failure ?? "Capture timeout: \(mode.rawValue)") }
        print("PASS: primary display -> ScreenCaptureKit -> \(mode.rawValue) -> TCP -> receiver")
    }
}
