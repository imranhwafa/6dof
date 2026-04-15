import ScreenCaptureKit
import CoreVideo
import CoreMedia
import Metal
import Foundation

/// Manages one SCStream per monitor slot.
///
/// Conforms to SCStreamOutput and SCStreamDelegate directly (self-conformer).
/// SCStream holds only a weak reference to SCStreamOutput — a local conformer would be
/// deallocated before any frame arrives. CaptureManager must live as long as capture is active.
///
/// Blit discipline (ARC-03): captureOutput blits the IOSurface-backed texture into an owned
/// MTLTexture slot immediately and lets all IOSurface references go out of scope before returning.
/// This prevents -3821 pool exhaustion.
final class CaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: - Dependencies

    let texturePool: TexturePool
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?

    // MARK: - Stream state

    /// One stream per monitor slot. Index 0 = left monitor, 1 = right monitor.
    private var streams: [Int: SCStream] = [:]

    /// Dedicated serial queue for capture callback processing.
    /// Passed to addStreamOutput — keeps blit off the main thread.
    private let captureQueue = DispatchQueue(
        label: "com.app.sixdof.capture",
        qos: .userInteractive
    )

    // MARK: - Triple-buffer write indices

    /// Rotating write index per monitor slot (0, 1, 2 cycling).
    private var writeIndices: [Int: Int] = [:]

    // MARK: - Init

    /// - Parameter device: The MTLDevice used for texture creation.
    ///   Must be the same device used by the render layer (Phase 4 integration).
    ///   For Phase 1, pass MTLCreateSystemDefaultDevice().
    init(device: MTLDevice = MTLCreateSystemDefaultDevice()!) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.texturePool = TexturePool()

        super.init()

        // Create CVMetalTextureCache once — reuse across all frames
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let cache else {
            fatalError("[CaptureManager] Failed to create CVMetalTextureCache: \(result)")
        }
        self.textureCache = cache
    }

    // MARK: - Start / Stop

    /// Configure and start an SCStream for one monitor slot.
    /// - Parameters:
    ///   - filter: SCContentFilter targeting the chosen window (from WindowPicker).
    ///   - monitorSlot: 0 for left monitor, 1 for right monitor.
    ///   - targetFPS: Requested capture rate. Default 60.
    func startCapture(
        filter: SCContentFilter,
        monitorSlot: Int,
        targetFPS: Int = 60
    ) async throws {
        let config = SCStreamConfiguration()

        // Width/height are derived from the filter's content rect.
        // WindowPicker will provide correct dimensions in Plan 04; use 1920x1080 as safe default.
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA  // matches MTLPixelFormat.bgra8Unorm
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 5  // headroom above default 3; prevents -3821 under processing spikes

        // Pre-allocate owned texture slots now that we know resolution
        texturePool.allocate(device: device, width: config.width, height: config.height, monitor: monitorSlot)
        writeIndices[monitorSlot] = 0

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // Pass self — SCStream holds only weak reference; strong ref kept here in streams dict
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        streams[monitorSlot] = stream

        print("[CaptureManager] Stream started for monitor slot \(monitorSlot) at \(targetFPS)fps")
    }

    func stopCapture(monitorSlot: Int) async {
        guard let stream = streams[monitorSlot] else { return }
        try? await stream.stopCapture()
        streams.removeValue(forKey: monitorSlot)
        print("[CaptureManager] Stream stopped for monitor slot \(monitorSlot)")
    }

    // MARK: - SCStreamOutput (called on captureQueue)

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        // Determine which monitor slot this stream belongs to
        guard let slotIndex = streams.first(where: { $0.value === stream })?.key else { return }

        processFrame(sampleBuffer, monitorSlot: slotIndex)
        // sampleBuffer is released here on return — ARC-03 blit discipline satisfied
    }

    // MARK: - SCStreamDelegate (called on internal SCStream queue)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        // -3821 = IOSurface pool exhaustion. Surface prominently — indicates blit discipline failure.
        print("""
            [CaptureManager] STREAM STOPPED WITH ERROR
            Domain: \(nsError.domain)
            Code:   \(nsError.code)
            Desc:   \(nsError.localizedDescription)
            \(nsError.code == -3821 ? "-> Code -3821: IOSurface pool exhaustion. Check blit-and-release discipline." : "")
            """)
    }

    // MARK: - Frame processing (blit-and-release)

    private func processFrame(_ sampleBuffer: CMSampleBuffer, monitorSlot: Int) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Debug assertion: confirm IOSurface zero-copy path is active
        assert(
            CVPixelBufferGetIOSurface(imageBuffer) != nil,
            "[CaptureManager] Expected IOSurface-backed pixel buffer — zero-copy path inactive"
        )

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        // Create an MTLTexture aliasing the IOSurface (zero-copy, no CPU memcpy)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache!,
            imageBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard result == kCVReturnSuccess,
              let cvTexture,
              let srcTexture = CVMetalTextureGetTexture(cvTexture) else {
            print("[CaptureManager] Failed to create MTLTexture from IOSurface: \(result)")
            return
        }

        // Get owned destination texture from pool
        let writeIdx = writeIndices[monitorSlot] ?? 0
        guard let dstTexture = texturePool.ownedTexture(monitor: monitorSlot, bufferIndex: writeIdx) else {
            // Pool not yet allocated — skip this frame
            return
        }

        // Blit immediately into owned texture
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }

        blit.copy(
            from: srcTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: dstTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        // Retain cvTexture until GPU blit completes (Pitfall 6 prevention)
        let capturedCVTexture = cvTexture
        commandBuffer.addCompletedHandler { _ in
            // cvTexture goes out of scope here — IOSurface backing released after GPU finishes
            _ = capturedCVTexture
        }
        commandBuffer.commit()

        // Write owned texture reference to pool for render-side consumption
        texturePool.write(dstTexture, monitor: monitorSlot, bufferIndex: writeIdx)
        writeIndices[monitorSlot] = (writeIdx + 1) % TexturePool.bufferCount

        print("[CaptureManager] Frame slot=\(monitorSlot) buf=\(writeIdx) \(width)x\(height)")
        // sampleBuffer released here on return from processFrame -> captureOutput callback
    }
}
