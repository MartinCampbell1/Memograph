import Combine
import Foundation

struct AudioHealthSnapshot: Equatable {
    var pendingJobs: Int = 0
    var runningJobs: Int = 0
    var failedJobs: Int = 0
    var pendingMicrophoneJobs: Int = 0
    var pendingSystemJobs: Int = 0
    var currentRunningSource: String?
    var currentRunningJob: String?
    var lastUploadSizeBytes: Int64?
    var lastTranscriptionLatencyMs: Int?
    var lastRetryCount: Int = 0
    var networkFailureCount: Int = 0
    var consecutiveCloudFailures: Int = 0
    var cloudTranscriptionDelayed: Bool = false
    var systemAudioThrottled: Bool = false
    var systemAudioThrottleReason: String?
    var lastError: String?
    var updatedAt: Date = .distantPast

    var statusLines: [String] {
        var lines: [String] = []
        lines.append("audio queue: \(pendingJobs) pending")
        if failedJobs > 0 {
            lines.append("failed jobs: \(failedJobs)")
        }

        if let source = currentRunningSource {
            lines.append("current job: \(source)")
        } else if runningJobs > 0 {
            lines.append("current job: running")
        }

        if cloudTranscriptionDelayed {
            lines.append("cloud transcription delayed")
        }

        if systemAudioThrottled {
            if let reason = systemAudioThrottleReason, !reason.isEmpty {
                lines.append("system audio throttled: \(reason)")
            } else {
                lines.append("system audio throttled")
            }
        }

        if let size = lastUploadSizeBytes {
            lines.append("last upload: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }

        if let latency = lastTranscriptionLatencyMs {
            lines.append("last latency: \(latency) ms")
        }

        if lastRetryCount > 0 {
            lines.append("last retry count: \(lastRetryCount)")
        }

        if networkFailureCount > 0 {
            lines.append("network failures: \(networkFailureCount)")
        }

        if let lastError, !lastError.isEmpty {
            lines.append("last error: \(lastError)")
        }

        return lines
    }
}

struct SystemAudioThrottleDecision: Equatable {
    let shouldThrottle: Bool
    let reason: String?
    let cooldown: TimeInterval

    static let allow = SystemAudioThrottleDecision(
        shouldThrottle: false,
        reason: nil,
        cooldown: 0
    )
}

final class AudioHealthMonitor: ObservableObject, @unchecked Sendable {
    static let shared = AudioHealthMonitor()

    @Published private(set) var snapshot = AudioHealthSnapshot()

    func publish(_ snapshot: AudioHealthSnapshot) {
        self.snapshot = snapshot
    }
}
