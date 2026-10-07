import AppKit
import ScreenCaptureKit
import VideoToolbox
import AVFoundation

final class AudioRenderer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queued = 0
    private let lock = NSLock()

    func configure(_ config: AudioConfiguration) throws {
        guard config.channels == 2, config.bitsPerChannel == 32, config.bytesPerFrame == 8, config.interleaved,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: config.sampleRate,
                                         channels: AVAudioChannelCount(config.channels), interleaved: true) else {
            throw WireError.invalid("音频格式不受支持")
        }
        stop()
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
    }

    func enqueue(_ data: Data) {
        guard let format, data.count % 8 == 0 else { return }
        lock.lock()
        guard queued < 12 else { lock.unlock(); return }
        queued += 1; lock.unlock()
        let frames = AVAudioFrameCount(data.count / 8)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        _ = data.withUnsafeBytes { raw in memcpy(buffer.audioBufferList.pointee.mBuffers.mData, raw.baseAddress!, data.count) }
        player.scheduleBuffer(buffer) { [weak self] in
            self?.lock.lock(); self?.queued = max(0, (self?.queued ?? 1) - 1); self?.lock.unlock()
        }
    }

    func stop() {
        player.stop(); engine.stop(); engine.detach(player); format = nil
        lock.lock(); queued = 0; lock.unlock()
    }
}

func check(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else { throw WireError.invalid("\(message)（\(status)）") }
}

func makeFormat(_ config: VideoConfiguration) throws -> CMVideoFormatDescription {
    try config.validate()
    try DisplayProfile(width: config.width, height: config.height, hiDPI: true, hevc: config.hevc, appVersion: nil).validate()
    guard config.parameterSets.count == (config.hevc ? 3 : 2),
          config.parameterSets.allSatisfy({ !$0.isEmpty && $0.count <= 65536 }) else {
        throw WireError.invalid("视频参数无效")
    }
    let storage = config.parameterSets.map { $0 as NSData }
    let pointers = storage.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
    let lengths = storage.map { $0.length }
    var description: CMFormatDescription?
    let status = pointers.withUnsafeBufferPointer { ptr in
        lengths.withUnsafeBufferPointer { size in
            if config.hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil,
                    parameterSetCount: storage.count, parameterSetPointers: ptr.baseAddress!,
                    parameterSetSizes: size.baseAddress!, nalUnitHeaderLength: 4,
                    extensions: nil, formatDescriptionOut: &description)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                parameterSetCount: storage.count, parameterSetPointers: ptr.baseAddress!,
                parameterSetSizes: size.baseAddress!, nalUnitHeaderLength: 4,
                formatDescriptionOut: &description)
        }
    }
    try check(status, "无法读取视频格式")
    guard let description else { throw WireError.invalid("缺少视频格式") }
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    guard dimensions.width == config.width, dimensions.height == config.height else {
        throw WireError.invalid("视频尺寸与约定不一致")
    }
    return description
}

