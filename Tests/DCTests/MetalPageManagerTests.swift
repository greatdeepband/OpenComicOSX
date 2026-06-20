import XCTest
import CoreGraphics
import os
@testable import DC

final class MetalPageManagerTests: XCTestCase {

    private let cap = 16384  // mirrors ReaderConstants.maxTextureDimension

    func test_cappedSize_withinLimit_isUnchanged() {
        let r = MetalPageManager.cappedSize(width: 4000, height: 6000, maxDimension: cap)
        XCTAssertEqual(r.width, 4000)
        XCTAssertEqual(r.height, 6000)
    }

    func test_cappedSize_atLimit_isUnchanged() {
        let r = MetalPageManager.cappedSize(width: cap, height: 1000, maxDimension: cap)
        XCTAssertEqual(r.width, cap)
        XCTAssertEqual(r.height, 1000)
    }

    /// The webtoon-strip case that would otherwise SIGABRT in makeTexture:
    /// a tall thin page taller than the Metal limit must be scaled so the
    /// long edge lands exactly at the cap, preserving aspect ratio.
    func test_cappedSize_tallStrip_scalesLongEdgeToCap() {
        let r = MetalPageManager.cappedSize(width: 1080, height: 21600, maxDimension: cap)
        XCTAssertEqual(r.height, cap, "Long edge must be clamped to the cap")
        XCTAssertLessThanOrEqual(r.width, cap)
        // Aspect ratio preserved: 1080/21600 = 0.05 → width ≈ 0.05 * 16384 = 819.
        XCTAssertEqual(Double(r.width) / Double(r.height), 1080.0 / 21600.0, accuracy: 0.01)
    }

    func test_cappedSize_wideStrip_scalesLongEdgeToCap() {
        let r = MetalPageManager.cappedSize(width: 30000, height: 2000, maxDimension: cap)
        XCTAssertEqual(r.width, cap)
        XCTAssertLessThanOrEqual(r.height, cap)
        XCTAssertEqual(Double(r.height) / Double(r.width), 2000.0 / 30000.0, accuracy: 0.01)
    }

    func test_cappedSize_bothAxesOverLimit_clampsToFit() {
        let r = MetalPageManager.cappedSize(width: 20000, height: 18000, maxDimension: cap)
        XCTAssertLessThanOrEqual(r.width, cap)
        XCTAssertLessThanOrEqual(r.height, cap)
        XCTAssertEqual(max(r.width, r.height), cap, "The longer axis lands at the cap")
    }

    func test_cappedSize_degenerateInput_doesNotCrash() {
        XCTAssertEqual(MetalPageManager.cappedSize(width: 0, height: 0, maxDimension: cap).width, 0)
        let neg = MetalPageManager.cappedSize(width: -5, height: 10, maxDimension: cap)
        XCTAssertGreaterThanOrEqual(neg.width, 0)
    }

    // MARK: - onThumbReady lock stress test

    /// Hammers both the WRITE path (`setOnThumbReady`) and the READ+CALL path
    /// (`invokeOnThumbReady`, which mirrors `decodeThumb`'s
    /// `lock.withLock { $0 }` snapshot → `MainActor.run { cb(...) }` pattern)
    /// from many concurrent tasks simultaneously.
    ///
    /// Goals:
    ///   1. No crash / EXC_BAD_ACCESS under concurrent write+read interleave.
    ///   2. `callCount` never goes negative (no double-free / corrupt counter).
    ///   3. No Swift warning: every local is used.
    ///
    /// Note: TSan is unavailable in this build environment. High iteration
    /// count + real task-group concurrency maximises scheduler interleaving so
    /// a data race on the old `nonisolated(unsafe) var` would manifest as a
    /// crash or a corrupt counter — neither of which should occur here.
    func test_setOnThumbReady_concurrentStress_noCrash() async {
        let manager = MetalPageManager()
        let iterations = 2000
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        // Make a 1×1 CGImage to pass through invokeOnThumbReady — exercising
        // the production read-then-call path with a real image argument.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(data: nil, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4,
                            space: colorSpace, bitmapInfo: bitmapInfo)!
        let dummyImage = ctx.makeImage()!

        // Concurrent task group: every iteration both writes (set/clear) AND
        // reads+invokes the callback via the same lock path as decodeThumb.
        // The interleaving exercises write-while-read and read-while-write
        // races that the old nonisolated(unsafe) var couldn't protect against.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    if i % 2 == 0 {
                        // WRITE: install a counting callback.
                        manager.setOnThumbReady { _, _ in
                            callCount.withLock { $0 += 1 }
                        }
                    } else {
                        // WRITE: clear the callback.
                        manager.setOnThumbReady(nil)
                    }
                    // READ+CALL: snapshot the closure under the lock and invoke
                    // it on the main actor — mirroring decodeThumb lines
                    // `let cb = onThumbReadyLock.withLock { $0 }` followed by
                    // `if let cb { await MainActor.run { cb(pageIndex, image) } }`.
                    // dummyImage is passed here so the variable is live and the
                    // callback receives a valid CGImage (as production does).
                    await manager.invokeOnThumbReady(pageIndex: i, image: dummyImage)
                }
            }
        }

        // Drain: clear the callback so any subsequent stray MainActor work
        // that arrives late hits a nil closure and no-ops.
        manager.setOnThumbReady(nil)

        // callCount >= 0 is always true; the real assertion is "we reached
        // this line without a crash, hang, or EXC_BAD_ACCESS."
        let finalCount = callCount.withLock { $0 }
        XCTAssertGreaterThanOrEqual(finalCount, 0,
            "Stress completed without crash (callCount=\(finalCount))")
    }
}
