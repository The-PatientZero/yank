import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YankCore

@Suite struct PNGDownsamplerTests {
    @Test func shrinksTheLongestEdgeToTheLimit() throws {
        let source = try Self.pngData(width: 400, height: 100)

        let png = try #require(PNGDownsampler.png(from: source, maxPixel: 200))

        let size = try Self.pixelSize(of: png)
        #expect(size.width == 200)
        #expect(size.height == 50)
    }

    @Test func keepsASmallImageAtItsSize() throws {
        let source = try Self.pngData(width: 30, height: 20)

        let png = try #require(PNGDownsampler.png(from: source, maxPixel: 200))

        let size = try Self.pixelSize(of: png)
        #expect(size.width == 30)
        #expect(size.height == 20)
    }

    @Test func readsFromAFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PNGDownsamplerTests-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.pngData(width: 64, height: 64).write(to: url)

        let png = try #require(PNGDownsampler.png(fromFileAt: url, maxPixel: 32))

        #expect(try Self.pixelSize(of: png).width == 32)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(PNGDownsampler.png(from: Data("not an image".utf8), maxPixel: 200) == nil)
        #expect(PNGDownsampler.png(from: Data(), maxPixel: 200) == nil)
    }

    @Test func rejectsAURLThatIsNotAFile() throws {
        let url = try #require(URL(string: "https://example.com/image.png"))
        #expect(PNGDownsampler.png(fromFileAt: url, maxPixel: 200) == nil)
    }

    private struct TestImageError: Error {}

    static func pngData(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError() }
        context.setFillColor(CGColor(red: 1, green: 0.75, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestImageError() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw TestImageError() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestImageError() }
        return data as Data
    }

    private static func pixelSize(of png: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TestImageError() }
        return (image.width, image.height)
    }
}
