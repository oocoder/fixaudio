import XCTest
@testable import MeetingRecorder

final class RecordingMenuStateTests: XCTestCase {
    func testRecordingShowsStopAndDisablesTranscription() {
        let state = RecordingMenuState.make(
            isRecording: true,
            isFinishing: false,
            isTranscribing: false,
            micAvailable: true,
            sourceExists: true
        )

        XCTAssertEqual(state.recordTitle, "Stop and Save Recording")
        XCTAssertTrue(state.recordEnabled)
        XCTAssertFalse(state.transcribeLastEnabled)
        XCTAssertFalse(state.transcribeAnyEnabled)
    }

    func testFinishingShowsProgressStateAndDisablesActions() {
        let state = RecordingMenuState.make(
            isRecording: false,
            isFinishing: true,
            isTranscribing: false,
            micAvailable: true,
            sourceExists: true
        )

        XCTAssertEqual(state.recordTitle, "Finishing M4A…")
        XCTAssertFalse(state.recordEnabled)
        XCTAssertFalse(state.transcribeLastEnabled)
        XCTAssertFalse(state.transcribeAnyEnabled)
    }

    func testFinishedRecordingEnablesLastRecordingTranscription() {
        let state = RecordingMenuState.make(
            isRecording: false,
            isFinishing: false,
            isTranscribing: false,
            micAvailable: true,
            sourceExists: true
        )

        XCTAssertEqual(state.recordTitle, "Start Meeting Recording…")
        XCTAssertTrue(state.recordEnabled)
        XCTAssertTrue(state.transcribeLastEnabled)
        XCTAssertTrue(state.transcribeAnyEnabled)
    }

    func testIdleWithoutMicrophoneStillAllowsAnyFileTranscription() {
        let state = RecordingMenuState.make(
            isRecording: false,
            isFinishing: false,
            isTranscribing: false,
            micAvailable: false,
            sourceExists: false
        )

        XCTAssertFalse(state.recordEnabled)
        XCTAssertFalse(state.transcribeLastEnabled)
        XCTAssertTrue(state.transcribeAnyEnabled)
    }

    func testTranscribingDisablesAllActions() {
        let state = RecordingMenuState.make(
            isRecording: false,
            isFinishing: false,
            isTranscribing: true,
            micAvailable: true,
            sourceExists: true
        )

        XCTAssertFalse(state.recordEnabled)
        XCTAssertFalse(state.transcribeLastEnabled)
        XCTAssertFalse(state.transcribeAnyEnabled)
    }
}
