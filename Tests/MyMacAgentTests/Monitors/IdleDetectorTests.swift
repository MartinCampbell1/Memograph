import Testing
@testable import MyMacAgent

final class MockIdleDelegate: IdleDetectorDelegate {
    var lastIsIdle: Bool?
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool) {
        lastIsIdle = isIdle
    }
}

struct IdleDetectorTests {
    @Test("Default idle threshold is 120 seconds")
    func defaultThreshold() {
        let detector = IdleDetector()
        #expect(detector.idleThreshold == 120)
    }

    @Test("Custom idle threshold")
    func customThreshold() {
        let detector = IdleDetector(idleThreshold: 60)
        #expect(detector.idleThreshold == 60)
    }

    @Test("Current idle time is non-negative")
    func idleTimeNonNegative() {
        let detector = IdleDetector()
        #expect(detector.currentIdleTime >= 0)
    }

    @Test("isIdle returns false for active user with high threshold")
    func notIdleWithHighThreshold() {
        let detector = IdleDetector(idleThreshold: 999999)
        #expect(!detector.isIdle)
    }

    @Test("Delegate interface compiles")
    func delegateInterface() {
        let delegate = MockIdleDelegate()
        let detector = IdleDetector(idleThreshold: 0)
        detector.delegate = delegate
        #expect(delegate.lastIsIdle == nil)
    }
}
