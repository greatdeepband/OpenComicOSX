import Metal
import MetalKit
import CoreVideo

// MARK: - SpreadInfo

/// Metadata for a composited left+right page spread.
struct SpreadInfo {
    /// The sequential index of the right (paired) page.
    let rightIndex: Int
    /// The Y origin and height of this spread row in document space.
    let rect: CGRect
}

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

    /// Live spread textures keyed by the LEFT page's sequential index.
    /// Only maintained while `pagesPerRow == 2` is active.
    private var spreadTextures: [Int: MTLTexture] = [:]

    /// Compute pipeline used to blit two page textures into a spread texture.
    private var blitPipeline: MTLComputePipelineState?

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

        // Create the blit compute pipeline for spread composition
        if let blitFunc = library.makeFunction(name: "composeSpreadKernel") {
            do {
                blitPipeline = try device.makeComputePipelineState(function: blitFunc)
            } catch {
                // Non-fatal — spread composition will fall back to individual rendering
            }
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
        // Evict spread textures whose left page is outside the range
        spreadTextures = spreadTextures.filter { range.contains($0.key) }
    }

    /// Sets the spread map for vertical-double mode.
    /// Called by MetalPageView.Coordinator whenever the layout changes.
    /// - Parameter spreads: Dict keyed by left-page sequential index → SpreadInfo.
    func setSpreads(_ spreads: [Int: SpreadInfo]) {
        // Evict spreads whose left page no longer exists
        spreadTextures = spreadTextures.filter { spreads[$0.key] != nil }
    }

    /// Composites a spread texture from the left and right page textures.
    /// Returns the spread texture (newly created or cached) for the given left index.
    /// Must be called with valid left/right textures already in the ring buffer.
    func composeSpread(
        leftIndex: Int,
        rightIndex: Int,
        leftRect: CGRect,
        rightRect: CGRect,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let blitPipeline = blitPipeline,
              let leftTex = textureRing[leftIndex],
              let rightTex = textureRing[rightIndex] else { return nil }

        // Reuse existing spread texture if dimensions match
        let spreadWidth = Int(leftRect.width + rightRect.width)
        let spreadHeight = Int(max(leftRect.height, rightRect.height))

        if let existing = spreadTextures[leftIndex],
           existing.width == spreadWidth && existing.height == spreadHeight {
            // Recompose into the existing texture
            renderSpreadIntoTexture(
                leftTex: leftTex, rightTex: rightTex,
                leftRect: leftRect, rightRect: rightRect,
                target: existing,
                pipeline: blitPipeline,
                commandBuffer: commandBuffer
            )
            return existing
        }

        // Create a new spread texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: spreadWidth,
            height: spreadHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let spreadTex = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        spreadTextures[leftIndex] = spreadTex

        renderSpreadIntoTexture(
            leftTex: leftTex, rightTex: rightTex,
            leftRect: leftRect, rightRect: rightRect,
            target: spreadTex,
            pipeline: blitPipeline,
            commandBuffer: commandBuffer
        )

        return spreadTex
    }

    private func renderSpreadIntoTexture(
        leftTex: MTLTexture, rightTex: MTLTexture,
        leftRect: CGRect, rightRect: CGRect,
        target: MTLTexture,
        pipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)

        // Set the three textures: left, right, destination
        encoder.setTexture(leftTex, index: 0)
        encoder.setTexture(rightTex, index: 1)
        encoder.setTexture(target, index: 2)

        // Pass layout params as constants: [leftWidth, rightX, gap, 0]
        var params: (Float, Float, Float, Float) = (
            Float(leftRect.width),
            Float(leftRect.width + 2), // right page X offset (includes gap)
            2.0, // gap between pages
            0
        )
        encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(
            width: (target.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (target.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
    }

    /// Encode a render pass for the given viewport and page positions.
    /// When `spreads` is provided (vertical-double mode), spread textures are used
    /// in place of individual page textures.
    func render(
        viewport: CGRect,
        visibleRange: ClosedRange<Int>,
        pagePositions: [Int: CGRect],
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        spreads: [Int: SpreadInfo] = [:]
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
            guard let rect = pagePositions[pageIndex] else { continue }

            let texture: MTLTexture?
            if let spread = spreads[pageIndex] {
                // Vertical double: composite spread texture
                texture = spreadTextures[pageIndex]
                _ = spread.rightIndex // used by composeSpread caller
            } else {
                texture = textureRing[pageIndex]
            }

            guard let tex = texture else { continue }
            encoder.setFragmentTexture(tex, index: 0)

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