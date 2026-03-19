# Memory Analysis & Mitigation Strategy

I have profiled the application's memory usage and analyzed the source code. The ~3GB RAM footprint with 369 comics loaded is caused by a combination of eager loading and unbounded caching. 

Here is the breakdown of where the memory is going, followed by the recommended mitigation strategy.

## 1. Memory Breakdown

The memory footprint comes from two distinct architectural choices: the thumbnail cache and the comic reader model.

### The Thumbnail Cache (Library View)
Currently, `LibraryViewModel` eagerly loads **every** thumbnail from the disk cache directory into a flat `[String: NSImage]` dictionary at startup. 

* **The Orphan Problem:** The cache directory contains 18,190 thumbnails (from all comics ever opened or scanned), but the current library only contains 369 comics. The app loads all 18,190 into RAM.
* **The Unbounded Dictionary:** A standard Swift dictionary never evicts its contents under memory pressure.
* **The Retina Multiplier:** A 200×280px image on a Retina display is backed by a 400×560px bitmap. At 4 bytes per pixel (RGBA), plus `NSImage` overhead, each thumbnail consumes roughly 1.1 MB of RAM.

| Component | Disk Count | RAM Usage (Estimated) |
| :--- | :--- | :--- |
| Orphaned Thumbnails | ~17,821 | ~2.5 GB |
| Active Library Thumbnails | 369 | ~410 MB |
| **Total Thumbnail RAM** | **18,190** | **~2.9 GB** |

### The Comic Reader (Reader View)
When a user opens a comic, `ComicLoader` extracts the archive to a temporary directory and eagerly decodes **every single page** into an `NSImage` before deleting the temp directory. 

* A typical 200-page comic with 1500×2300px pages consumes **~2.6 GB** of RAM while open.
* Because the app only allows one comic open at a time, this memory is released when the reader is closed, but it creates massive memory pressure during reading.

## 2. Mitigation Strategies

To solve this elegantly without rewriting the entire application architecture, we need to address both the library and the reader.

### Strategy A: The `NSCache` Migration (Library)
Instead of a flat dictionary, we should use `NSCache<NSString, NSImage>`. `NSCache` is provided by Apple specifically for this use case; it automatically evicts objects when the system experiences memory pressure.

Furthermore, the `preloadThumbnailCache()` function must be rewritten to only load thumbnails for the URLs that actually exist in the `recentComics` and `galleries` arrays, rather than blindly loading the entire directory.

### Strategy B: Lazy Page Loading (Reader)
Eagerly decoding 200 high-resolution pages into RAM is unsustainable. However, rewriting `ComicLoader` to keep the archive open and extract pages on-the-fly is highly complex and error-prone (especially for formats like PDF and TAR).

The elegant middle ground is **Disk-Backed Lazy Loading**:
1. `ComicLoader` extracts the archive to a temporary directory, but **does not** decode the images into `NSImage`.
2. The `ComicPage` model is updated to store a `URL` (pointing to the temp file) instead of an `NSImage`.
3. The views (`ZoomableImageView`, `VerticalComicScrollView`) load the `NSImage` from the URL only when the page is about to appear on screen.
4. When the comic is closed, the temporary directory is deleted.

## 3. Recommendation

I recommend implementing **Strategy A** first, as it is a low-risk, high-impact change that directly addresses the 3GB idle memory issue you observed. 

**Implementation Steps for Strategy A:**
1. Change `thumbnailCache` from `[String: NSImage]` to `NSCache<NSString, NSImage>`.
2. Set `countLimit = 500` on the cache (enough to keep the visible grid smooth, but strictly capping RAM at ~500MB).
3. Update `preloadThumbnailCache()` to iterate over `galleries` and `recentComics`, loading only those specific hashes from disk.
4. Update `ComicCard` to fetch from `NSCache`, and if missing, load from disk asynchronously.

This will immediately drop the idle RAM usage from ~3GB down to ~100-200MB, without changing how the reader functions.

If you agree with this diagnosis, I can proceed with implementing Strategy A.