final class HardwareDecoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var configuration: VideoConfiguration?
    private var rawPool: CVPixelBufferPool?
    var onImage: ((CVPixelBuffer, UInt64) -> Void)?
    var onFailure: ((String) -> Void)?

    func configure(_ config: VideoConfiguration) throws {
        stop()
        try config.validate()
        configuration = config
        if config.mode == .lossless {
            let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: config.width,
                kCVPixelBufferHeightKey: config.height, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            try check(CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &rawPool), "Cannot allocate RGB pool")
            return
        }
        let format = try makeFormat(config)
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, frame, status, _, image, _, _ in
            guard let ref else { return }
            let decoder = Unmanaged<HardwareDecoder>.fromOpaque(ref).takeUnretainedValue()
            guard status == noErr, let image else {
                decoder.onFailure?("硬件解码失败，请选择 4K 流畅档（\(status)）")
                return
            }
            guard let config = decoder.configuration else { return }
            guard CVPixelBufferGetPixelFormatType(image) == config.decodedPixelFormat else {
                decoder.onFailure?("Decoder returned an unexpected pixel format")
                return
            }
            config.attachColor(to: image)
            decoder.onImage?(image, UInt64(UInt(bitPattern: frame)))
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attrs = [kCVPixelBufferPixelFormatTypeKey: config.decodedPixelFormat,
                     kCVPixelBufferIOSurfacePropertiesKey: [:],
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        try check(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
            decoderSpecification: spec, imageBufferAttributes: attrs, outputCallback: &callback,
            decompressionSessionOut: &session), "此设备无法硬件解码该分辨率，请使用 4K 档")
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        self.format = format
    }

    func decode(_ data: Data) throws {
        if let config = configuration, config.mode == .lossless {
            guard data.count == (try RawFrame.byteCount(width: config.width, height: config.height)),
                  let pool = rawPool else { throw WireError.invalid("Invalid RGB frame size") }
            var image: CVPixelBuffer?
            try check(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &image), "RGB renderer is backlogged")
            guard let image else { throw WireError.invalid("Missing RGB buffer") }
            try check(CVPixelBufferLockBaseAddress(image, []), "Cannot lock RGB buffer")
            defer { CVPixelBufferUnlockBaseAddress(image, []) }
            guard let base = CVPixelBufferGetBaseAddress(image) else { throw WireError.invalid("Missing RGB storage") }
            let stride = CVPixelBufferGetBytesPerRow(image)
            data.withUnsafeBytes { raw in
                for row in 0..<config.height {
                    memcpy(base.advanced(by: row * stride), raw.baseAddress!.advanced(by: 8 + row * config.width * 4), config.width * 4)
                }
            }
            config.attachColor(to: image)
            onImage?(image, try Wire.integer(data, at: 0, as: UInt64.self))
            return
        }
        guard let session, let format, data.count > 8 else { throw WireError.invalid("视频先于格式到达") }
        let sequence = try Wire.integer(data, at: 0, as: UInt64.self)
        let bytes = Data(data.dropFirst(8))
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block), "无法创建解码缓冲")
        guard let block else { throw WireError.invalid("缺少解码缓冲") }
        try bytes.withUnsafeBytes { raw in
            try check(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes.count), "无法填充解码缓冲")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 60), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = bytes.count
        try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "无法构建视频帧")
        guard let sample else { throw WireError.invalid("缺少视频帧") }
        // Synchronous decode bounds work on the dedicated receive thread, never AppKit.
        try check(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
            frameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(sequence)), infoFlagsOut: nil), "解码失败")
    }
    func stop() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        configuration = nil
        rawPool = nil
    }
    deinit { stop() }
}

extension VideoConfiguration {
    var decodedPixelFormat: OSType {
        mode == .fidelity ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
    var cgColorSpace: CGColorSpace { CGColorSpace(name: colorSpace == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)! }
    var primaries: CFString { colorSpace == .displayP3 ? kCVImageBufferColorPrimaries_P3_D65 : kCVImageBufferColorPrimaries_ITU_R_709_2 }
    func attachColor(to image: CVPixelBuffer) {
        CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey, cgColorSpace, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        if mode != .lossless {
            CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
    }
}

final class VideoSurface: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CALayer()
    private let imageLock = NSLock()
    private var newest: (CVPixelBuffer, UInt64)?
    private var scheduled = false
    private var generation = 0
    private var pointer: PointerUpdate?
    private var sourceAspect: CGFloat = 16.0 / 9.0
    var onSubmit: ((UInt64) -> Void)?
    var onFirstImage: (() -> Void)?
    private var hasImage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        cursorLayer.contentsGravity = .resizeAspect
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        updatePointerFrame()
        CATransaction.commit()
    }

