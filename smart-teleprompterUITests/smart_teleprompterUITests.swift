import XCTest
import UIKit

@MainActor
final class smart_teleprompterUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["UITEST_STORE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.cells.staticTexts["Newest"].waitForExistence(timeout: 10))
    }

    func testNotionImportIsAvailableAndLegalLinksAreVisible() {
        app.buttons["Add Script"].tap()
        app.buttons["Import from Notion…"].tap()
        XCTAssertTrue(app.buttons["Connect to Notion"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Privacy Policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Terms of Service"].exists)
    }

    func testCreationOrderDoesNotChangeWhenEditing() {
        assertOrder(["Newest", "Middle", "Oldest"])
        app.cells.staticTexts["Oldest"].tap()
        let title = app.textFields["Optional title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(" edited")
        returnToLibrary()
        assertOrder(["Newest", "Middle", "Oldest edited"])
    }

    func testManualOrderSurvivesRelaunch() {
        app.buttons["Edit"].tap()
        let handle = app.cells.containing(.staticText, identifier: "Oldest").buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), app.debugDescription)
        let destination = app.cells.staticTexts["Newest"]
        handle.press(forDuration: 0.5, thenDragTo: destination)
        app.buttons["Done"].tap()
        assertOrder(["Oldest", "Newest", "Middle"])
        app.terminate()
        app.launch()
        assertOrder(["Oldest", "Newest", "Middle"])
        // New scripts appear at the top without disturbing the saved order.
        app.buttons["Add Script"].tap()
        app.buttons["New Script"].tap()
        XCTAssertTrue(app.textFields["Optional title"].waitForExistence(timeout: 5))
        returnToLibrary()
        assertOrder(["Untitled Script", "Oldest", "Newest", "Middle"])
    }

    func testMirrorModesPreserveWhiteText() throws {
        app.cells.staticTexts["Newest"].tap()
        app.buttons["Present"].tap()
        let word = app.staticTexts["Every"]
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        let baseline = try whitePixels(in: word)
        XCTAssertGreaterThan(baseline, 100)
        for (button, name) in [("Mirror top–bottom", "vertical"),
                               ("Mirror left–right", "both"),
                               ("Mirror top–bottom", "horizontal"),
                               ("Mirror left–right", "normal")] {
            revealControls()
            app.buttons[button].tap()
            // Poll actual rendered pixels so animation settling does not cause flakes.
            let bright = NSPredicate { [self] _, _ in
                (try? whitePixels(in: word)) ?? 0 > Int(Double(baseline) * 0.7)
            }
            expectation(for: bright, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Mirror contrast - \(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    private func returnToLibrary() {
        if !app.cells.staticTexts["Newest"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    private func revealControls() {
        if !app.buttons["Mirror top–bottom"].isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
    }

    private func assertOrder(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) {
        for title in titles {
            XCTAssertTrue(app.cells.staticTexts[title].waitForExistence(timeout: 5), file: file, line: line)
        }
        let positions = titles.map { app.cells.staticTexts[$0].frame.minY }
        XCTAssertEqual(positions, positions.sorted(), file: file, line: line)
        XCTAssertEqual(Set(positions).count, positions.count, file: file, line: line)
    }

    /// Measure the rendered glyph, not an accessibility color or a model flag.
    private func whitePixels(in element: XCUIElement) throws -> Int {
        // XCTest crops in screen coordinates, including landscape and mirrors.
        let crop = try XCTUnwrap(element.screenshot().image.cgImage)
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 220 && pixels[$0 + 1] > 220 && pixels[$0 + 2] > 220
        }.count
    }
}
