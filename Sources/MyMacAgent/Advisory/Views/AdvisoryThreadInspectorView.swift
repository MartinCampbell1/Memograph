import SwiftUI

struct AdvisoryThreadInspectorView: View {
    let snapshot: AdvisoryThreadDetailSnapshot
    let statusMessage: String?
    let onRename: (String?) -> Void
    let onTogglePinned: () -> Void
    let onSetStatus: (AdvisoryThreadStatus) -> Void
    let onExport: () -> Void
    let onTurnIntoSignal: () -> Void
    let onCreateSubthread: () -> Void
    let onSelectThread: (String) -> Void
    let onApplyMaintenanceProposal: (AdvisoryThreadMaintenanceProposal) -> Void
    let onQuickAction: (String, AdvisoryArtifactQuickAction) -> Void
    let onFeedback: (String, AdvisoryArtifactFeedbackKind) -> Void

    @State private var titleOverride = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                titleEditor
                summarySection
                maintenanceSection
                relationsSection
                continuitySection
                artifactsSection
                evidenceSection
            }
            .padding()
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { syncTitleOverride() }
        .onChange(of: snapshot.thread.id) { syncTitleOverride() }
        .onChange(of: snapshot.thread.userTitleOverride) { syncTitleOverride() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thread")
                        .font(.headline)
                    Text(snapshot.thread.displayTitle)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button(snapshot.thread.userPinned ? "Unpin" : "Pin", action: onTogglePinned)
                    Menu("Status") {
                        ForEach(AdvisoryThreadStatus.allCases, id: \.rawValue) { status in
                            Button(threadStatusLabel(status)) {
                                onSetStatus(status)
                            }
                        }
                    }
                    Button("Turn Into Signal", action: onTurnIntoSignal)
                    Button("Export to Obsidian", action: onExport)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                badge(threadStatusLabel(snapshot.thread.status))
                badge(threadKindLabel(snapshot.thread.kind))
                Text("Importance \(Int(snapshot.thread.importanceScore * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ObsidianExporter.formatDuration(minutes: snapshot.thread.totalActiveMinutes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display title")
                .font(.subheadline.weight(.semibold))
            TextField("Optional user title override", text: $titleOverride)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save title") {
                    onRename(normalizedOverride)
                }
                Button("Reset") {
                    titleOverride = ""
                    onRename(nil)
                }
                .disabled(snapshot.thread.userTitleOverride == nil && titleOverride.isEmpty)
                Spacer()
                Button("New sub-thread", action: onCreateSubthread)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.subheadline.weight(.semibold))
            Text(snapshot.thread.summary ?? "Пока нет summary для этой нити.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                if let firstSeenAt = snapshot.thread.firstSeenAt {
                    metaRow("First seen", value: firstSeenAt)
                }
                if let lastActiveAt = snapshot.thread.lastActiveAt {
                    metaRow("Last active", value: lastActiveAt)
                }
                if let lastArtifactAt = snapshot.thread.lastArtifactAt {
                    metaRow("Last artifact", value: lastArtifactAt)
                }
            }
        }
    }

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Maintenance")
                .font(.subheadline.weight(.semibold))
            if snapshot.maintenanceProposals.isEmpty {
                Text("Пока нет явных maintenance moves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.maintenanceProposals) { proposal in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(proposal.title)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(proposal.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(proposal.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let suggestedStatus = proposal.suggestedStatus {
                            Text("Suggested status: \(threadStatusLabel(suggestedStatus))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let targetThreadTitle = proposal.targetThreadTitle {
                            Text("Target: \(targetThreadTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let suggestedTitle = proposal.suggestedTitle,
                           proposal.kind == .splitIntoSubthread {
                            Text("Suggested sub-thread: \(suggestedTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(maintenanceActionLabel(for: proposal)) {
                                onApplyMaintenanceProposal(proposal)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(0.06))
                    )
                }
            }
        }
    }

    private var relationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relations")
                .font(.subheadline.weight(.semibold))

            if let parentThread = snapshot.parentThread {
                Button {
                    onSelectThread(parentThread.id)
                } label: {
                    relationRow(
                        title: parentThread.displayTitle,
                        subtitle: "Parent thread",
                        isPinned: parentThread.userPinned
                    )
                }
                .buttonStyle(.plain)
            }

            if snapshot.childThreads.isEmpty {
                Text("Нет sub-threads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.childThreads) { child in
                    Button {
                        onSelectThread(child.id)
                    } label: {
                        relationRow(
                            title: child.displayTitle,
                            subtitle: "\(threadStatusLabel(child.status)) · \(ObsidianExporter.formatDuration(minutes: child.totalActiveMinutes))",
                            isPinned: child.userPinned
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var continuitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open loops")
                .font(.subheadline.weight(.semibold))
            if snapshot.continuityItems.isEmpty {
                Text("Нет continuity items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.continuityItems.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                        Text(continuityStatusLabel(item.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let body = item.body, !body.isEmpty {
                            Text(AdvisorySupport.cleanedSnippet(body, maxLength: 120))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }
        }
    }

    private var artifactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent advisory artifacts")
                .font(.subheadline.weight(.semibold))
            if snapshot.artifacts.isEmpty {
                Text("Artifacts ещё не появлялись.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.artifacts.prefix(6)) { artifact in
                    AdvisoryArtifactCardView(
                        artifact: artifact,
                        thread: snapshot.thread,
                        maxBodyLength: 140,
                        maxSteps: 2,
                        onQuickAction: { action in
                            onQuickAction(artifact.id, action)
                        },
                        onFeedback: { kind in
                            onFeedback(artifact.id, kind)
                        }
                    )
                }
            }
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence")
                .font(.subheadline.weight(.semibold))
            if snapshot.evidence.isEmpty {
                Text("Явных evidence refs пока нет.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.evidence.prefix(10)) { evidence in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(evidence.evidenceKind)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(evidence.evidenceRef)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func relationRow(
        title: String,
        subtitle: String,
        isPinned: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var normalizedOverride: String? {
        let trimmed = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func syncTitleOverride() {
        titleOverride = snapshot.thread.userTitleOverride ?? ""
    }

    private func threadStatusLabel(_ status: AdvisoryThreadStatus) -> String {
        switch status {
        case .active: return "active"
        case .stalled: return "stalled"
        case .parked: return "parked"
        case .resolved: return "resolved"
        }
    }

    private func threadKindLabel(_ kind: AdvisoryThreadKind) -> String {
        switch kind {
        case .project: return "project"
        case .question: return "question"
        case .interest: return "interest"
        case .person: return "person"
        case .commitment: return "commitment"
        case .theme: return "theme"
        }
    }

    private func continuityStatusLabel(_ status: ContinuityItemStatus) -> String {
        switch status {
        case .open: return "open"
        case .stabilizing: return "stabilizing"
        case .parked: return "parked"
        case .resolved: return "resolved"
        }
    }

    private func maintenanceActionLabel(
        for proposal: AdvisoryThreadMaintenanceProposal
    ) -> String {
        switch proposal.kind {
        case .statusChange:
            return "Apply Status"
        case .reparentUnderThread:
            return "Make Child Thread"
        case .mergeIntoThread:
            return "Merge Threads"
        case .splitIntoSubthread:
            return "Create Sub-thread"
        }
    }
}