    func offer(_ image: CVPixelBuffer, sequence: UInt64) {
        imageLock.lock()
        newest = (image, sequence)
        let shouldSchedule = !scheduled
        scheduled = true
        let expectedGeneration = generation
        imageLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.renderLatest(expectedGeneration)
        }
    }

    private func renderLatest(_ expectedGeneration: Int) {
        imageLock.lock()
        guard expectedGeneration == generation, let current = newest else {
            scheduled = false
            imageLock.unlock()
            return
        }
        // Keep the displayed frame while AVFoundation drains. Flushing on ordinary
        // backpressure causes the visible black flash reported when cursor traffic starts.
        guard videoLayer.isReadyForMoreMediaData else {
            imageLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
                self?.renderLatest(expectedGeneration)
            }
            return
        }
        newest = nil
        scheduled = false
        imageLock.unlock()

        let (image, sequence) = current
        sourceAspect = CGFloat(CVPixelBufferGetWidth(image)) / max(CGFloat(1), CGFloat(CVPixelBufferGetHeight(image)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updatePointerFrame()
        CATransaction.commit()
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
            formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        CMSetAttachment(sample, key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if videoLayer.status == .failed { videoLayer.flush() }
        videoLayer.enqueue(sample)
        onSubmit?(sequence)
        if !hasImage { hasImage = true; onFirstImage?() }
    }

    func setPointer(_ value: PointerUpdate) {
        pointer = value
        if let png = value.png, let bitmap = NSBitmapImageRep(data: png), let cgImage = bitmap.cgImage {
            cursorLayer.contents = cgImage
        } else if cursorLayer.contents == nil,
                  let bitmap = NSCursor.arrow.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                  let cgImage = bitmap.cgImage {
            cursorLayer.contents = cgImage
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updatePointerFrame()
        CATransaction.commit()
    }
    private func updatePointerFrame() {
        guard let pointer else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = !pointer.visible
        let rect = AVMakeRect(aspectRatio: CGSize(width: sourceAspect, height: 1), insideRect: bounds)
        let size: CGSize
        let hotspot: CGPoint
        if pointer.png == nil {
            // Standard cursors are drawn from the receiver's own Retina asset.
            size = NSCursor.arrow.image.size
            hotspot = NSCursor.arrow.hotSpot
        } else {
            let scale = window?.backingScaleFactor ?? 2
            size = CGSize(width: pointer.width / scale, height: pointer.height / scale)
            hotspot = CGPoint(x: pointer.hotX / scale, y: pointer.hotY / scale)
        }
        cursorLayer.frame = CGRect(x: rect.minX + pointer.x * rect.width - hotspot.x,
            y: rect.maxY - pointer.y * rect.height - size.height + hotspot.y,
            width: size.width, height: size.height)
    }
    func reset() {
        imageLock.lock(); generation += 1; newest = nil; scheduled = false; imageLock.unlock()
        videoLayer.flushAndRemoveImage()
        cursorLayer.isHidden = true
        pointer = nil
        sourceAspect = 16.0 / 9.0
        hasImage = false
    }
}

@available(macOS 14.0, *)
final class ScreenSender: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "wired.encode", qos: .userInteractive)
    private var encoder: VTCompressionSession?
    private var stream: SCStream?
    private var virtualDisplay: CGVirtualDisplay?
    private var active = false
    private var budget = FrameBudget(limit: 3)
    private var configured = false
    private var lastPTS = CMTime.invalid
    private var profile: DisplayProfile?
    private var mode: TransmissionMode = .lowLatency
    private var streamColorSpace: StreamColorSpace = .sRGB
    private var capturePixelFormat: OSType {
        switch mode {
        case .lowLatency: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .fidelity: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .lossless: return kCVPixelFormatType_32BGRA
        }
    }
    private let peer: CablePeer
    private(set) var displayID: CGDirectDisplayID = 0
    var onFailure: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onStats: ((StreamStatistics) -> Void)?
    private var acknowledged = 0
    private var skipped = 0
    private var lastStats = DispatchTime.now().uptimeNanoseconds
    private var lastRoundTrip = 0.0
    private var bytesSinceStats = 0
    private var rateSamples: [Double] = []
    private var mirror = false
    private var audioEnabled = false
    private var sentAudioConfiguration = false

    init(peer: CablePeer) { self.peer = peer }

    @MainActor func start(profile: DisplayProfile, mirror: Bool = false, audio: Bool = false, mode: TransmissionMode = .lowLatency) async throws {
        self.mode = mode
        streamColorSpace = mode != .lowLatency && profile.wideGamut ? .displayP3 : .sRGB
        guard mode != .fidelity || profile.hevc else { throw WireError.invalid("色彩保真需要 HEVC 硬件解码支持，请选择其他模式") }
        self.mirror = mirror
        self.audioEnabled = audio
        onStatus?(mirror ? "正在准备镜像采集 · \(profile.width) × \(profile.height)" : "正在创建虚拟显示器 · \(profile.width) × \(profile.height)")
        try profile.validate()
        self.profile = profile
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "Thunder Display"
        descriptor.vendorID = 0xEEEE
        descriptor.productID = 0x5744
        descriptor.serialNum = 1
        descriptor.maxPixelsWide = UInt32(profile.width)
        descriptor.maxPixelsHigh = UInt32(profile.height)
        descriptor.sizeInMillimeters = CGSize(width: Double(profile.width) / 218 * 25.4, height: Double(profile.height) / 218 * 25.4)
        descriptor.whitePoint = NSPoint(x: 0.3127, y: 0.3290)
        descriptor.redPrimary = streamColorSpace == .displayP3 ? NSPoint(x: 0.68, y: 0.32) : NSPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = streamColorSpace == .displayP3 ? NSPoint(x: 0.265, y: 0.69) : NSPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = NSPoint(x: 0.15, y: 0.06)
        descriptor.queue = queue
        if mirror {
            displayID = CGMainDisplayID()
            onStatus?("镜像主屏幕 · ID \(displayID) · 正在准备硬件编码器")
        } else {
            guard let display = CGVirtualDisplay(descriptor: descriptor) else { throw WireError.invalid("无法创建扩展屏幕（CGVirtualDisplay 返回空值）") }
            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = profile.hiDPI
            let factor = profile.hiDPI ? 2 : 1
            settings.modes = [CGVirtualDisplayMode(width: UInt(profile.width / factor), height: UInt(profile.height / factor), refreshRate: 60)!]
            guard display.apply(settings) else { throw WireError.invalid("系统拒绝此扩展屏幕尺寸 \(profile.width) × \(profile.height)") }
            virtualDisplay = display
            displayID = display.displayID
            onStatus?("虚拟显示器已创建 · ID \(displayID) · 正在准备硬件编码器")
        }
        try queue.sync {
            if mode == .lossless {
                // One raw frame in flight bounds memory and adapts cadence to the link.
                budget = FrameBudget(limit: 1)
                active = true
            } else { try createEncoder(profile) }
        }
        onStatus?(mode == .lossless ? "RGB 无损传输已准备 · 正在枚举屏幕" : (mirror ? "硬件编码器已准备 · 正在枚举主屏幕" : "硬件编码器已准备 · 正在等待 ScreenCaptureKit 枚举虚拟屏幕"))
        var target: SCDisplay?
        for _ in 0..<30 {
            guard !peer.isStopped else { throw WireError.invalid("连接已取消") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else { throw WireError.invalid("ScreenCaptureKit 未找到虚拟屏幕，请检查屏幕录制权限") }
        let config = SCStreamConfiguration()
        config.width = profile.width
        config.height = profile.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.pixelFormat = capturePixelFormat
        config.colorSpaceName = streamColorSpace == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        config.showsCursor = false
        config.scalesToFit = true
        config.captureResolution = .best
        config.capturesAudio = audio
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
        onStatus?("屏幕采集已启动 · 等待首帧")
    }

    private func createEncoder(_ profile: DisplayProfile) throws {
        let codec = profile.hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        try check(VTCompressionSessionCreate(allocator: nil, width: Int32(profile.width), height: Int32(profile.height),
            codecType: codec, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { ref, source, status, _, sample in
                guard let ref else { return }
                let owner = Unmanaged<ScreenSender>.fromOpaque(ref).takeUnretainedValue()
                let sequence = UInt64(UInt(bitPattern: source))
                owner.queue.async {
                    guard owner.active else { return }
                    guard status == noErr, let sample else { owner.onFailure?("硬件编码失败（\(status)）"); return }
                    do { try owner.encoded(sample, sequence: sequence) }
                    catch { owner.onFailure?(error.localizedDescription) }
                }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder), "无法创建硬件编码器")
        guard let encoder else { throw WireError.invalid("缺少硬件编码器") }
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue), "无法启用实时编码")
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), "无法关闭帧重排")
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel,
            value: mode == .fidelity ? kVTProfileLevel_HEVC_Main10_AutoLevel : (profile.hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)), "此硬件不支持所选编码模式")
        if mode == .fidelity {
            try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_OutputBitDepth, value: 10 as CFNumber), "此硬件不支持 10-bit 编码")
        }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        let bitrate = mode.bitrate(width: profile.width, height: profile.height)
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber), "Cannot set bitrate")
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: mode == .lowLatency ? kCFBooleanTrue : kCFBooleanFalse)
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ColorPrimaries, value: streamColorSpace == .displayP3 ? kCVImageBufferColorPrimaries_P3_D65 : kCVImageBufferColorPrimaries_ITU_R_709_2), "Cannot set primaries")
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB), "Cannot set transfer function")
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2), "Cannot set YCbCr matrix")
        try check(VTCompressionSessionPrepareToEncodeFrames(encoder), "硬件编码器准备失败")
        active = true
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard active, sampleBuffer.isValid else { return }
        if type == .audio { relayAudio(sampleBuffer); return }
        guard type == .screen,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer), let profile else { return }
        guard CVPixelBufferGetPixelFormatType(image) == capturePixelFormat,
              CVPixelBufferGetWidth(image) == profile.width, CVPixelBufferGetHeight(image) == profile.height else {
            onFailure?("屏幕采集不支持所选像素格式或尺寸，请选择其他模式")
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 { return }
        guard let sequence = budget.reserve(now: DispatchTime.now().uptimeNanoseconds) else { skipped += 1; return }
        lastPTS = pts
        if mode == .lossless {
            do { try sendRaw(image, sequence: sequence) }
            catch { onFailure?(error.localizedDescription) }
            return
        }
        guard let encoder else { return }
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: nil, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(sequence)), infoFlagsOut: nil)
        if result != noErr { onFailure?("编码器跟不上当前分辨率（\(result)）") }
    }

    private func sendRaw(_ image: CVPixelBuffer, sequence: UInt64) throws {
        guard let profile else { throw WireError.invalid("Missing display profile") }
        if !configured {
            peer.send(.configuration, try Wire.json(VideoConfiguration(width: profile.width, height: profile.height,
                hevc: false, parameterSets: [], mode: .lossless, colorSpace: streamColorSpace)))
            configured = true
        }
        let data = try RawFrame.pack(image, sequence: sequence)
        peer.send(.video, data)
        bytesSinceStats += data.count
    }

    private func relayAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioEnabled, let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM,
              stream.mChannelsPerFrame == 2, stream.mBitsPerChannel == 32, stream.mBytesPerFrame == 8,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < 256 * 1024 else { return }
        if !sentAudioConfiguration {
            let config = AudioConfiguration(sampleRate: stream.mSampleRate, channels: 2, bytesPerFrame: 8,
                                            bitsPerChannel: 32, interleaved: true)
            peer.send(.audioConfiguration, (try? Wire.json(config)) ?? Data())
            sentAudioConfiguration = true
        }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { return }
        peer.send(.audio, data)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }

    private func encoded(_ sample: CMSampleBuffer, sequence: UInt64) throws {
        guard let profile, let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { throw WireError.invalid("编码器返回空画面") }
        if !configured {
            var sets: [Data] = []
            for index in 0..<(profile.hevc ? 3 : 2) {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status: OSStatus
                if profile.hevc {
                    status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                try check(status, "无法读取编码参数")
                guard let pointer else { throw WireError.invalid("缺少编码参数") }
                sets.append(Data(bytes: pointer, count: size))
            }
            peer.send(.configuration, try Wire.json(VideoConfiguration(width: profile.width, height: profile.height,
                                                                      hevc: profile.hevc, parameterSets: sets, mode: mode, colorSpace: streamColorSpace)))
            configured = true
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < Wire.maximumPacket - 16 else { throw WireError.invalid("编码帧过大") }
        var data = Data()
        Wire.append(sequence, to: &data)
        data.append(Data(count: length))
        try data.withUnsafeMutableBytes { raw in
            try check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                destination: raw.baseAddress!.advanced(by: 8)), "无法读取编码帧")
        }
        peer.send(.video, data)
        bytesSinceStats += data.count
    }

    func acknowledge(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            do {
                guard data.count == 8 else { throw WireError.invalid("画面确认格式错误") }
                let seq = try Wire.integer(data, at: 0, as: UInt64.self)
                let now = DispatchTime.now().uptimeNanoseconds
                if let elapsed = try self.budget.acknowledge(seq, now: now) { self.lastRoundTrip = elapsed }
                self.acknowledged += 1
                if now - self.lastStats >= 1_000_000_000 {
                    let fps = Double(self.acknowledged) * 1_000_000_000 / Double(now - self.lastStats)
                    let mbps = Double(self.bytesSinceStats * 8) * 1_000_000_000 / Double(now - self.lastStats) / 1_000_000
                    self.rateSamples.append(mbps)
                    if self.rateSamples.count > 60 { self.rateSamples.removeFirst(self.rateSamples.count - 60) }
                    let stats = StreamStatistics(fps: fps, roundTripMilliseconds: self.lastRoundTrip,
                                                 megabitsPerSecond: mbps, codec: self.mode == .lossless ? "RGB 8-bit · \(self.streamColorSpace.rawValue) · 无损" : (self.mode == .fidelity ? "HEVC 10-bit · \(self.streamColorSpace.rawValue)" : (self.profile?.hevc == true ? "HEVC 8-bit · sRGB" : "H.264 8-bit · sRGB")),
                                                 samples: self.rateSamples)
                    self.onStats?(stats)
                    self.peer.send(.statistics, (try? Wire.json(stats)) ?? Data())
                    self.acknowledged = 0; self.bytesSinceStats = 0; self.lastStats = now
                }
            } catch { self.onFailure?(error.localizedDescription) }
        }
    }

    @MainActor func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync {
            active = false
            if let encoder {
                VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(encoder)
            }
            encoder = nil
        }
        virtualDisplay = nil
        audioEnabled = false; sentAudioConfiguration = false
        displayID = 0
        onStatus?("发送端视频已停止")
    }
}

extension RawFrame {
    static func pack(_ image: CVPixelBuffer, sequence: UInt64) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else {
            throw WireError.invalid("Lossless transport requires BGRA")
        }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        var data = Data(count: try byteCount(width: width, height: height))
        try check(CVPixelBufferLockBaseAddress(image, .readOnly), "Cannot lock captured RGB")
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw WireError.invalid("Missing captured RGB") }
        let stride = CVPixelBufferGetBytesPerRow(image)
        var header = sequence.bigEndian
        data.withUnsafeMutableBytes { raw in
            withUnsafeBytes(of: &header) { raw.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: 8) }
            for row in 0..<height {
                memcpy(raw.baseAddress!.advanced(by: 8 + row * width * 4), base.advanced(by: row * stride), width * 4)
            }
        }
        return data
    }
}
