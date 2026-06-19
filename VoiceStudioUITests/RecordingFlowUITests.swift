import XCTest

/// End-to-end flows for the v2 project-library + multi-track editor.
/// Launches with UITEST_RESET so the library starts empty and deterministic.
/// Microphone permission is pre-granted via `simctl privacy` in the test run.
final class RecordingFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_RESET"]
        app.launch()
        return app
    }

    /// From the (empty) library, create a project and land in the editor.
    private func createProject(_ app: XCUIApplication) {
        let newProject = app.buttons["New Project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 5), "New Project button missing")
        newProject.tap()
        // A name prompt appears; confirm with Create.
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "New Project name prompt missing")
        create.tap()
        XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 5), "Editor (Record button) didn't open")
    }

    /// In the editor, record a short take and approve it onto a track.
    private func recordAndApprove(_ app: XCUIApplication) {
        app.buttons["Record"].tap()
        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Record screen didn't open")
        start.tap()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Recording didn't start (engine crash?)")
        sleep(2)
        stop.tap()
        let approve = app.buttons["Approve & Add to Track"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5), "Approve control missing after stop")
        approve.tap()
    }

    func testCreateRecordApprove() {
        let app = launchApp()
        createProject(app)
        recordAndApprove(app)
        // Back in the editor without crashing; the take clip exists.
        XCTAssertTrue(app.staticTexts["Take"].waitForExistence(timeout: 5),
                      "Approved take did not appear on the timeline")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testPlayAfterApprove() {
        let app = launchApp()
        createProject(app)
        recordAndApprove(app)
        XCTAssertTrue(app.staticTexts["Take"].waitForExistence(timeout: 5))
        // The editor play button should start playback (flips Play → Pause).
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Play button missing")
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 4),
                      "Playback did not start after adding a recording to the track")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testRecordWithMonitoringDoesNotCrash() {
        let app = launchApp()
        createProject(app)
        app.buttons["Record"].tap()
        let monitor = app.switches.firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        if (monitor.value as? String) == "0" { monitor.tap() }
        app.buttons["Start recording"].tap()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Monitored recording didn't start (crash?)")
        sleep(2)
        stop.tap()
        XCTAssertTrue(app.buttons["Approve & Add to Track"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testClipInspectorSoloListen() {
        let app = launchApp()
        createProject(app)
        recordAndApprove(app)

        let take = app.staticTexts["Take"]
        XCTAssertTrue(take.waitForExistence(timeout: 5))
        take.tap()                                   // select the clip
        // Open the per-clip inspector via the bottom Effects tool.
        let effects = app.buttons["Effects"]
        XCTAssertTrue(effects.waitForExistence(timeout: 5), "Effects tool missing")
        effects.tap()

        // Enable per-clip effects and solo-listen.
        let fx = app.switches.firstMatch
        XCTAssertTrue(fx.waitForExistence(timeout: 5))
        if (fx.value as? String) == "0" { fx.tap() }
        let listen = app.buttons["Listen (solo)"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5), "Solo listen missing")
        listen.tap()
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testCreateAndDeleteProject() {
        let app = launchApp()
        createProject(app)
        // Go back to the library.
        app.navigationBars.buttons.firstMatch.tap()
        // A project card exists; long-press → delete.
        let card = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Project card missing in library")
        card.press(forDuration: 1.1)
        let del = app.buttons["Delete Project"]
        XCTAssertTrue(del.waitForExistence(timeout: 5), "Delete action missing")
        del.tap()
        // Library returns to empty state.
        XCTAssertTrue(app.buttons["New Project"].waitForExistence(timeout: 5),
                      "Library should be empty after delete")
    }
}
