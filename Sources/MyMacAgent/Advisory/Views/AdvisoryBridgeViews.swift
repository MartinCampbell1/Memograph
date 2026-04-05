import SwiftUI

struct AdvisoryProviderDiagnosticsView: View {
    let providerStatuses: [AdvisoryProviderDiagnostic]
    let activeProviderName: String?
    var checkedAt: String? = nil
    var compact: Bool = false

    private var diagnostics: [AdvisoryProviderDiagnostic] {
        providerStatuses
            .sorted { $0.priority < $1.priority }
            .filter { diagnostic in
                if compact {
                    return diagnostic.status != "not_checked" || activeProviderName == diagnostic.providerName
                }
                return true
            }
    }

    var body: some View {
        if !diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                if !compact {
                    HStack {
                        Text("Provider sessions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let checkedAt, !checkedAt.isEmpty {
                            Text(checkedAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(diagnostics) { diagnostic in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(statusTint(for: diagnostic))
                            .frame(width: 7, height: 7)
                            .padding(.top, compact ? 4 : 5)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(diagnostic.displayName)
                                    .font(compact ? .caption : .caption.weight(.medium))
                                Text(statusText(for: diagnostic))
                                    .font(.caption2)
                                    .foregroundStyle(statusTint(for: diagnostic))
                            }
                            if let detail = diagnostic.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusText(for diagnostic: AdvisoryProviderDiagnostic) -> String {
        if activeProviderName == diagnostic.providerName {
            return "selected"
        }
        if let cooldownRemainingSeconds = diagnostic.cooldownRemainingSeconds, cooldownRemainingSeconds > 0 {
            return "\(diagnostic.statusLabel) · \(cooldownRemainingSeconds)s"
        }
        return diagnostic.statusLabel
    }

    private func statusTint(for diagnostic: AdvisoryProviderDiagnostic) -> Color {
        if activeProviderName == diagnostic.providerName {
            return .green
        }
        switch diagnostic.status {
        case "ok":
            return .green
        case "session_expired", "session_missing":
            return .orange
        case "timeout":
            return .yellow
        case "cooldown":
            return .orange
        case "binary_missing", "unavailable":
            return .secondary
        default:
            return .secondary
        }
    }
}
