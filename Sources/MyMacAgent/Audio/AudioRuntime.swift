import AppKit
import CoreAudio
import Foundation

struct AudioCloudRuntimeEnvironment {
    let baseURL: String
    let apiKey: String
    let microphoneModel: String
    let systemAudioModel: String
}

struct AudioRuntimeEnvironment {
    let executableURL: URL
    let launchArgumentsPrefix: [String]
    let scriptPath: String
    let modelName: String
}

enum AudioRuntimeStatus {
    case cloudReady(AudioCloudRuntimeEnvironment)
    case ready(AudioRuntimeEnvironment)
    case missingAPIKey(String)
    case missingPython(String)
    case missingScript(String)

    var description: String {
        switch self {
        case .cloudReady(let env):
            return "Готово (облако: mic \(env.microphoneModel), system \(env.systemAudioModel))"
        case .ready(let env):
            let command = env.launchArgumentsPrefix.first ?? env.executableURL.lastPathComponent
            return "Готово (локально: \(command))"
        case .missingAPIKey(let details):
            return "Нет API-ключа для аудио: \(details)"
        case .missingPython(let details):
            return "Не найден Python runtime: \(details)"
        case .missingScript(let details):
            return "Не найден whisper helper: \(details)"
        }
    }

    var canTranscribe: Bool {
        switch self {
        case .cloudReady, .ready:
            return true
        case .missingAPIKey, .missingPython, .missingScript:
            return false
        }
    }
}

enum AudioRuntimeResolver {
    static func resolve(
        settings: AppSettings = AppSettings(),
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> AudioRuntimeStatus {
        switch settings.audioTranscriptionProvider {
        case .openAI:
            let apiKey = settings.resolvedAudioTranscriptionAPIKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                return .missingAPIKey("в настройках аудио не задан ключ OpenAI")
            }

            return .cloudReady(
                AudioCloudRuntimeEnvironment(
                    baseURL: settings.audioTranscriptionBaseURL,
                    apiKey: apiKey,
                    microphoneModel: settings.audioMicrophoneModel,
                    systemAudioModel: settings.audioSystemModel
                )
            )

        case .localWhisper:
            break
        }

        guard let scriptPath = resolveScriptPath(fileManager: fileManager, bundle: bundle) else {
            return .missingScript("whisper_transcribe.py was not found in the bundle or source tree")
        }

        let configuredCommand = settings.audioPythonCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredCommand.isEmpty {
            return resolveConfiguredCommand(configuredCommand, scriptPath: scriptPath, modelName: settings.audioModelName, fileManager: fileManager)
        }

        if let localVenv = defaultPythonCandidates(fileManager: fileManager).first {
            return .ready(
                AudioRuntimeEnvironment(
                    executableURL: URL(fileURLWithPath: localVenv),
                    launchArgumentsPrefix: [],
                    scriptPath: scriptPath,
                    modelName: settings.audioModelName
                )
            )
        }

        return .ready(
            AudioRuntimeEnvironment(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                launchArgumentsPrefix: ["python3"],
                scriptPath: scriptPath,
                modelName: settings.audioModelName
            )
        )
    }

    private static func resolveConfiguredCommand(
        _ command: String,
        scriptPath: String,
        modelName: String,
        fileManager: FileManager
    ) -> AudioRuntimeStatus {
        if command.contains("/") {
            guard fileManager.isExecutableFile(atPath: command) else {
                return .missingPython(command)
            }
            return .ready(
                AudioRuntimeEnvironment(
                    executableURL: URL(fileURLWithPath: command),
                    launchArgumentsPrefix: [],
                    scriptPath: scriptPath,
                    modelName: modelName
                )
            )
        }

        return .ready(
            AudioRuntimeEnvironment(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                launchArgumentsPrefix: [command],
                scriptPath: scriptPath,
                modelName: modelName
            )
        )
    }

    private static func resolveScriptPath(fileManager: FileManager, bundle: Bundle) -> String? {
        if let bundled = Bundle.module.url(forResource: "whisper_transcribe", withExtension: "py")?.path {
            return bundled
        }

        if let bundled = bundle.resourceURL?.appendingPathComponent("whisper_transcribe.py").path,
           fileManager.fileExists(atPath: bundled) {
            return bundled
        }

        let projectRoot = bundle.bundlePath.components(separatedBy: "/build/").first ?? fileManager.currentDirectoryPath
        let sourcePath = projectRoot + "/Sources/MyMacAgent/Audio/whisper_transcribe.py"
        if fileManager.fileExists(atPath: sourcePath) {
            return sourcePath
        }

        return nil
    }

    private static func defaultPythonCandidates(fileManager: FileManager) -> [String] {
        let currentDirectory = fileManager.currentDirectoryPath
        let directCandidates = [
            currentDirectory + "/.venv/bin/python3",
            NSHomeDirectory() + "/mymacagent/.venv/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]

        return directCandidates.filter { fileManager.isExecutableFile(atPath: $0) }
    }
}

struct AudioProcessInfo {
    let pid: pid_t
    let bundleID: String?
    let inputDeviceIDs: [AudioDeviceID]
    let isRunningInput: Bool
    let outputDeviceIDs: [AudioDeviceID]
    let isRunningOutput: Bool

