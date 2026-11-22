import Testing
@testable import MouseServiceKit

@Test func dialMappingRunsBetweenCaptureAndRelease() {
    var capture = D100HCapture()
    #expect(capture.update(wanted: 9, readerAvailable: true) == [.capture(9)])
    #expect(!capture.accepts(9))
    #expect(capture.readerReported(session: 9, open: true) == [.configure(true, revision: 1)])
    #expect(!capture.accepts(9))
    #expect(capture.configurationFinished(revision: 1, success: true).isEmpty)
    #expect(capture.accepts(9))
    #expect(capture.update(wanted: nil, readerAvailable: true) == [.configure(false, revision: 2)])
    #expect(!capture.accepts(9))
    #expect(capture.configurationFinished(revision: 2, success: true) == [.release(restored: true)])
}

@Test func dialMappingCancelsAndIgnoresLateRepliesAfterOwnerChanges() {
    var capture = D100HCapture()
    _ = capture.update(wanted: 6, readerAvailable: true)
    _ = capture.readerReported(session: 6, open: true)
    #expect(capture.update(wanted: 7, readerAvailable: true) == [.configure(false, revision: 2)])
    #expect(capture.readerReported(session: 6, open: true).isEmpty)
    #expect(capture.readerReported(session: 7, open: true).isEmpty)
    #expect(capture.configurationFinished(revision: 1, success: true).isEmpty)
    #expect(capture.configurationFinished(revision: 2, success: true) == [.capture(7)])
    #expect(capture.readerReported(session: 7, open: true) == [.configure(true, revision: 3)])
    #expect(!capture.accepts(7))
    #expect(capture.configurationFinished(revision: 3, success: true).isEmpty)
    #expect(capture.accepts(7))
    #expect(capture.update(wanted: 7, readerAvailable: false) == [.configure(false, revision: 4)])
    #expect(!capture.accepts(7))
}

@Test func dialMappingFailureRestoresBeforeReleasingAndWaitsForNewFocus() {
    var capture = D100HCapture()
    _ = capture.update(wanted: 4, readerAvailable: true)
    _ = capture.readerReported(session: 4, open: true)
    #expect(capture.configurationFinished(revision: 1, success: false) == [.configure(false, revision: 2)])
    #expect(capture.configurationFinished(revision: 2, success: false) == [.release(restored: false)])
    #expect(capture.update(wanted: 4, readerAvailable: true).isEmpty)
    #expect(capture.update(wanted: 5, readerAvailable: true) == [.capture(5)])
}

@Test func dialCaptureLostBeforeAcknowledgmentNeverWritesFirmware() {
    var capture = D100HCapture()
    #expect(capture.update(wanted: 4, readerAvailable: true) == [.capture(4)])
    #expect(capture.update(wanted: nil, readerAvailable: true) == [.release(restored: true)])
    #expect(capture.readerReported(session: 4, open: true).isEmpty)
}
