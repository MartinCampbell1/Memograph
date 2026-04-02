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
