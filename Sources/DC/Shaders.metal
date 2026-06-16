#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Uniforms for projecting document-space vertices into Metal NDC.
//   viewportOriginX : doc-space X coordinate of the drawable's left edge
//   viewportOriginY : doc-space Y coordinate of the drawable's top edge
//   viewportWidth   : drawable width in document points
//   viewportHeight  : drawable height in document points
// The viewport MUST be the CAMetalLayer's frame (in documentView coords), not
// the clipView's bounds — otherwise when the drawable is smaller than the clip
// (zoomed out, doc smaller than viewport, recentreIfContentFits active) the
// normalisation factor is wrong and the page renders squished.
struct PageUniforms {
    float viewportOriginX;
    float viewportOriginY;
    float viewportWidth;
    float viewportHeight;
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                             constant float4 *vertices [[buffer(0)]],
                             constant float2 *texCoords [[buffer(1)]],
                             constant PageUniforms &u [[buffer(2)]]) {
    VertexOut out;

    // Project CPU-provided document-space vertex into Metal NDC. Page rects are
    // in document points (top-origin; y increases downward because the hosting
    // NSView is isFlipped). DO NOT clamp — the rasterizer clips the triangle
    // against the NDC frustum, preserving natural texture interpolation for the
    // visible slice. Clamping squashes off-viewport vertices onto the edges
    // while the texcoords keep interpolating linearly, producing the vertical
    // stretch bug that shipped in earlier Metal pipeline versions.
    const float docX = vertices[vertexID].x;
    const float docY = vertices[vertexID].y;
    const float viewX = (docX - u.viewportOriginX) / u.viewportWidth;
    const float viewY = (docY - u.viewportOriginY) / u.viewportHeight;

    // NDC: x in [-1, +1] right-positive, y in [-1, +1] up-positive.
    out.position = float4(
        viewX * 2.0 - 1.0,
        1.0 - viewY * 2.0,
        0.0,
        1.0
    );
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return tex.sample(s, in.texCoord);
}
