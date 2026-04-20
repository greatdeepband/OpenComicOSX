#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                             constant float4 *vertices [[buffer(0)]],
                             constant float2 *texCoords [[buffer(1)]]) {
    VertexOut out;
    out.position = vertices[vertexID];
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return tex.sample(s, in.texCoord);
}

// MARK: - Loupe Compute Kernel

/// Renders a 2× magnified circular crop of the source texture centred on `cursorTexCoord`.
/// Buffer index 0: [cursorX: float, cursorY: float, radius: float]
kernel void loupeKernel(texture2d<float, access::read> srcTex [[texture(0)]],
                        texture2d<float, access::write> destTex [[texture(1)]],
                        constant float *params [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    const float w = float(destTex.get_width());
    const float h = float(destTex.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) { return; }

    const float cursorX   = params[0];
    const float cursorY   = params[1];
    const float radius    = params[2];
    const float magnify   = 2.0;

    // Normalised coords within the loupe quad (0→1, 0 at bottom-left).
    const float u = float(gid.x) / w;
    const float v = float(gid.y) / h;

    // Remap to source texture space, centred on cursor with 2× zoom-out.
    const float srcX = cursorX + (u - 0.5) * radius / magnify;
    const float srcY = cursorY + (v - 0.5) * radius / magnify;

    // Circle clip: discard pixels outside the loupe circle.
    const float dx = (u - 0.5) * 2.0;
    const float dy = (v - 0.5) * 2.0;
    if (dx * dx + dy * dy > 1.0) {
        destTex.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    // Sample with border clamp.
    const uint tw = srcTex.get_width();
    const uint th = srcTex.get_height();
    const uint sx = uint(clamp(srcX, 0.0, 1.0) * float(tw - 1));
    const uint sy = uint(clamp(srcY, 0.0, 1.0) * float(th - 1));
    destTex.write(srcTex.read(uint2(sx, sy)), gid);
}

// MARK: - Spread Composition Compute Kernel

/// Composites two page textures side-by-side into a single spread texture.
/// Buffer index 0: [leftWidth: float, rightX: float, gap: float, _: float]
kernel void composeSpreadKernel(texture2d<float, access::read> leftTex [[texture(0)]],
                                texture2d<float, access::read> rightTex [[texture(1)]],
                                texture2d<float, access::write> destTex [[texture(2)]],
                                constant float *params [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destTex.get_width() || gid.y >= destTex.get_height()) {
        return;
    }

    float leftWidth  = params[0];
    float rightX    = params[1];
    float gap       = params[2];

    float4 color;

    if (float(gid.x) < leftWidth) {
        // Left page — map X directly
        uint2 srcCoord = uint2(gid.x, gid.y);
        srcCoord.x = min(srcCoord.x, leftTex.get_width() - 1);
        srcCoord.y = min(srcCoord.y, leftTex.get_height() - 1);
        color = leftTex.read(srcCoord);
    } else {
        // Right page — offset by gap
        float rightXNorm = float(gid.x) - rightX;
        uint2 srcCoord = uint2(rightXNorm, gid.y);
        srcCoord.x = min(srcCoord.x, rightTex.get_width() - 1);
        srcCoord.y = min(srcCoord.y, rightTex.get_height() - 1);
        color = rightTex.read(srcCoord);
    }

    destTex.write(color, gid);
}