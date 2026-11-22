import Testing
import MouseContract
@testable import MouseServiceKit

@Test func dialMappingRunsBetweenCaptureAndRelease() {
    var capture = D100HCapture()
    #expect(capture.update(wanted: 9, readerAvailable: true) == [.capture(9)])
    #expect(!capture.accepts(9))
    #expect(capture.readerReported(session: 9, open: true) == [.configure(true, revision: 1)])
    #expect(!capture.accepts(9))
    #expect(capture.configurationFinished(revision: 1, success: true, time: 0).isEmpty)
    #expect(capture.accepts(9))
    #expect(capture.update(wanted: nil, readerAvailable: true) == [.configure(false, revision: 2)])
    #expect(!capture.accepts(9))
    #expect(capture.configurationFinished(revision: 2, success: true, time: 0) == [.release(restored: true)])
}

@Test func dialMappingCancelsAndIgnoresLateRepliesAfterOwnerChanges() {
    var capture = D100HCapture()
    _ = capture.update(wanted: 6, readerAvailable: true)
    _ = capture.readerReported(session: 6, open: true)
    #expect(capture.update(wanted: 7, readerAvailable: true) == [.configure(false, revision: 2)])
    #expect(capture.readerReported(session: 6, open: true).isEmpty)
    #expect(capture.readerReported(session: 7, open: true).isEmpty)
    #expect(capture.configurationFinished(revision: 1, success: true, time: 0).isEmpty)
    #expect(capture.configurationFinished(revision: 2, success: true, time: 0) == [.capture(7)])
    #expect(capture.readerReported(session: 7, open: true) == [.configure(true, revision: 3)])
    #expect(!capture.accepts(7))
    #expect(capture.configurationFinished(revision: 3, success: true, time: 0).isEmpty)
    #expect(capture.accepts(7))
    #expect(capture.update(wanted: 7, readerAvailable: false) == [.configure(false, revision: 4)])
    #expect(!capture.accepts(7))
}

@Test func dialMappingFailureRestoresBeforeReleasingAndWaitsForNewFocus() {
    var capture = D100HCapture()
    _ = capture.update(wanted: 4, readerAvailable: true)
    _ = capture.readerReported(session: 4, open: true)
    #expect(capture.configurationFinished(revision: 1, success: false, time: 0) == [.configure(false, revision: 2)])
    #expect(capture.configurationFinished(revision: 2, success: false, time: 0) == [.release(restored: false)])
    #expect(capture.update(wanted: 4, readerAvailable: true).isEmpty)
    #expect(capture.update(wanted: 5, readerAvailable: true) == [.capture(5)])
}

@Test func dialCaptureLostBeforeAcknowledgmentNeverWritesFirmware() {
    var capture = D100HCapture()
    #expect(capture.update(wanted: 4, readerAvailable: true) == [.capture(4)])
    #expect(capture.update(wanted: nil, readerAvailable: true) == [.release(restored: true)])
    #expect(capture.readerReported(session: 4, open: true).isEmpty)
}

@Test func dialDropsQueuedInputAndUnpairedReleasesAtActivation() {
    var capture = D100HCapture()
    _ = capture.update(wanted: 4, readerAvailable: true)
    _ = capture.readerReported(session: 4, open: true)
    _ = capture.configurationFinished(revision: 1, success: true, time: 10)

    let press = D100HInput.button(.topLeft, pressed: true)
    let release = D100HInput.button(.topLeft, pressed: false)
    #expect(capture.acceptsInput(press, session: 4, time: 9) == false)
    #expect(capture.acceptsInput(release, session: 4, time: 11) == false)
    #expect(capture.acceptsInput(press, session: 4, time: 12) == true)
    #expect(capture.acceptsInput(release, session: 4, time: 13) == true)
}
