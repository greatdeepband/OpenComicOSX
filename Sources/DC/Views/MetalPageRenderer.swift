import Metal
import MetalKit
import CoreVideo

/// Metal device, command queue, and texture ring buffer.
/// Handles CVPixelBuffer → MTLTexture upload and GPU render encoding.
final class MetalPageRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    private var textureRing: [Int: (texture: MTLTexture, lastAccess: Date)] = [:]
    private let maxCachedPages = 10

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let textureCache = cache else { return nil }
        self.textureCache = textureCache
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
        if textureRing.count >= maxCachedPages {
            let lru = textureRing.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
            if let key = lru { textureRing.removeValue(forKey: key) }
        }
        textureRing[pageIndex] = (texture, Date())
        return texture
    }

    /// Returns the texture for a cached page, updating its last-access time.
    func texture(for pageIndex: Int) -> MTLTexture? {
        guard var entry = textureRing[pageIndex] else { return nil }
        entry.lastAccess = Date()
        textureRing[pageIndex] = entry
        return entry.texture
    }

    /// Evict all textures outside the given page range.
    func evictOutside(_ range: ClosedRange<Int>) {
        textureRing = textureRing.filter { range.contains($0.key) }
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

        // Simple passthrough vertex/fragment shaders (see Shaders.metal)
        // Quad vertices: two triangles covering each page rect
        for pageIndex in visibleRange {
            guard let texture = textureRing[pageIndex]?.texture,
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