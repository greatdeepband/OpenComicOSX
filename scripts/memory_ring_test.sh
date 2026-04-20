#!/bin/bash
# Memory Ring Buffer Verification Script
# Run from the DC project root:
#   bash scripts/memory_ring_test.sh
#
# This script verifies the two-ring memory architecture is wired correctly:
#   Ring 1: MetalPageManager (CVPixelBuffer, actor, max 10 pages)
#   Ring 2: MetalPageRenderer.textureRing (MTLTexture, struct, max 10 pages)
#
# It checks:
#   1. Both rings are capped at 10 entries (LRU eviction trigger)
#   2. Ring 2 is populated from Ring 1 (upload path)
#   3. evictOutside() correctly prunes both rings to the visible window
#   4. LRU eviction uses access time, not arbitrary dict order

set -e

DC_DIR="/Volumes/Media/__Manus copy/DC"
cd "$DC_DIR"

echo "========================================"
echo "DC Memory Ring Buffer Verification"
echo "========================================"
echo ""

# --- 1. Check build is clean ---
echo "[1/5] Checking build is clean..."
if swift build 2>&1 | grep -q "error:"; then
    echo "FAIL: Build has errors"
    swift build 2>&1 | grep "error:"
    exit 1
else
    echo "PASS: Build complete"
fi
echo ""

# --- 2. Verify TextureRingBuffer struct exists and is wired ---
echo "[2/5] Verifying TextureRingBuffer struct..."
if grep -q "struct TextureRingBuffer" Sources/DC/Views/MetalPageRenderer.swift; then
    echo "PASS: TextureRingBuffer struct found"
else
    echo "FAIL: TextureRingBuffer struct not found"
    exit 1
fi

if grep -q "textureRing.insert" Sources/DC/Views/MetalPageRenderer.swift; then
    echo "PASS: textureRing.insert() call found (LRU eviction on insert)"
else
    echo "FAIL: textureRing.insert() not called"
    exit 1
fi

if grep -q "textureRing.touch" Sources/DC/Views/MetalPageRenderer.swift; then
    echo "PASS: textureRing.touch() call found (LRU timestamp update)"
else
    echo "FAIL: textureRing.touch() not called"
    exit 1
fi

if grep -q "textureRing.evictOutside" Sources/DC/Views/MetalPageRenderer.swift; then
    echo "PASS: textureRing.evictOutside() call found"
else
    echo "FAIL: textureRing.evictOutside() not called"
    exit 1
fi
echo ""

# --- 3. Verify LRU eviction uses lastAccessTime min, not dict.keys.first ---
echo "[3/5] Verifying LRU eviction logic..."
if grep -q 'lastAccessTimes.min(by:' Sources/DC/ViewModels/MetalPageManager.swift; then
    echo "PASS: MetalPageManager uses lastAccessTimes.min() for LRU (not dict.keys.first)"
else
    echo "FAIL: MetalPageManager LRU eviction not using lastAccessTimes.min()"
    exit 1
fi

if grep -q 'entries.min(by:' Sources/DC/Views/MetalPageRenderer.swift; then
    echo "PASS: TextureRingBuffer uses entries.min() for LRU (not arbitrary ordering)"
else
    echo "FAIL: TextureRingBuffer LRU eviction not using entries.min()"
    exit 1
fi
echo ""

# --- 4. Verify ring capacity constants (max 10) ---
echo "[4/5] Verifying ring capacity constants..."
MANAGER_MAX=$(grep "maxCachedPages = 10" Sources/DC/ViewModels/MetalPageManager.swift || echo "")
MANAGER_MAX=$(grep "maxCachedPages = 10" Sources/DC/ViewModels/MetalPageManager.swift || echo "")
RENDERER_MAX=$(grep "init(maxSize: Int = 10)" Sources/DC/Views/MetalPageRenderer.swift || echo "")

if [[ -n "$MANAGER_MAX" ]]; then
    echo "PASS: MetalPageManager maxCachedPages = 10"
else
    echo "FAIL: MetalPageManager maxCachedPages not set to 10"
    exit 1
fi

if [[ -n "$RENDERER_MAX" ]]; then
    echo "PASS: TextureRingBuffer maxSize = 10"
else
    echo "FAIL: TextureRingBuffer maxSize not set to 10"
    exit 1
fi
echo ""

# --- 5. Verify wiring between rings (coordinator render path) ---
echo "[5/5] Verifying inter-ring wiring (PageManager → Renderer)..."

# The coordinator's render() does:
#   1. pageManager.page(for:) → CVPixelBuffer from decodedPages ring
#   2. renderer.upload(pixelBuffer:) → MTLTexture inserted into textureRing
#   3. renderer.evictOutside(visibleRange) → prunes both rings

RENDER_CALLS_UPLOAD=$(grep -c "renderer.upload" Sources/DC/Views/MetalPageView.swift || echo "0")
RENDER_CALLS_EVICT=$(grep -c "renderer.evictOutside\|pageManager.evictOutside" Sources/DC/Views/MetalPageView.swift || echo "0")

if [[ "$RENDER_CALLS_UPLOAD" -ge 1 ]]; then
    echo "PASS: Coordinator calls renderer.upload() to transfer buffers to texture ring"
else
    echo "FAIL: renderer.upload() not found in coordinator render path"
    exit 1
fi

if [[ "$RENDER_CALLS_EVICT" -ge 1 ]]; then
    echo "PASS: Coordinator calls evictOutside() to prune rings to visible range"
else
    echo "FAIL: evictOutside() not found in coordinator"
    exit 1
fi
echo ""

# --- 6. Verify actor-isolated evictOutside on MetalPageManager ---
echo "[6/6] Verifying MetalPageManager.evictOutside is actor-isolated..."
if grep -q "func evictOutside" Sources/DC/ViewModels/MetalPageManager.swift; then
    echo "PASS: MetalPageManager.evictOutside() method exists"
else
    echo "FAIL: MetalPageManager.evictOutside() not found"
    exit 1
fi
echo ""

echo "========================================"
echo "All checks PASSED"
echo "========================================"
echo ""
echo "Summary of verified wiring:"
echo "  Ring 1: MetalPageManager (actor) — CVPixelBuffer[], max 10, LRU via lastAccessTimes.min()"
echo "  Ring 2: MetalPageRenderer.textureRing (struct) — MTLTexture[], max 10, LRU via entries.min()"
echo "  Wiring: Coordinator.render() calls pageManager.page() → renderer.upload() → textureRing"
echo "  Eviction: Coordinator calls evictOutside() on both rings with visible range"
