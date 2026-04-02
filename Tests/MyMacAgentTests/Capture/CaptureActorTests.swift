import Testing
import Foundation
@testable import MyMacAgent

struct CaptureActorTests {
    @Test("Tracks in-flight count")
    func tracksInFlight() async {
        let limiter = CaptureGate(maxConcurrent: 2)
        #expect(await limiter.inFlightCount == 0)
        let acquired = await limiter.tryAcquire()
        #expect(acquired)
        #expect(await limiter.inFlightCount == 1)
        await limiter.release()
        #expect(await limiter.inFlightCount == 0)
    }

    @Test("Rejects when at max concurrency")
    func rejectsAtMax() async {
        let limiter = CaptureGate(maxConcurrent: 1)
        let first = await limiter.tryAcquire()
        #expect(first)
        let second = await limiter.tryAcquire()
        #expect(!second)
        await limiter.release()
        let third = await limiter.tryAcquire()
        #expect(third)
    }

    @Test("Backlog counter increments on rejection")
    func backlogCounter() async {
        let limiter = CaptureGate(maxConcurrent: 1)
        _ = await limiter.tryAcquire()
        _ = await limiter.tryAcquire()
        _ = await limiter.tryAcquire()
        #expect(await limiter.rejectedCount == 2)
    }
}
