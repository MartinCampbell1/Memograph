import CoreAudio
import Foundation

struct AudioRuntimeEnvironment {
    let executableURL: URL
    let launchArgumentsPrefix: [String]
    let scriptPath: String
    let modelName: String
}

enum AudioRuntimeStatus {
    case ready(AudioRuntimeEnvironment)
    case missingPython(String)
    case missingScript(String)

    var description: String {
        switch self {
        case .ready(let env):
            let command = env.launchArgumentsPrefix.first ?? env.executableURL.lastPathComponent
            return "Ready (\(command))"
        case .missingPython(let details):
            return "Python runtime missing: \(details)"
        case .missingScript(let details):
            return "Whisper helper missing: \(details)"
        }
    }
}

enum AudioRuntimeResolver {
    static func resolve(
        settings: AppSettings = AppSettings(),
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> AudioRuntimeStatus {
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
    let inputDeviceIDs: [AudioDeviceID]
    let isRunningInput: Bool
    let outputDeviceIDs: [AudioDeviceID]
    let isRunningOutput: Bool

    init(
        pid: pid_t,
        inputDeviceIDs: [AudioDeviceID] = [],
        isRunningInput: Bool = false,
        outputDeviceIDs: [AudioDeviceID] = [],
        isRunningOutput: Bool = false
    ) {
        self.pid = pid
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
    static func hasExternalProcessUsingOutputDevice(
        _ processes: [AudioProcessInfo],
        outputDeviceID: AudioDeviceID,
        currentPID: pid_t = getpid()
    ) -> Bool {
        processes.contains { process in
            process.pid != currentPID &&
            process.isRunningOutput &&
            process.outputDeviceIDs.contains(outputDeviceID)
        }
    }
}

enum SystemAudioProbePolicy {
    static func shouldAttemptCapture(
        now: Date,
        hasExternalOutput: Bool,
        isCapturing: Bool,
        retryCaptureAfter: Date,
        stableOutputObservedSince: Date?,
        minimumStableObservation: TimeInterval,
        outputSignature: String?,
        suppressedSilentSignature: String?,
        suppressedSilentSignatureUntil: Date,
        globalSilentCooldownUntil: Date
    ) -> Bool {
        guard hasExternalOutput, !isCapturing, now >= retryCaptureAfter else {
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
            return true
        }

        return outputSignature != suppressedSilentSignature || now >= suppressedSilentSignatureUntil
    }
}