    init(
        pid: pid_t,
        bundleID: String? = nil,
        inputDeviceIDs: [AudioDeviceID] = [],
        isRunningInput: Bool = false,
        outputDeviceIDs: [AudioDeviceID] = [],
        isRunningOutput: Bool = false
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.inputDeviceIDs = inputDeviceIDs
        self.isRunningInput = isRunningInput
        self.outputDeviceIDs = outputDeviceIDs
        self.isRunningOutput = isRunningOutput
    }
}

enum AudioProcessInspector {
    static func fetchProcesses() -> [AudioProcessInfo] {
        let processObjectIDs = readObjectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return processObjectIDs.compactMap { processObjectID in
            guard let pid = readUInt32(
                objectID: processObjectID,
                selector: kAudioProcessPropertyPID
            ) else {
                return nil
            }

            let inputDevices = readObjectIDArray(
                objectID: processObjectID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            )
            let outputDevices = readObjectIDArray(
                objectID: processObjectID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            )
            let isRunningInput = readUInt32(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningInput
            ) ?? 0
            let isRunningOutput = readUInt32(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) ?? 0

            return AudioProcessInfo(
                pid: pid_t(pid),
                bundleID: NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier,
                inputDeviceIDs: inputDevices,
                isRunningInput: isRunningInput != 0,
                outputDeviceIDs: outputDevices,
                isRunningOutput: isRunningOutput != 0
            )
        }
    }

    private static func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readObjectIDArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr, propertySize > 0 else {
            return []
        }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(0), count: count)
        let readStatus = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &values)
        guard readStatus == noErr else {
            return []
        }
        return values
    }
}

enum MicrophoneUsageEvaluator {
    static func hasExternalProcessUsingInputDevice(
        _ processes: [AudioProcessInfo],
        inputDeviceID: AudioDeviceID,
        currentPID: pid_t = getpid()
    ) -> Bool {
        processes.contains { process in
            process.pid != currentPID &&
            process.isRunningInput &&
            process.inputDeviceIDs.contains(inputDeviceID)
        }
    }
}

enum SystemAudioUsageEvaluator {
    private static let lowConfidenceHelperOwners: [String: String] = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
        "com.google.Chrome.helper": "com.google.Chrome",
        "com.brave.Browser.helper": "com.brave.Browser",
        "com.microsoft.edgemac.helper": "com.microsoft.edgemac",
        "com.apple.corespeechd": "com.apple.corespeechd"
    ]

    static func significantExternalProcesses(
        _ processes: [AudioProcessInfo],
        outputDeviceID: AudioDeviceID,
        currentPID: pid_t = getpid()
    ) -> [AudioProcessInfo] {
        processes.filter { process in
            process.pid != currentPID &&
            process.isRunningOutput &&
            process.outputDeviceIDs.contains(outputDeviceID) &&
            !(process.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    static func hasExternalProcessUsingOutputDevice(
        _ processes: [AudioProcessInfo],
        outputDeviceID: AudioDeviceID,
        currentPID: pid_t = getpid()
    ) -> Bool {
        !significantExternalProcesses(
            processes,
            outputDeviceID: outputDeviceID,
            currentPID: currentPID
        ).isEmpty
    }

    static func canonicalSignature(
        _ processes: [AudioProcessInfo],
        outputDeviceID: AudioDeviceID,
        currentPID: pid_t = getpid()
    ) -> String? {
        let bundleIDs = significantExternalProcesses(
            processes,
            outputDeviceID: outputDeviceID,
            currentPID: currentPID
        )
        .compactMap(\.bundleID)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        guard !bundleIDs.isEmpty else {
            return nil
        }

        return Array(Set(bundleIDs)).sorted().joined(separator: "|")
    }

    static func isLowConfidenceSignature(_ signature: String) -> Bool {
        let bundleIDs = signatureComponents(signature)
        guard !bundleIDs.isEmpty else {
            return false
        }

        return bundleIDs.allSatisfy { lowConfidenceHelperOwners[$0] != nil }
    }

    static func hasFrontmostAffinity(_ signature: String, frontmostBundleID: String?) -> Bool {
        guard let frontmostBundleID, !frontmostBundleID.isEmpty else {
            return false
        }

        return signatureComponents(signature).contains { bundleID in
            canonicalOwnerBundleID(for: bundleID) == frontmostBundleID
                || bundleID == frontmostBundleID
        }
    }

    private static func signatureComponents(_ signature: String) -> [String] {
        signature
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func canonicalOwnerBundleID(for bundleID: String) -> String {
        lowConfidenceHelperOwners[bundleID] ?? bundleID
    }
}

enum SystemAudioProbePolicy {
    static func shouldAttemptCapture(
        now: Date,
        hasExternalOutput: Bool,
        phase: SystemAudioCapturePhase,
        retryCaptureAfter: Date,
        stableOutputObservedSince: Date?,
        minimumStableObservation: TimeInterval,
        outputSignature: String?,
        isLowConfidenceOutput: Bool,
        hasFrontmostAffinity: Bool,
        suppressedSilentSignature: String?,
        requiresSilentSignatureReset: Bool,
        knownAudibleSignatures: Set<String>,
        globalSilentCooldownUntil: Date
    ) -> Bool {
        guard hasExternalOutput, phase == .idle, now >= retryCaptureAfter else {
            return false
        }

        guard now >= globalSilentCooldownUntil else {
            return false
        }

        guard let stableOutputObservedSince,
              now.timeIntervalSince(stableOutputObservedSince) >= minimumStableObservation else {
            return false
        }

        guard let outputSignature else {
            return false
        }

        let isKnownAudibleSignature = knownAudibleSignatures.contains(outputSignature)

        if isLowConfidenceOutput && !isKnownAudibleSignature && !hasFrontmostAffinity {
            return false
        }

        if requiresSilentSignatureReset && outputSignature == suppressedSilentSignature {
            return false
        }

        if isKnownAudibleSignature {
            return true
        }

        return true
    }
}
