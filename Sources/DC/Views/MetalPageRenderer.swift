import Metal
import CoreVideo

// MARK: - TextureRingBuffer

/// Fixed-capacity LRU map of page index → MTLTexture. Not thread-safe; callers
/// are expected to serialize access (MetalPageRenderer is used only from the
/// main actor in this project).
struct TextureRingBuffer {
    private var entries: [Int: (texture: MTLTexture, lastAccess: Date)] = [:]
    private let maxSize: Int

    init(maxSize: Int = 10) {
        self.maxSize = maxSize
    }

    mutating func insert(_ texture: MTLTexture, for pageIndex: Int) {
        if entries.count >= maxSize {
            if let lruKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                entries.removeValue(forKey: lruKey)
            }
        }
        entries[pageIndex] = (texture, Date())
    }

    mutating func touch(pageIndex: Int) -> MTLTexture? {
        guard var entry = entries[pageIndex] else { return nil }
        entry.lastAccess = Date()
        entries[pageIndex] = entry
        return entry.texture
    }

    subscript(pageIndex: Int) -> MTLTexture? {
        entries[pageIndex]?.texture
    }
}

// MARK: - MetalPageRenderer

/// Metal device, command queue, and texture ring buffer.
/// Handles CVPixelBuffer → MTLTexture upload and GPU render encoding for the
/// vertical and vertical-double reading modes.
final class MetalPageRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState

    private var textureRing = TextureRingBuffer(maxSize: ReaderConstants.pageCacheCap)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue

        // Prefer the SPM default library; fall back to runtime compilation of
        // the bundled Shaders.metal so the .app bundle doesn't need a
        // pre-compiled .metallib.
        let library: MTLLibrary?
        if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
        } else if let metalURL = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
                  let metalSrc = try? String(contentsOf: metalURL, encoding: .utf8) {
            library = try? device.makeLibrary(source: metalSrc, options: nil)
        } else {
            library = nil
        }

        guard let library = library,
              let vertexFunc = library.makeFunction(name: "vertexShader"),
              let fragmentFunc = library.makeFunction(name: "fragmentShader") else {
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let state = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            return nil
        }
        self.pipelineState = state
    }

    /// Copy a 32BGRA CVPixelBuffer into a device-owned MTLTexture and store it
    /// in the ring buffer. An independent texture is used (rather than
    /// `CVMetalTextureCacheCreateTextureFromImage`) so the CVPixelBuffer can be
    /// released/evicted without affecting subsequent sampling — a previously
    /// shared backing caused black pages once the pixel buffer was evicted.
    func upload(pixelBuffer: CVPixelBuffer, for pageIndex: Int) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        texture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: bytesPerRow)

        textureRing.insert(texture, for: pageIndex)
        return texture
    }

    /// Returns the cached texture for a page, touching its LRU timestamp.
    func texture(for pageIndex: Int) -> MTLTexture? {
        textureRing.touch(pageIndex: pageIndex)
    }

    /// Encode a render pass for the given viewport and page positions.
    ///
    /// `viewport` is the CAMetalLayer's frame in documentView coordinates —
    /// the drawable maps 1:1 onto this rect. The vertex shader projects
    /// page rects (also in doc coords) into NDC relative to this viewport.
    /// MUST be the metalLayer frame, not the clipView bounds — they differ
    /// whenever the drawable is smaller than the clip (zoomed out or
    /// recentred), and using clip bounds makes the page render squished.
    func render(
        viewport: CGRect,
        visibleRange: ClosedRange<Int>,
        pagePositions: [Int: CGRect],
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        // MTLViewport is specified in drawable pixels. Infer the drawable size
        // from the colour attachment texture so we don't have to plumb
        // backingScaleFactor through from AppKit.
        var drawW: Double = Double(viewport.width)
        var drawH: Double = Double(viewport.height)
        if let drawTex = renderPassDescriptor.colorAttachments[0].texture {
            drawW = Double(drawTex.width)
            drawH = Double(drawTex.height)
        }
        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0,
            width: drawW, height: drawH,
            znear: 0, zfar: 1
        ))
        encoder.setRenderPipelineState(pipelineState)

        // SIMD4<Float> has the same 16-byte layout as the shader's PageUniforms
        // struct: (viewportOriginX, viewportOriginY, viewportWidth, viewportHeight).
        var uniforms = SIMD4<Float>(
            Float(viewport.origin.x),
            Float(viewport.origin.y),
            Float(viewport.width),
            Float(viewport.height)
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)

        for pageIndex in visibleRange {
            guard let rect = pagePositions[pageIndex],
                  let tex = textureRing[pageIndex] else { continue }
            encoder.setFragmentTexture(tex, index: 0)

            let vertices: [Float] = [
                Float(rect.minX), Float(rect.minY), 0, 1,
                Float(rect.maxX), Float(rect.minY), 0, 1,
                Float(rect.minX), Float(rect.maxY), 0, 1,
                Float(rect.maxX), Float(rect.maxY), 0, 1
            ]
            encoder.setVertexBytes(vertices, length: MemoryLayout<Float>.stride * 16, index: 0)

            let texCoords: [Float] = [0, 0, 1, 0, 0, 1, 1, 1]
            encoder.setVertexBytes(texCoords, length: MemoryLayout<Float>.stride * 8, index: 1)

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
    }
}
