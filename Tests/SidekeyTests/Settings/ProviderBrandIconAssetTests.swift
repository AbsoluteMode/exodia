import XCTest
@testable import Sidekey

@MainActor
final class ProviderBrandIconAssetTests: XCTestCase {
    func testSettingsProviderBrandAssetsAreBundled() throws {
        let root = try projectRoot()
        let iconDir = root.appendingPathComponent("Resources/UsefulLinkIcons")
        let expectedNames = [
            "openai",
            "deepgram",
            "soniox",
            "elevenlabs",
            "codex",
            "claude-code",
            "openrouter",
        ]

        for name in expectedNames {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: iconDir.appendingPathComponent("\(name).svg").path
                ),
                "Missing \(name).svg"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: iconDir.appendingPathComponent("\(name).pdf").path
                ),
                "Missing \(name).pdf"
            )
        }
    }

    func testSonioxIconIsVectorNotEmbeddedBitmap() throws {
        let root = try projectRoot()
        let svgURL = root
            .appendingPathComponent("Resources/UsefulLinkIcons")
            .appendingPathComponent("soniox.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8)

        XCTAssertTrue(svg.contains("<path"))
        XCTAssertFalse(svg.contains("<image"))
        XCTAssertFalse(svg.contains("base64"))
    }

    func testSonioxIconUsesTightViewBoxSoMarkReadsAtRowSize() throws {
        let root = try projectRoot()
        let svgURL = root
            .appendingPathComponent("Resources/UsefulLinkIcons")
            .appendingPathComponent("soniox.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8)

        XCTAssertTrue(svg.contains("width=\"48\""))
        XCTAssertTrue(svg.contains("height=\"48\""))
        XCTAssertTrue(svg.contains("viewBox=\"8 6 32 36\""))
    }

    func testTranscriptionProviderBrandAssetsPrewarmIntoCache() throws {
        let iconDir = try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons")
        ProviderBrandIconAsset.setResourceDirectoryForTesting(iconDir)
        ProviderBrandIconAsset.clearCacheForTesting()
        defer {
            ProviderBrandIconAsset.clearCacheForTesting()
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        }

        let loadedCount = ProviderBrandIconAsset.prewarmTranscriptionProviderAssets()

        XCTAssertEqual(
            loadedCount,
            ProviderBrandIconAsset.transcriptionProviderAssetNames.count
                * ProviderBrandIconAsset.prewarmedPointSizes.count
        )
        for name in ProviderBrandIconAsset.transcriptionProviderAssetNames {
            XCTAssertTrue(ProviderBrandIconAsset.isSourceCachedForTesting(name))
            for pointSize in ProviderBrandIconAsset.prewarmedPointSizes {
                XCTAssertTrue(ProviderBrandIconAsset.isRenderedCachedForTesting(name, pointSize: pointSize))
            }
        }
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "ProviderBrandIconAssetTests", code: 1)
    }
}
