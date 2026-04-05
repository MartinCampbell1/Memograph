import Foundation

struct AdvisorySidecarRuntimeEnvironment {
    let executableURL: URL
    let launchArgumentsPrefix: [String]
    let scriptPath: String
    let baseEnvironment: [String: String]
}

enum AdvisorySidecarRuntimeStatus {
    case ready(AdvisorySidecarRuntimeEnvironment)
    case missingPython(String)
    case missingScript(String)

    var description: String {
        switch self {
        case .ready(let environment):
            let command = environment.launchArgumentsPrefix.first ?? environment.executableURL.lastPathComponent
            return "Advisory sidecar ready via \(command)"
        case .missingPython(let details):
            return "Missing Python runtime for advisory sidecar: \(details)"
        case .missingScript(let details):
            return "Missing advisory sidecar script: \(details)"
        }
    }
}

enum AdvisorySidecarSocketPathResolver {
    private static let unixSocketPathLimit = 100

    static func resolve(_ configuredPath: String) -> String {
        let expandedPath = (configuredPath as NSString).expandingTildeInPath
        guard expandedPath.utf8.count >= unixSocketPathLimit else {
            return expandedPath
        }

        let token = AdvisorySupport
            .stableIdentifier(prefix: "advisor_socket", components: [expandedPath])
            .replacingOccurrences(of: "advisor_socket_", with: "")
        return "/tmp/memograph-advisor-\(token).sock"
    }
}

enum AdvisorySidecarRuntimeResolver {
    static func resolve(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredPythonCandidates: [String]? = nil
    ) -> AdvisorySidecarRuntimeStatus {
        guard let scriptPath = resolveScriptPath(fileManager: fileManager, bundle: bundle) else {
            return .missingScript("memograph_advisor.py was not found in the bundle or source tree")
        }

        if let localPython = defaultPythonCandidates(
            fileManager: fileManager,
            environment: environment,
            preferredCandidates: preferredPythonCandidates
        ).first {
            return .ready(
                AdvisorySidecarRuntimeEnvironment(
                    executableURL: URL(fileURLWithPath: localPython),
                    launchArgumentsPrefix: [],
                    scriptPath: scriptPath,
                    baseEnvironment: defaultEnvironment()
                )
            )
        }

        return .missingPython("python3 was not found in .venv, common locations, or PATH")
    }

    private static func resolveScriptPath(
        fileManager: FileManager,
        bundle: Bundle
    ) -> String? {
        if let bundled = Bundle.module.url(forResource: "memograph_advisor", withExtension: "py")?.path {
            return bundled
        }

        if let bundled = bundle.resourceURL?.appendingPathComponent("memograph_advisor.py").path,
           fileManager.fileExists(atPath: bundled) {
            return bundled
        }

        let projectRoot = bundle.bundlePath.components(separatedBy: "/build/").first ?? fileManager.currentDirectoryPath
        let sourcePath = projectRoot + "/Sources/MyMacAgent/Advisory/Bridge/memograph_advisor.py"
        if fileManager.fileExists(atPath: sourcePath) {
            return sourcePath
        }

        return nil
    }

    private static func defaultPythonCandidates(
        fileManager: FileManager,
        environment: [String: String],
        preferredCandidates: [String]?
    ) -> [String] {
        let currentDirectory = fileManager.currentDirectoryPath
        let directCandidates = preferredCandidates ?? [
            currentDirectory + "/.venv/bin/python3",
            NSHomeDirectory() + "/mymacagent/.venv/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { ($0 as NSString).appendingPathComponent("python3") }

        return AdvisorySupport.dedupe(directCandidates + pathCandidates)
            .filter { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func defaultEnvironment() -> [String: String] {
        [
            "PYTHONUNBUFFERED": "1",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]
    }
}
