import AppKit
import ScreenCaptureKit
import VideoToolbox
import AVFoundation

func check(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else { throw WireError.invalid("\(message)（\(status)）") }
}

func makeFormat(_ config: VideoConfiguration) throws -> CMVideoFormatDescription {
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
    var onImage: ((CVPixelBuffer, UInt64) -> Void)?
    var onFailure: ((String) -> Void)?

    func configure(_ config: VideoConfiguration) throws {
        stop()
        let format = try makeFormat(config)
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, frame, status, _, image, _, _ in
            guard let ref else { return }
            let decoder = Unmanaged<HardwareDecoder>.fromOpaque(ref).takeUnretainedValue()
            guard status == noErr, let image else {
                decoder.onFailure?("硬件解码失败，请选择 4K 流畅档（\(status)）")
                return
            }
            decoder.onImage?(image, UInt64(UInt(bitPattern: frame)))
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     kCVPixelBufferIOSurfacePropertiesKey: [:],
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        try check(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
            decoderSpecification: spec, imageBufferAttributes: attrs, outputCallback: &callback,
            decompressionSessionOut: &session), "此设备无法硬件解码该分辨率，请使用 4K 档")
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        self.format = format
    }

    func decode(_ data: Data) throws {
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
    }
    deinit { stop() }
}

final class VideoSurface: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CALayer()
    private let imageLock = NSLock()
    private var newest: (CVPixelBuffer, UInt64)?
    private var scheduled = false
    private var generation = 0
    private var pointer: PointerUpdate?
    var onSubmit: ((UInt64) -> Void)?
    var onFirstImage: (() -> Void)?
    private var hasImage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        cursorLayer.contentsGravity = .resize
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
            guard let self else { return }
            self.imageLock.lock()
            guard expectedGeneration == self.generation else { self.imageLock.unlock(); return }
            let current = self.newest
            self.newest = nil
            self.scheduled = false
            self.imageLock.unlock()
            guard let (image, sequence) = current else { return }
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
            // Only decoded images may be superseded; compressed dependencies remain intact.
            if self.videoLayer.status == .failed || !self.videoLayer.isReadyForMoreMediaData { self.videoLayer.flush() }
            self.videoLayer.enqueue(sample)
            self.onSubmit?(sequence)
            if !self.hasImage { self.hasImage = true; self.onFirstImage?() }
        }
    }

    func setPointer(_ value: PointerUpdate) {
        pointer = value
        if let png = value.png, let bitmap = NSBitmapImageRep(data: png), let cgImage = bitmap.cgImage {
            cursorLayer.contents = cgImage
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updatePointerFrame()
        CATransaction.commit()
    }
    private func updatePointerFrame() {
        guard let pointer else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = !pointer.visible
        // Video is always 16:9 for the supported iMac panels.
        let rect = AVMakeRect(aspectRatio: CGSize(width: 16, height: 9), insideRect: bounds)
        let scale = window?.backingScaleFactor ?? 2
        let w = pointer.width / scale, h = pointer.height / scale
        cursorLayer.frame = CGRect(x: rect.minX + pointer.x * rect.width - pointer.hotX / scale,
            y: rect.maxY - pointer.y * rect.height - h + pointer.hotY / scale, width: w, height: h)
    }
    func reset() {
        imageLock.lock(); generation += 1; newest = nil; scheduled = false; imageLock.unlock()
        videoLayer.flushAndRemoveImage()
        cursorLayer.isHidden = true
        pointer = nil
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
    private let peer: CablePeer
    private(set) var displayID: CGDirectDisplayID = 0
    var onFailure: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onStats: ((String) -> Void)?
    private var acknowledged = 0
    private var skipped = 0
    private var lastStats = DispatchTime.now().uptimeNanoseconds
    private var lastRoundTrip = 0.0

    init(peer: CablePeer) { self.peer = peer }

    @MainActor func start(profile: DisplayProfile) async throws {
        onStatus?("正在创建虚拟显示器 · \(profile.width) × \(profile.height)")
        try profile.validate()
        self.profile = profile
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "WiredDisplay"
        descriptor.vendorID = 0xEEEE
        descriptor.productID = 0x5744
        descriptor.serialNum = 1
        descriptor.maxPixelsWide = UInt32(profile.width)
        descriptor.maxPixelsHigh = UInt32(profile.height)
        descriptor.sizeInMillimeters = CGSize(width: Double(profile.width) / 218 * 25.4, height: Double(profile.height) / 218 * 25.4)
        descriptor.whitePoint = NSPoint(x: 0.3127, y: 0.3290)
        descriptor.redPrimary = NSPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = NSPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = NSPoint(x: 0.15, y: 0.06)
        descriptor.queue = queue
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { throw WireError.invalid("无法创建扩展屏幕（CGVirtualDisplay 返回空值）") }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = profile.hiDPI
        let factor = profile.hiDPI ? 2 : 1
        settings.modes = [CGVirtualDisplayMode(width: UInt(profile.width / factor), height: UInt(profile.height / factor), refreshRate: 60)!]
        guard display.apply(settings) else { throw WireError.invalid("系统拒绝此扩展屏幕尺寸 \(profile.width) × \(profile.height)") }
        virtualDisplay = display
        displayID = display.displayID
        onStatus?("虚拟显示器已创建 · ID \(displayID) · 正在准备硬件编码器")
        try queue.sync { try createEncoder(profile) }
        onStatus?("硬件编码器已准备 · 正在等待 ScreenCaptureKit 枚举虚拟屏幕")
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
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.scalesToFit = true
        config.captureResolution = .best
        config.capturesAudio = false
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
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
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel,
            value: profile.hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        let bitrate = min(150_000_000, max(40_000_000, profile.width * profile.height * 10))
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        try check(VTCompressionSessionPrepareToEncodeFrames(encoder), "硬件编码器准备失败")
        active = true
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard active, type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer), let encoder else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 { return }
        guard let sequence = budget.reserve(now: DispatchTime.now().uptimeNanoseconds) else { skipped += 1; return }
        lastPTS = pts
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: nil, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(sequence)), infoFlagsOut: nil)
        if result != noErr { onFailure?("编码器跟不上当前分辨率（\(result)）") }
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
                                                                      hevc: profile.hevc, parameterSets: sets)))
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
                    self.onStats?(String(format: "%.0f 帧/秒 · 确认往返 %.0f ms", fps, self.lastRoundTrip))
                    self.acknowledged = 0; self.lastStats = now
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
        displayID = 0
        onStatus?("发送端视频已停止")
    }
}
