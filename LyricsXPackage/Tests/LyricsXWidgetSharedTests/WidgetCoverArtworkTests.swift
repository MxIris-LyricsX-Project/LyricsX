import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import LyricsXWidgetShared

// The app writes the widget's snapshot on every lyric line. It used to resize
// and re-encode the cover each time, through `NSImage.lockFocus`, whose
// extended-range bitmap sent ImageIO's JPEG encoder through its Metal HDR
// converter: on a Mac Studio M3 Ultra each line put about 300 MB of GPU
// memory to work (19 blocks of 16 MiB), which the process then held for
// seconds — measured with `footprint` on 1.9.1 on 2026-11-15.

@Suite("Widget cover artwork")
struct WidgetCoverArtworkTests {
    @Test("a snapshot written again for the same track reuses the cover prepared first")
    func sameTrackReusesItsCover() throws {
        var cache = WidgetCoverArtworkCache()
        let first = try #require(cache.artwork(for: try solidImage(red: 200, green: 40, blue: 40), trackIdentifier: "track-a"))
        let second = try #require(cache.artwork(for: try solidImage(red: 40, green: 40, blue: 200), trackIdentifier: "track-a"))

        #expect(second == first)
    }

    @Test("another track gets a cover of its own")
    func anotherTrackPreparesItsOwnCover() throws {
        var cache = WidgetCoverArtworkCache()
        _ = cache.artwork(for: try solidImage(red: 200, green: 40, blue: 40), trackIdentifier: "track-a")
        let cover = try #require(cache.artwork(for: try solidImage(red: 40, green: 40, blue: 200), trackIdentifier: "track-b"))
        let color = try #require(cover.backgroundColor)

        #expect(color.blue > color.red)
    }

    @Test("artwork of another size for the same track replaces the cover")
    func largerArtworkForTheSameTrackReplacesTheCover() throws {
        var cache = WidgetCoverArtworkCache()
        _ = cache.artwork(for: try solidImage(red: 200, green: 40, blue: 40, width: 300, height: 300), trackIdentifier: "track-a")
        let cover = try #require(cache.artwork(for: try solidImage(red: 40, green: 40, blue: 200, width: 1200, height: 1200), trackIdentifier: "track-a"))
        let color = try #require(cover.backgroundColor)

        #expect(color.blue > color.red)
    }

    @Test("the cover is a JPEG whose longest side is 400 pixels")
    func coverIsFourHundredPixelsOnItsLongestSide() throws {
        let cover = try #require(WidgetCoverArtwork(artwork: try solidImage(red: 90, green: 120, blue: 150, width: 1200, height: 900)))
        let source = try #require(CGImageSourceCreateWithData(cover.jpegData as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        #expect(decoded.width == 400)
        #expect(decoded.height == 300)
    }

    @Test("artwork smaller than the cover is not scaled up")
    func smallArtworkKeepsItsSize() throws {
        let cover = try #require(WidgetCoverArtwork(artwork: try solidImage(red: 90, green: 120, blue: 150, width: 120, height: 120)))
        let source = try #require(CGImageSourceCreateWithData(cover.jpegData as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(decoded.width == 120)
        #expect(decoded.height == 120)
    }

    @Test("the background is the cover's colour at 60 percent")
    func backgroundIsTheDarkenedCoverColor() throws {
        let cover = try #require(WidgetCoverArtwork(artwork: try solidImage(red: 200, green: 100, blue: 50)))
        let color = try #require(cover.backgroundColor)

        // 200, 100 and 50 out of 255, times 0.6.
        #expect(abs(color.red - 0.4706) < 0.01)
        #expect(abs(color.green - 0.2353) < 0.01)
        #expect(abs(color.blue - 0.1176) < 0.01)
        #expect(color.alpha == 1)
    }
}

@Suite("Widget cover encoding probes", .serialized)
struct WidgetCoverEncodingProbes {
    @Test("preparing a cover leaves the process's GPU memory where it was")
    func preparingACoverUsesNoGPUMemory() throws {
        // A cover the size Music and NetEase hand over.
        let artwork = try solidImage(red: 30, green: 160, blue: 90, width: 1400, height: 1400)
        let graphicsBefore = try #require(graphicsFootprint())
        _ = try #require(WidgetCoverArtwork(artwork: artwork))
        let graphicsAfter = try #require(graphicsFootprint())

        let growth = graphicsAfter - graphicsBefore
        #expect(
            growth < 16 << 20,
            "GPU memory grew by \(growth >> 20) MiB while preparing one cover"
        )
    }

    /// The task's graphics ledger: GPU memory it owns, mapped or not — the
    /// "Owned physical footprint (unmapped) (graphics)" row of `footprint`.
    private func graphicsFootprint() -> Int64? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { informationPointer in
            informationPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), integerPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return information.ledger_tag_graphics_footprint
    }
}

/// An opaque sRGB image of one colour, like a decoded cover.
private func solidImage(red: UInt8, green: UInt8, blue: UInt8, width: Int = 600, height: Int = 600) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let color = try #require(CGColor(
        colorSpace: colorSpace,
        components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1]
    ))
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
