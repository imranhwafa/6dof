import Metal
import Foundation

/// Thread-safe triple-buffered texture hand-off between capture queue and render queue.
///
/// Two monitor slots (0 = left, 1 = right). Three owned MTLTexture buffers per slot.
/// Capture queue writes via write(_:monitor:bufferIndex:).
/// Render queue reads via read(monitor:).
///
/// Static-content frames (SCK-04): When SCStream does not deliver a new frame (window
/// content unchanged), read(monitor:) returns the last valid texture. No nil, no freeze.
final class TexturePool {

    // MARK: - Constants

    static let monitorCount = 2
    static let bufferCount = 3  // triple-buffer

    // MARK: - Storage

    private var lock = NSLock()

    /// slots[monitorIndex][bufferIndex] — owned MTLTexture or nil before first frame
    private var slots: [[MTLTexture?]]

    /// Index of the most recently written buffer for each monitor slot
    private var readIndices: [Int]

    // MARK: - Init

    init() {
        slots = Array(
            repeating: Array(repeating: nil, count: TexturePool.bufferCount),
            count: TexturePool.monitorCount
        )
        readIndices = Array(repeating: 0, count: TexturePool.monitorCount)
    }

    // MARK: - Write (called from capture queue)

    /// Write an owned texture into the pool.
    /// - Parameters:
    ///   - texture: Owned MTLTexture produced by blit from IOSurface-backed texture.
    ///   - monitor: Slot index (0 or 1).
    ///   - bufferIndex: Which of the 3 buffer slots to write into (0, 1, or 2).
    func write(_ texture: MTLTexture, monitor: Int, bufferIndex: Int) {
        lock.withLock {
            slots[monitor][bufferIndex] = texture
            readIndices[monitor] = bufferIndex
        }
    }

    // MARK: - Read (called from render queue)

    /// Returns the most recently written texture for a monitor slot.
    /// Returns nil only before the first frame arrives (not after static-content gaps).
    func read(monitor: Int) -> MTLTexture? {
        lock.withLock { slots[monitor][readIndices[monitor]] }
    }

    // MARK: - Direct slot access (for CaptureManager blit destination)

    /// Returns the pre-allocated owned texture at a specific buffer index.
    /// Used by CaptureManager to get the destination texture before blitting.
    /// Returns nil if allocate(device:width:height:monitor:) has not been called yet.
    func ownedTexture(monitor: Int, bufferIndex: Int) -> MTLTexture? {
        lock.withLock { slots[monitor][bufferIndex] }
    }

    // MARK: - Pre-allocate owned textures

    /// Pre-allocate all owned texture slots for a monitor given its resolution.
    /// Call this once when the capture stream is configured, before frames arrive.
    /// - Parameters:
    ///   - device: The MTLDevice (same device used for rendering).
    ///   - width: Pixel width of the captured window.
    ///   - height: Pixel height of the captured window.
    ///   - monitor: Slot index (0 or 1).
    func allocate(device: MTLDevice, width: Int, height: Int, monitor: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private  // GPU-only; blit encoder writes here

        lock.withLock {
            for bufferIndex in 0..<TexturePool.bufferCount {
                slots[monitor][bufferIndex] = device.makeTexture(descriptor: descriptor)
            }
        }
    }
}
