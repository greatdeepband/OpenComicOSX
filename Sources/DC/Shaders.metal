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