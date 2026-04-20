import Metal
import MetalKit
import CoreVideo

// MARK: - TextureRingBuffer

/// Thread-unsafe LRU texture ring buffer with a fixed capacity.
struct TextureRingBuffer {
    private var entries: [Int: (texture: MTLTexture, lastAccess: Date)] = [:]
    private let maxSize: Int

    init(maxSize: Int = 10) {
        self.maxSize = maxSize
    }

    // MARK: - Mutating API

    /// Insert or replace a texture for the given page index.
    /// Evicts the least-recently-used entry if at capacity.
    mutating func insert(_ texture: MTLTexture, for pageIndex: Int) {
        if entries.count >= maxSize {
            let lruKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
            if let key = lruKey { entries.removeValue(forKey: key) }
        }
        entries[pageIndex] = (texture, Date())
    }

    /// Touch the entry for `pageIndex`, updating its last-access time.
    /// Returns the texture if found.
    mutating func touch(pageIndex: Int) -> MTLTexture? {
        guard var entry = entries[pageIndex] else { return nil }
        entry.lastAccess = Date()
        entries[pageIndex] = entry
        return entry.texture
    }

    /// Evict all entries outside the given range.
    mutating func evictOutside(_ range: ClosedRange<Int>) {
        entries = entries.filter { range.contains($0.key) }
    }

    // MARK: - Non-mutating subscript

    subscript(pageIndex: Int) -> MTLTexture? {
        entries[pageIndex]?.texture
    }
}

// MARK: - MetalPageRenderer

/// Metal device, command queue, and texture ring buffer.
/// Handles CVPixelBuffer → MTLTexture upload and GPU render encoding.
final class MetalPageRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache
    let pipelineState: MTLRenderPipelineState

    private var textureRing = TextureRingBuffer(maxSize: 10)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let textureCache = cache else { return nil }
        self.textureCache = textureCache

        // Create the render pipeline state from the metal shaders
        guard let library = device.makeDefaultLibrary(),
              let vertexFunc = library.makeFunction(name: "vertexShader"),
              let fragmentFunc = library.makeFunction(name: "fragmentShader") else {
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            return nil
        }
    }

    /// Upload a CVPixelBuffer to a MTLTexture and store in the ring buffer.
    func upload(pixelBuffer: CVPixelBuffer, for pageIndex: Int) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            return nil
        }

        // Ring buffer: evict LRU if at capacity
        textureRing.insert(texture, for: pageIndex)
        return texture
    }

    /// Returns the texture for a cached page, updating its last-access time.
    func texture(for pageIndex: Int) -> MTLTexture? {
        return textureRing.touch(pageIndex: pageIndex)
    }

    /// Evict all textures outside the given page range.
    func evictOutside(_ range: ClosedRange<Int>) {
        textureRing.evictOutside(range)
    }

    /// Encode a render pass for the given viewport and page positions.
    func render(
        viewport: CGRect,
        visibleRange: ClosedRange<Int>,
        pagePositions: [Int: CGRect],
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0,
            width: Double(viewport.width), height: Double(viewport.height),
            znear: 0, zfar: 1
        ))

        // Set the render pipeline state
        encoder.setRenderPipelineState(pipelineState)

        // Simple passthrough vertex/fragment shaders (see Shaders.metal)
        // Quad vertices: two triangles covering each page rect
        for pageIndex in visibleRange {
            guard let texture = textureRing[pageIndex],
                  let rect = pagePositions[pageIndex] else { continue }

            encoder.setFragmentTexture(texture, index: 0)

            let vertices: [Float] = [
                Float(rect.minX), Float(rect.minY), 0, 1,
                Float(rect.maxX), Float(rect.minY), 0, 1,
                Float(rect.minX), Float(rect.maxY), 0, 1,
                Float(rect.maxX), Float(rect.maxY), 0, 1
            ]
            encoder.setVertexBytes(vertices, length: MemoryLayout<Float>.stride * 4, index: 0)

            let texCoords: [Float] = [0, 1, 1, 1, 0, 0, 1, 0]
            encoder.setVertexBytes(texCoords, length: MemoryLayout<Float>.stride * 4, index: 1)

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
    }
}