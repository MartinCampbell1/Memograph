import Foundation
import os

struct AppliedKnowledgeDraftResult {
    let artifact: KnowledgeDraftArtifact
    let appliedPath: String
    let backupPath: String?
}

final class ObsidianExporter {
    private struct SummaryWindowMetadata {
        let count: Int?
        let windowStart: Date?
        let windowEnd: Date?
        let mode: String?

        var isHourly: Bool {
            guard let windowStart, let windowEnd else { return false }
            if mode == "hourly" {
                return true
            }
            return windowEnd.timeIntervalSince(windowStart) < 23 * 3600
        }
    }

    private let db: DatabaseManager
    private let vaultPath: String
    private let logger = Logger.export
    private let dateSupport: LocalDateSupport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(db: DatabaseManager, vaultPath: String = "", timeZone: TimeZone = .autoupdatingCurrent) {
        self.db = db
        self.vaultPath = vaultPath
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func renderDailyNote(summary: DailySummaryRecord) throws -> String {
        let metadata = summaryWindowMetadata(from: summary.contextSwitchesJson)
        let title = noteTitle(for: summary, metadata: metadata)
        var md = "# \(title)\n\n"

        // Navigation links (graph connections between days)
        let prevDay = offsetDate(summary.date, by: -1)
        let nextDay = offsetDate(summary.date, by: 1)
        md += "← [[Daily/\(prevDay)|\(prevDay)]] | [[Daily/\(nextDay)|\(nextDay)]] →\n\n"

        if let metadata, metadata.isHourly,
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            md += "_Окно отчёта: \(dateSupport.localDateTimeString(from: windowStart)) → "
            md += "\(dateSupport.localDateTimeString(from: windowEnd)) (\(dateSupport.timeZone.identifier))_\n\n"
        }

        if let richBody = richStructuredBody(from: summary.summaryText) {
            return md + stripTopHeading(from: richBody) + (richBody.hasSuffix("\n") ? "" : "\n")
        }

        // Summary
        md += "## Сводка\n"
        md += "\(summary.summaryText ?? "Сводка недоступна.")\n\n"

        // Main apps
        md += "## Основные приложения\n"
        if let appsJson = summary.topAppsJson,
           let appsData = appsJson.data(using: .utf8),
           let apps = try? JSONSerialization.jsonObject(with: appsData) as? [[String: Any]] {
            for app in apps {
                let name = app["name"] as? String ?? "Неизвестно"
                let minutes = app["duration_min"] as? Int ?? 0
                md += "- \(name) — \(Self.formatDuration(minutes: minutes))\n"
            }
        } else {
            md += "- Нет данных по приложениям\n"
        }
        md += "\n"

        // Main topics
        md += "## Основные темы\n"
        if let topicsJson = summary.topTopicsJson,
           let topicsData = topicsJson.data(using: .utf8),
           let topics = try? JSONSerialization.jsonObject(with: topicsData) as? [String] {
            for topic in topics {
                md += "- [[\(topic)]]\n"
            }
        } else {
            md += "- Темы не извлечены\n"
        }
        md += "\n"

        // Timeline
        md += "## Таймлайн\n"
        let timeline: String
        if let metadata, metadata.isHourly,
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            let window = SummaryWindowDescriptor(date: summary.date, start: windowStart, end: windowEnd)
            timeline = try buildTimeline(for: window)
        } else {
            timeline = try buildTimeline(for: summary.date)
        }
        md += timeline.isEmpty ? "- Сессии не записаны\n" : timeline
        md += "\n"

        // Suggested notes
        md += "## Предлагаемые заметки\n"
        if let notesJson = summary.suggestedNotesJson,
           let notesData = notesJson.data(using: .utf8),
           let notes = try? JSONSerialization.jsonObject(with: notesData) as? [String] {
            for note in notes {
                md += "- [[\(note)]]\n"
            }
        } else {
            md += "- Предложений нет\n"
        }
        md += "\n"

        // Continue next
        if let unfinished = summary.unfinishedItemsJson {
            md += "## Продолжить далее\n"
            md += "- \(unfinished)\n\n"
        }

        return md
    }

    func buildTimeline(for date: String) throws -> String {
        guard let start = dateSupport.startOfLocalDay(for: date),
              let end = dateSupport.endOfLocalDay(for: date) else {
            return ""
        }
        return try buildTimeline(for: SummaryWindowDescriptor(date: date, start: start, end: end))
    }

    func buildTimeline(for window: SummaryWindowDescriptor) throws -> String {
        let rangeStart = dateSupport.isoString(from: window.start)
        let rangeEnd = dateSupport.isoString(from: window.end)
        let sessions = try db.query("""
            SELECT s.started_at, s.ended_at, a.app_name
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at < ? AND COALESCE(s.ended_at, ?) >= ?
            ORDER BY s.started_at
        """, params: [.text(rangeEnd), .text(rangeEnd), .text(rangeStart)])

        var timeline = ""
        for row in sessions {
            guard let startedAt = row["started_at"]?.textValue,
                  let appName = row["app_name"]?.textValue else { continue }
            guard let sessionStart = dateSupport.parseDateTime(startedAt) else { continue }

            let sessionEnd = row["ended_at"]?.textValue.flatMap(dateSupport.parseDateTime) ?? window.end
            let clippedStart = max(sessionStart, window.start)
            let clippedEnd = min(sessionEnd, window.end)
            guard clippedEnd > clippedStart else { continue }

            let startTime = formatTime(dateSupport.isoString(from: clippedStart))
            let endTime = formatTime(dateSupport.isoString(from: clippedEnd))
            timeline += "- \(startTime)–\(endTime) — \(appName)\n"
        }
        return timeline
    }

    func exportDailyNote(summary: DailySummaryRecord) throws -> String {
        let markdown = try renderDailyNote(summary: summary)

        let dailyDir = (vaultPath as NSString).appendingPathComponent("Daily")
        try FileManager.default.createDirectory(atPath: dailyDir, withIntermediateDirectories: true)

        let filename = noteFilename(for: summary)
        let filePath = (dailyDir as NSString).appendingPathComponent(filename)

        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        logger.info("Exported daily note to \(filePath)")

        return filePath
    }

    func exportKnowledgeNote(_ note: KnowledgeNoteRecord) throws -> String {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        let folder = knowledgeFolderName(for: note.noteType)
        let directory = (knowledgeRoot as NSString).appendingPathComponent(folder)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let slug = knowledgeSlug(for: note.title)
        let filePath = (directory as NSString).appendingPathComponent("\(slug).md")
        try note.bodyMarkdown.write(toFile: filePath, atomically: true, encoding: .utf8)

        try? db.execute("""
            UPDATE knowledge_notes
            SET export_obsidian_status = 'done'
            WHERE id = ?
        """, params: [.text(note.id)])

        return filePath
    }

    func exportKnowledgeIndex(_ markdown: String) throws -> String {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        try FileManager.default.createDirectory(atPath: knowledgeRoot, withIntermediateDirectories: true)

        let filePath = (knowledgeRoot as NSString).appendingPathComponent("_index.md")
        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    func exportKnowledgeMaintenance(_ markdown: String) throws -> String {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        try FileManager.default.createDirectory(atPath: knowledgeRoot, withIntermediateDirectories: true)

        let filePath = (knowledgeRoot as NSString).appendingPathComponent("_maintenance.md")
        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    func renderAdvisoryThread(_ detail: AdvisoryThreadDetailSnapshot) -> String {
        var md = "# Нить — \(detail.thread.displayTitle)\n\n"
        md += "_Тип: \(threadKindLabel(detail.thread.kind)) · Статус: \(threadStatusLabel(detail.thread.status))"
        if detail.thread.userPinned {
            md += " · pinned"
        }
        md += "_\n\n"

        if detail.thread.displayTitle != detail.thread.title {
            md += "- Canonical title: \(detail.thread.title)\n"
        }
        md += "- Importance: \(String(format: "%.2f", detail.thread.importanceScore))\n"
        md += "- Confidence: \(String(format: "%.2f", detail.thread.confidence))\n"
        md += "- Total active: \(Self.formatDuration(minutes: detail.thread.totalActiveMinutes))\n"
        if let firstSeenAt = detail.thread.firstSeenAt {
            md += "- First seen: \(dateSupport.localDateTimeString(from: firstSeenAt))\n"
        }
        if let lastActiveAt = detail.thread.lastActiveAt {
            md += "- Last active: \(dateSupport.localDateTimeString(from: lastActiveAt))\n"
        }
        if let lastArtifactAt = detail.thread.lastArtifactAt {
            md += "- Last advisory artifact: \(dateSupport.localDateTimeString(from: lastArtifactAt))\n"
        }
        if let parentThread = detail.parentThread {
            md += "- Parent thread: [[\(parentThread.slug)|\(parentThread.displayTitle)]]\n"
        }
        md += "\n"

        md += "## Summary\n"
        md += "\(detail.thread.summary ?? "Пока нет summary для этой нити.")\n\n"

        md += "## Open Loops\n"
        if detail.continuityItems.isEmpty {
            md += "- Нет открытых continuity items.\n\n"
        } else {
            for item in detail.continuityItems {
                md += "- \(item.title) · \(continuityStatusLabel(item.status))\n"
            }
            md += "\n"
        }

        md += "## Child Threads\n"
        if detail.childThreads.isEmpty {
            md += "- Нет sub-threads.\n\n"
        } else {
            for child in detail.childThreads {
                md += "- [[\(child.slug)|\(child.displayTitle)]] · \(threadStatusLabel(child.status)) · \(Self.formatDuration(minutes: child.totalActiveMinutes))\n"
            }
            md += "\n"
        }

        md += "## Maintenance\n"
        if detail.maintenanceProposals.isEmpty {
            md += "- Похоже, maintenance moves сейчас не обязательны.\n\n"
        } else {
            for proposal in detail.maintenanceProposals {
                md += "- \(proposal.title) · \(Int(proposal.confidence * 100))%\n"
                md += "  - \(proposal.rationale)\n"
                if let targetThreadTitle = proposal.targetThreadTitle {
                    md += "  - Target: \(targetThreadTitle)\n"
                }
                if let suggestedTitle = proposal.suggestedTitle {
                    md += "  - Suggested title: \(suggestedTitle)\n"
                }
            }
            md += "\n"
        }

        md += "## Recent Advisory Artifacts\n"
        if detail.artifacts.isEmpty {
            md += "- Advisory artifacts ещё не появлялись.\n\n"
        } else {
            for artifact in detail.artifacts {
                md += "- \(artifact.kind.rawValue) · \(artifact.title) · \(artifact.status.rawValue)\n"
            }
            md += "\n"
        }

        md += "## Evidence\n"
        if detail.evidence.isEmpty {
            md += "- Явных evidence refs пока нет.\n"
        } else {
            for evidence in detail.evidence.prefix(20) {
                md += "- \(evidence.evidenceKind): \(evidence.evidenceRef)\n"
            }
        }
        md += "\n"
        return md
    }

    func exportAdvisoryThread(_ detail: AdvisoryThreadDetailSnapshot) throws -> String {
        let threadsRoot = (knowledgeRootDirectory() as NSString).appendingPathComponent("Threads")
        try FileManager.default.createDirectory(atPath: threadsRoot, withIntermediateDirectories: true)

        let filePath = (threadsRoot as NSString).appendingPathComponent("\(detail.thread.slug).md")
        try renderAdvisoryThread(detail).write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    @discardableResult
    func syncKnowledgeDraftArtifacts(_ artifacts: [KnowledgeDraftArtifact]) throws -> [String] {
        let draftsRoot = knowledgeDraftsDirectory()
        try FileManager.default.createDirectory(atPath: draftsRoot, withIntermediateDirectories: true)

        let expectedRelativePaths = Set(artifacts.map(\.relativePath))
        let enumerator = FileManager.default.enumerator(atPath: draftsRoot)
        while let relativePath = enumerator?.nextObject() as? String {
            guard relativePath.hasSuffix(".md"),
                  !relativePath.hasPrefix("AppliedBackup/"),
                  !relativePath.hasPrefix("ReviewResolved/"),
                  !expectedRelativePaths.contains(relativePath) else {
                continue
            }
            let path = (draftsRoot as NSString).appendingPathComponent(relativePath)
            if archiveResolvedReviewDraftIfNeeded(at: path, relativePath: relativePath, draftsRoot: draftsRoot) != nil {
                continue
            }
            try? FileManager.default.removeItem(atPath: path)
        }

        var writtenPaths: [String] = []
        for artifact in artifacts {
            let filePath = (draftsRoot as NSString).appendingPathComponent(artifact.relativePath)
            let directory = (filePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let markdownToWrite = mergedDraftMarkdownPreservingReviewDecision(
                for: artifact,
                existingPath: filePath
            )
            try markdownToWrite.write(toFile: filePath, atomically: true, encoding: .utf8)
            writtenPaths.append(filePath)
        }

        pruneEmptyDraftDirectories(under: draftsRoot)
        return writtenPaths
    }

    @discardableResult
    func applyKnowledgeDraftArtifacts(_ artifacts: [KnowledgeDraftArtifact]) throws -> [AppliedKnowledgeDraftResult] {
        let applyableArtifacts = artifacts.filter { $0.applyTargetRelativePath != nil }
        guard !applyableArtifacts.isEmpty else { return [] }

        let knowledgeRoot = knowledgeRootDirectory()
        try FileManager.default.createDirectory(atPath: knowledgeRoot, withIntermediateDirectories: true)

        let backupRoot = appliedBackupDirectory()
        try FileManager.default.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        var results: [AppliedKnowledgeDraftResult] = []
        for artifact in applyableArtifacts {
            guard let targetRelativePath = artifact.applyTargetRelativePath else { continue }
            let targetPath = (knowledgeRoot as NSString).appendingPathComponent(targetRelativePath)
            let targetDirectory = (targetPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)

            var backupPath: String?
            if FileManager.default.fileExists(atPath: targetPath) {
                backupPath = (backupRoot as NSString).appendingPathComponent(targetRelativePath)
                let backupDirectory = ((backupPath ?? "") as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: backupDirectory, withIntermediateDirectories: true)
                let existingData = try Data(contentsOf: URL(fileURLWithPath: targetPath))
                try existingData.write(to: URL(fileURLWithPath: backupPath ?? ""), options: .atomic)
            }

            try artifact.markdown.write(toFile: targetPath, atomically: true, encoding: .utf8)
            results.append(
                AppliedKnowledgeDraftResult(
                    artifact: artifact,
                    appliedPath: targetPath,
                    backupPath: backupPath
                )
            )
        }

        return results
    }

    func discoverKnowledgeReviewDecisions(existing: [KnowledgeReviewDecisionRecord] = []) -> [KnowledgeReviewDecisionRecord] {
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })

        let draftsRoot = knowledgeDraftsDirectory()
        let archivedReviewRoot = (draftsRoot as NSString).appendingPathComponent("ReviewResolved")
        let activeReviewRoot = (draftsRoot as NSString).appendingPathComponent("Review")

        for root in [archivedReviewRoot, activeReviewRoot] {
            guard FileManager.default.fileExists(atPath: root),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                continue
            }

            for file in files where file.hasSuffix(".md") && file != "_index.md" {
                let path = (root as NSString).appendingPathComponent(file)
                guard let markdown = try? String(contentsOfFile: path, encoding: .utf8),
                      let key = reviewMetadataValue(named: "memograph-review-key", in: markdown),
                      let kindRaw = reviewMetadataValue(named: "memograph-review-kind", in: markdown),
                      let kind = KnowledgeReviewDecisionKind(rawValue: kindRaw),
                      let status = extractReviewDecisionStatus(from: markdown) else {
                    continue
                }

                if root == activeReviewRoot && status == .pending {
                    byKey.removeValue(forKey: key)
                    continue
                }

                guard status != .pending else { continue }
                byKey[key] = KnowledgeReviewDecisionRecord(
                    key: key,
                    kind: kind,
                    status: status,
                    title: extractedTitle(from: markdown) ?? ((file as NSString).deletingPathExtension),
                    path: path,
                    recordedAt: fileModificationISODate(at: path)
                )
            }
        }

        return Array(byKey.values).sorted(by: compareReviewDecisions)
    }

    func discoverApprovedKnowledgeReviewDecisions() -> [KnowledgeReviewDecisionRecord] {
        let reviewRoot = (knowledgeDraftsDirectory() as NSString).appendingPathComponent("Review")
        guard FileManager.default.fileExists(atPath: reviewRoot),
              let files = try? FileManager.default.contentsOfDirectory(atPath: reviewRoot) else {
            return []
        }

        return files
            .filter { $0.hasSuffix(".md") && $0 != "_index.md" }
            .compactMap { file in
                let path = (reviewRoot as NSString).appendingPathComponent(file)
                guard let markdown = try? String(contentsOfFile: path, encoding: .utf8),
                      let key = reviewMetadataValue(named: "memograph-review-key", in: markdown),
                      let kindRaw = reviewMetadataValue(named: "memograph-review-kind", in: markdown),
                      let kind = KnowledgeReviewDecisionKind(rawValue: kindRaw),
                      let status = extractReviewDecisionStatus(from: markdown),
                      status == .apply else {
                    return nil
                }
                return KnowledgeReviewDecisionRecord(
                    key: key,
                    kind: kind,
                    status: status,
                    title: extractedTitle(from: markdown) ?? ((file as NSString).deletingPathExtension),
                    path: path,
                    recordedAt: fileModificationISODate(at: path)
                )
            }
            .sorted(by: compareReviewDecisions)
    }

    func renderKnowledgeReviewHistory(_ records: [KnowledgeReviewDecisionRecord]) -> String {
        var markdown = "# Memograph Решения ревью по слою знаний\n\n"
        markdown += "_Обновлено: \(dateSupport.localDateTimeString(from: Date()))_\n\n"
        markdown += "- [[Knowledge/_drafts/_index|центр управления]]\n"
        markdown += "- [[Knowledge/_drafts/ReviewResolved/_index|доска завершенных ревью]]\n\n"

        guard !records.isEmpty else {
            markdown += "- Пока нет решений ревью со статусом не-pending.\n"
            return markdown
        }

        markdown += "## Недавно отревьюено\n"
        for record in records.sorted(by: compareReviewDecisions).prefix(30) {
            let recordedAt = record.recordedAt
                .flatMap(dateSupport.parseDateTime)
                .map(dateSupport.localDateTimeString(from:))
                ?? record.recordedAt
                ?? "неизвестное время"
            let linkTarget = reviewDecisionLinkTarget(for: record)
            switch record.status {
            case .apply:
                markdown += "- `\(recordedAt)` — одобрено [[\(linkTarget)|\(record.title)]]\n"
            case .dismiss:
                markdown += "- `\(recordedAt)` — отклонено [[\(linkTarget)|\(record.title)]]\n"
            case .pending:
                continue
            }
        }
        markdown += "\n"
        return markdown
    }

    func exportKnowledgeReviewHistory(_ records: [KnowledgeReviewDecisionRecord]) throws -> String {
        let knowledgeRoot = knowledgeRootDirectory()
        try FileManager.default.createDirectory(atPath: knowledgeRoot, withIntermediateDirectories: true)

        let filePath = (knowledgeRoot as NSString).appendingPathComponent("_reviewed.md")
        let markdown = renderKnowledgeReviewHistory(records)
        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    func renderKnowledgeResolvedReviewBoard(_ records: [KnowledgeReviewDecisionRecord]) -> String {
        var markdown = "# Доска завершенных ревью слоя знаний\n\n"
        markdown += "_Архив пакетов ревью, по которым уже принято решение._\n\n"
        markdown += "- [[Knowledge/_drafts/_index|центр управления]]\n\n"

        guard !records.isEmpty else {
            markdown += "- Пока нет завершенных пакетов ревью.\n"
            return markdown
        }

        let approved = records.filter { $0.status == .apply }
        let dismissed = records.filter { $0.status == .dismiss }

        if !approved.isEmpty {
            markdown += "## Одобрено\n"
            for record in approved.sorted(by: compareReviewDecisions).prefix(30) {
                let recordedAt = record.recordedAt
                    .flatMap(dateSupport.parseDateTime)
                    .map(dateSupport.localDateTimeString(from:))
                    ?? record.recordedAt
                    ?? "неизвестное время"
                markdown += "- `\(recordedAt)` — [[\(reviewDecisionLinkTarget(for: record))|\(record.title)]]\n"
            }
            markdown += "\n"
        }

        if !dismissed.isEmpty {
            markdown += "## Отклонено\n"
            for record in dismissed.sorted(by: compareReviewDecisions).prefix(30) {
                let recordedAt = record.recordedAt
                    .flatMap(dateSupport.parseDateTime)
                    .map(dateSupport.localDateTimeString(from:))
                    ?? record.recordedAt
                    ?? "неизвестное время"
                markdown += "- `\(recordedAt)` — [[\(reviewDecisionLinkTarget(for: record))|\(record.title)]]\n"
            }
            markdown += "\n"
        }

        markdown += "## Как использовать\n"
        markdown += "- Используй эту доску, чтобы возвращаться к уже завершенным пакетам ревью.\n"
        markdown += "- Одобренные пакеты уже должны отражаться в `Недавно применено` или в persistent overrides.\n"
        markdown += "- Отклоненные пакеты остаются здесь в архиве, чтобы не возвращаться в активную очередь ревью.\n"
        return markdown
    }

    func exportKnowledgeResolvedReviewBoard(_ records: [KnowledgeReviewDecisionRecord]) throws -> String {
        let resolvedRoot = (knowledgeDraftsDirectory() as NSString).appendingPathComponent("ReviewResolved")
        try FileManager.default.createDirectory(atPath: resolvedRoot, withIntermediateDirectories: true)

        let filePath = (resolvedRoot as NSString).appendingPathComponent("_index.md")
        let markdown = renderKnowledgeResolvedReviewBoard(records)
        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    func renderKnowledgeAppliedHistory(_ records: [KnowledgeAppliedActionRecord]) -> String {
        var markdown = "# Memograph Примененные действия слоя знаний\n\n"
        markdown += "_Обновлено: \(dateSupport.localDateTimeString(from: Date()))_\n\n"
        markdown += "- [[Knowledge/_drafts/_index|центр управления]]\n\n"

        guard !records.isEmpty else {
            markdown += "- Пока не было применено ни одного действия слоя знаний.\n"
            return markdown
        }

        markdown += "## Недавно применено\n"
        for record in records.sorted(by: compareAppliedActions).prefix(20) {
            let appliedAt = dateSupport.parseDateTime(record.appliedAt)
                .map(dateSupport.localDateTimeString(from:))
                ?? record.appliedAt
            let linkTarget = "Knowledge/\(record.applyTargetRelativePath.replacingOccurrences(of: ".md", with: ""))"
            if record.kind == .mergeOverlay, let targetTitle = record.targetTitle {
                markdown += "- `\(appliedAt)` — объединен контекст из `\(record.title)` в [[\(linkTarget)|\(targetTitle)]]\n"
            } else {
                markdown += "- `\(appliedAt)` — \(actionVerb(for: record.kind)) [[\(linkTarget)|\(record.title)]]\n"
            }
            if let backupPath = record.backupPath, !backupPath.isEmpty {
                markdown += "  Бэкап: `\(backupPath)`\n"
            }
        }
        markdown += "\n"
        return markdown
    }

    func exportKnowledgeAppliedHistory(_ records: [KnowledgeAppliedActionRecord]) throws -> String {
        let knowledgeRoot = knowledgeRootDirectory()
        try FileManager.default.createDirectory(atPath: knowledgeRoot, withIntermediateDirectories: true)

        let filePath = (knowledgeRoot as NSString).appendingPathComponent("_applied.md")
        let markdown = renderKnowledgeAppliedHistory(records)
        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    func discoverAppliedKnowledgeActions(existing: [KnowledgeAppliedActionRecord]) -> [KnowledgeAppliedActionRecord] {
        let knowledgeRoot = knowledgeRootDirectory()
        let candidateDirectories = [
            (knowledgeRoot as NSString).appendingPathComponent("Lessons"),
            (knowledgeRoot as NSString).appendingPathComponent("Topics")
        ]

        var byKey: [String: KnowledgeAppliedActionRecord] = [:]
        for record in existing {
            byKey[appliedActionKey(for: record)] = record
        }

        for directory in candidateDirectories where FileManager.default.fileExists(atPath: directory) {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for file in files where file.hasSuffix(".md") {
                let path = (directory as NSString).appendingPathComponent(file)
                guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                      let kind = detectedAppliedActionKind(from: content) else {
                    continue
                }
                let relativePath = relativeKnowledgePath(for: path)
                let key = appliedActionKey(kind: kind, relativePath: relativePath)
                guard byKey[key] == nil else { continue }
                let title = extractedTitle(from: content) ?? ((file as NSString).deletingPathExtension)
                let appliedAt = fileTimestamp(at: path)
                let backupPath = latestBackupPath(for: relativePath)
                byKey[key] = KnowledgeAppliedActionRecord(
                    id: KnowledgeAppliedActionRecord.stableID(kind: kind, applyTargetRelativePath: relativePath),
                    appliedAt: appliedAt,
                    kind: kind,
                    title: title,
                    sourceEntityId: nil,
                    applyTargetRelativePath: relativePath,
                    appliedPath: path,
                    backupPath: backupPath
                )

                if kind == .lessonRedirect {
                    let lessonRelativePath = "Lessons/\(file)"
                    let lessonKey = appliedActionKey(kind: .lessonPromotion, relativePath: lessonRelativePath)
                    guard byKey[lessonKey] == nil else { continue }

                    let lessonPath = (knowledgeRoot as NSString).appendingPathComponent(lessonRelativePath)
                    let lessonTitle = loadAppliedKnowledgeTitle(at: lessonPath) ?? title
                    let lessonAppliedAt = fileTimestamp(at: lessonPath)
                    let lessonBackupPath = latestBackupPath(for: lessonRelativePath)
                    byKey[lessonKey] = KnowledgeAppliedActionRecord(
                        id: KnowledgeAppliedActionRecord.stableID(
                            kind: .lessonPromotion,
                            applyTargetRelativePath: lessonRelativePath
                        ),
                        appliedAt: lessonAppliedAt,
                        kind: .lessonPromotion,
                        title: lessonTitle,
                        sourceEntityId: nil,
                        applyTargetRelativePath: lessonRelativePath,
                        appliedPath: lessonPath,
                        backupPath: lessonBackupPath
                    )
                }
            }
        }

        return byKey.values.sorted(by: compareAppliedActions)
    }

    func discoverKnowledgeMergeOverlays(
        existing: [KnowledgeMergeOverlayRecord],
        appliedActions: [KnowledgeAppliedActionRecord]
    ) -> [KnowledgeMergeOverlayRecord] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for action in appliedActions where action.kind == .redirect {
            guard FileManager.default.fileExists(atPath: action.appliedPath),
                  let markdown = try? String(contentsOfFile: action.appliedPath, encoding: .utf8),
                  let parsed = parseConsolidationRedirectStub(markdown, fallbackSourceTitle: action.title),
                  let targetEntity = loadKnowledgeEntity(
                    named: parsed.targetTitle,
                    constrainedToRelativePath: parsed.targetRelativePath
                  ) else {
                continue
            }

            let sourceEntity = loadKnowledgeEntity(named: parsed.sourceTitle)
            let overlay = discoveredMergeOverlayRecord(
                appliedAt: action.appliedAt,
                sourceTitle: parsed.sourceTitle,
                sourceAliases: parsed.sourceAliases,
                sourceOverview: parsed.sourceOverview,
                preservedSignals: parsed.preservedSignals,
                sourceEntity: sourceEntity,
                targetEntity: targetEntity,
                targetTitle: parsed.targetTitle,
                targetRelativePath: parsed.targetRelativePath
            )
            byId[overlay.id] = overlay
        }

        let mergeDirectory = (knowledgeDraftsDirectory() as NSString).appendingPathComponent("Apply/Merge")
        if FileManager.default.fileExists(atPath: mergeDirectory),
           let files = try? FileManager.default.contentsOfDirectory(atPath: mergeDirectory) {
            let appliedSourceTitles = Set(
                appliedActions.compactMap { action -> String? in
                    switch action.kind {
                    case .redirect, .mergeOverlay:
                        return action.title
                    default:
                        return nil
                    }
                }
            )

            for file in files where file.hasSuffix(".md") {
                let path = (mergeDirectory as NSString).appendingPathComponent(file)
                guard let markdown = try? String(contentsOfFile: path, encoding: .utf8),
                      let parsed = parseMergeDraft(markdown),
                      appliedSourceTitles.contains(parsed.sourceTitle),
                      let targetEntity = loadKnowledgeEntity(
                        named: parsed.targetTitle,
                        constrainedToRelativePath: parsed.targetRelativePath
                      ) else {
                    continue
                }

                let sourceEntity = loadKnowledgeEntity(named: parsed.sourceTitle)
                let overlay = discoveredMergeOverlayRecord(
                    appliedAt: appliedTimestamp(for: parsed.sourceTitle, from: appliedActions) ?? fileTimestamp(at: path),
                    sourceTitle: parsed.sourceTitle,
                    sourceAliases: sourceEntity.map(aliases(for:)) ?? [parsed.sourceTitle],
                    sourceOverview: parsed.sourceOverview,
                    preservedSignals: parsed.preservedSignals,
                    sourceEntity: sourceEntity,
                    targetEntity: targetEntity,
                    targetTitle: parsed.targetTitle,
                    targetRelativePath: parsed.targetRelativePath
                )
                byId[overlay.id] = overlay
            }
        }

        return deduplicatedMergeOverlays(Array(byId.values)).sorted(by: compareMergeOverlays)
    }

    func deleteKnowledgeNote(_ note: KnowledgeNoteRecord) throws {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        let folder = knowledgeFolderName(for: note.noteType)
        let directory = (knowledgeRoot as NSString).appendingPathComponent(folder)
        let slug = knowledgeSlug(for: note.title)
        let filePath = (directory as NSString).appendingPathComponent("\(slug).md")

        if FileManager.default.fileExists(atPath: filePath) {
            try FileManager.default.removeItem(atPath: filePath)
        }
    }

    func enqueueSummaryExport(_ summary: DailySummaryRecord, lastError: String? = nil) throws {
        let entityId = exportEntityId(for: summary)
        let payloadData = try encoder.encode(summary)
        guard let payloadJson = String(data: payloadData, encoding: .utf8) else {
            throw DatabaseError.executeFailed("Failed to encode export payload")
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let existing = try db.query("""
            SELECT id, retry_count
            FROM sync_queue
            WHERE job_type = ? AND entity_id = ?
              AND status IN ('pending', 'running', 'failed')
            ORDER BY id DESC
            LIMIT 1
        """, params: [.text("obsidian_export_summary"), .text(entityId)])

        if let row = existing.first,
           let id = row["id"]?.intValue {
            try db.execute("""
                UPDATE sync_queue
                SET payload_json = ?, status = 'pending', scheduled_at = ?, last_error = ?, finished_at = NULL
                WHERE id = ?
            """, params: [
                .text(payloadJson),
                .text(now),
                lastError.map { .text($0) } ?? .null,
                .integer(id)
            ])
        } else {
            try db.execute("""
                INSERT INTO sync_queue (job_type, entity_id, payload_json, status, retry_count, scheduled_at, last_error)
                VALUES (?, ?, ?, 'pending', 0, ?, ?)
            """, params: [
                .text("obsidian_export_summary"),
                .text(entityId),
                .text(payloadJson),
                .text(now),
                lastError.map { .text($0) } ?? .null
            ])
        }
    }

    @discardableResult
    func drainQueuedExports(limit: Int = 8) throws -> Int {
        let now = Date()
        let nowString = ISO8601DateFormatter().string(from: now)
        let rows = try db.query("""
            SELECT id, payload_json, retry_count
            FROM sync_queue
            WHERE job_type = ?
              AND status IN ('pending', 'failed')
              AND (scheduled_at IS NULL OR scheduled_at <= ?)
            ORDER BY id
            LIMIT ?
        """, params: [
            .text("obsidian_export_summary"),
            .text(nowString),
            .integer(Int64(limit))
        ])

        var exportedCount = 0
        for row in rows {
            guard let id = row["id"]?.intValue else { continue }
            let retryCount = Int(row["retry_count"]?.intValue ?? 0)

            try db.execute("""
                UPDATE sync_queue
                SET status = 'running', started_at = ?, last_error = NULL
                WHERE id = ?
            """, params: [.text(nowString), .integer(id)])

            do {
                guard let payloadJson = row["payload_json"]?.textValue,
                      let payloadData = payloadJson.data(using: .utf8) else {
                    throw DatabaseError.executeFailed("Missing export payload")
                }

                let summary = try decoder.decode(DailySummaryRecord.self, from: payloadData)
                _ = try exportDailyNote(summary: summary)

                try db.execute("""
                    UPDATE sync_queue
                    SET status = 'done', finished_at = ?, started_at = COALESCE(started_at, ?), last_error = NULL
                    WHERE id = ?
                """, params: [.text(nowString), .text(nowString), .integer(id)])
                exportedCount += 1
            } catch {
                let nextRetry = ISO8601DateFormatter().string(
                    from: now.addingTimeInterval(retryDelay(for: retryCount + 1))
                )
                try db.execute("""
                    UPDATE sync_queue
                    SET status = 'failed', retry_count = ?, scheduled_at = ?, finished_at = ?, last_error = ?
                    WHERE id = ?
                """, params: [
                    .integer(Int64(retryCount + 1)),
                    .text(nextRetry),
                    .text(nowString),
                    .text(error.localizedDescription),
                    .integer(id)
                ])
            }
        }

        return exportedCount
    }

    @discardableResult
    func cleanupSyncQueueHistory(
        doneOlderThanDays: Int = 7,
        failedOlderThanDays: Int = 30
    ) throws -> Int {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let doneCutoff = formatter.string(
            from: Calendar.current.date(byAdding: .day, value: -doneOlderThanDays, to: now) ?? now
        )
        let failedCutoff = formatter.string(
            from: Calendar.current.date(byAdding: .day, value: -failedOlderThanDays, to: now) ?? now
        )

        let doneRows = try db.query("""
            SELECT COUNT(*) as c
            FROM sync_queue
            WHERE status = 'done'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(doneCutoff)])
        let failedRows = try db.query("""
            SELECT COUNT(*) as c
            FROM sync_queue
            WHERE status = 'failed'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(failedCutoff)])
        let deletedCount = Int(doneRows.first?["c"]?.intValue ?? 0)
            + Int(failedRows.first?["c"]?.intValue ?? 0)

        try db.execute("""
            DELETE FROM sync_queue
            WHERE status = 'done'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(doneCutoff)])
        try db.execute("""
            DELETE FROM sync_queue
            WHERE status = 'failed'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(failedCutoff)])

        return deletedCount
    }

    static func formatDuration(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(String(format: "%02d", mins))m"
    }

    private func offsetDate(_ dateStr: String, by days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        guard let offset = Calendar.current.date(byAdding: .day, value: days, to: date) else { return dateStr }
        return formatter.string(from: offset)
    }

    private func formatTime(_ isoString: String) -> String {
        dateSupport.localTimeString(from: isoString)
    }

    private func noteTitle(for summary: DailySummaryRecord, metadata: SummaryWindowMetadata?) -> String {
        guard let metadata, metadata.isHourly,
              let windowStart = metadata.windowStart,
              let windowEnd = metadata.windowEnd else {
            return "Дневной лог — \(summary.date)"
        }

        return "Почасовой лог — \(dateSupport.localDateString(from: windowStart)) "
            + "\(dateSupport.localTimeString(from: windowStart))–\(dateSupport.localTimeString(from: windowEnd))"
    }

    private func noteFilename(for summary: DailySummaryRecord) -> String {
        if let metadata = summaryWindowMetadata(from: summary.contextSwitchesJson),
           metadata.isHourly,
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            return "\(dateSupport.localDateString(from: windowStart))_"
                + "\(dateSupport.localTimeString(from: windowStart).replacingOccurrences(of: ":", with: "-"))-"
                + "\(dateSupport.localTimeString(from: windowEnd).replacingOccurrences(of: ":", with: "-")).md"
        }

        let timeStamp = summary.generatedAt
            .flatMap(dateSupport.parseDateTime)
            .map { dateSupport.localTimeString(from: $0).replacingOccurrences(of: ":", with: "-") }
            ?? dateSupport.localTimeString(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(summary.date)_\(timeStamp).md"
    }

    private func exportEntityId(for summary: DailySummaryRecord) -> String {
        if let metadata = summaryWindowMetadata(from: summary.contextSwitchesJson),
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            return "\(summary.date)|\(dateSupport.isoString(from: windowStart))|\(dateSupport.isoString(from: windowEnd))"
        }

        return "\(summary.date)|daily"
    }

    private func summaryWindowMetadata(from json: String?) -> SummaryWindowMetadata? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let count = object["count"] as? Int
        let windowStart = (object["window_start"] as? String).flatMap(dateSupport.parseDateTime)
        let windowEnd = (object["window_end"] as? String).flatMap(dateSupport.parseDateTime)
        let mode = object["mode"] as? String
        return SummaryWindowMetadata(count: count, windowStart: windowStart, windowEnd: windowEnd, mode: mode)
    }

    private func retryDelay(for retryCount: Int) -> TimeInterval {
        let boundedRetryCount = min(max(retryCount, 1), 6)
        return Double(1 << boundedRetryCount) * 60
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

    private func threadStatusLabel(_ status: AdvisoryThreadStatus) -> String {
        switch status {
        case .active: return "active"
        case .stalled: return "stalled"
        case .parked: return "parked"
        case .resolved: return "resolved"
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

    private func knowledgeFolderName(for noteType: String) -> String {
        KnowledgeEntityType(rawValue: noteType)?.folderName ?? "Topics"
    }

    private func knowledgeDraftsDirectory() -> String {
        let knowledgeRoot = knowledgeRootDirectory()
        return (knowledgeRoot as NSString).appendingPathComponent("_drafts")
    }

    private func knowledgeRootDirectory() -> String {
        (vaultPath as NSString).appendingPathComponent("Knowledge")
    }

    private func appliedBackupDirectory() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = dateSupport.timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return (knowledgeDraftsDirectory() as NSString).appendingPathComponent("AppliedBackup/\(stamp)")
    }

    private func compareAppliedActions(_ lhs: KnowledgeAppliedActionRecord, _ rhs: KnowledgeAppliedActionRecord) -> Bool {
        if lhs.appliedAt != rhs.appliedAt {
            return lhs.appliedAt > rhs.appliedAt
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func compareReviewDecisions(_ lhs: KnowledgeReviewDecisionRecord, _ rhs: KnowledgeReviewDecisionRecord) -> Bool {
        if lhs.recordedAt != rhs.recordedAt {
            return (lhs.recordedAt ?? "") > (rhs.recordedAt ?? "")
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func actionVerb(for kind: KnowledgeAppliedActionKind) -> String {
        switch kind {
        case .lessonPromotion:
            return "повышено"
        case .lessonRedirect:
            return "перенаправлено"
        case .redirect:
            return "перенаправлено после консолидации"
        case .mergeOverlay:
            return "объединено"
        case .suppression:
            return "подавлено"
        }
    }

    private func compareMergeOverlays(_ lhs: KnowledgeMergeOverlayRecord, _ rhs: KnowledgeMergeOverlayRecord) -> Bool {
        if lhs.appliedAt != rhs.appliedAt {
            return lhs.appliedAt > rhs.appliedAt
        }
        return lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle) == .orderedAscending
    }

    private func deduplicatedMergeOverlays(
        _ overlays: [KnowledgeMergeOverlayRecord]
    ) -> [KnowledgeMergeOverlayRecord] {
        var bySemanticKey: [String: KnowledgeMergeOverlayRecord] = [:]
        for overlay in overlays {
            let key = "\(overlay.sourceTitle.lowercased())|\(overlay.targetRelativePath.lowercased())"
            guard let existing = bySemanticKey[key] else {
                bySemanticKey[key] = overlay
                continue
            }
            bySemanticKey[key] = preferredMergeOverlay(existing, overlay)
        }
        return Array(bySemanticKey.values)
    }

    private func preferredMergeOverlay(
        _ lhs: KnowledgeMergeOverlayRecord,
        _ rhs: KnowledgeMergeOverlayRecord
    ) -> KnowledgeMergeOverlayRecord {
        let lhsScore = mergeOverlayQualityScore(lhs)
        let rhsScore = mergeOverlayQualityScore(rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore ? lhs : rhs
        }
        if lhs.appliedAt != rhs.appliedAt {
            return lhs.appliedAt > rhs.appliedAt ? lhs : rhs
        }
        return lhs.id < rhs.id ? lhs : rhs
    }

    private func mergeOverlayQualityScore(_ overlay: KnowledgeMergeOverlayRecord) -> Int {
        var score = 0
        if !overlay.sourceEntityId.hasPrefix("merge-source|") {
            score += 10
        }
        score += overlay.sourceAliases.count * 2
        score += overlay.preservedSignals.count
        if let sourceOverview = overlay.sourceOverview,
           !sourceOverview.isEmpty {
            score += 3
        }
        return score
    }

    private func discoveredMergeOverlayRecord(
        appliedAt: String,
        sourceTitle: String,
        sourceAliases: [String],
        sourceOverview: String?,
        preservedSignals: [String],
        sourceEntity: KnowledgeEntityRecord?,
        targetEntity: KnowledgeEntityRecord,
        targetTitle: String,
        targetRelativePath: String
    ) -> KnowledgeMergeOverlayRecord {
        let mergedAliases = Array(
            Set((sourceEntity.map(aliases(for:)) ?? [sourceTitle]) + sourceAliases + [sourceTitle])
        ).sorted()
        let sourceEntityId = sourceEntity?.id ?? syntheticMergeSourceEntityID(for: sourceTitle)
        return KnowledgeMergeOverlayRecord(
            appliedAt: appliedAt,
            sourceEntityId: sourceEntityId,
            sourceTitle: sourceTitle,
            sourceAliases: mergedAliases,
            sourceOverview: sourceOverview,
            preservedSignals: preservedSignals,
            targetEntityId: targetEntity.id,
            targetTitle: targetTitle,
            targetRelativePath: targetRelativePath
        )
    }

    private func detectedAppliedActionKind(from markdown: String) -> KnowledgeAppliedActionKind? {
        if markdown.contains("_Apply-ready lesson draft generated from a safe maintenance action._")
            || markdown.contains("_Готовый lesson draft, сгенерированный из safe maintenance action._")
            || markdown.contains("_Готовый черновик lesson, сгенерированный из safe maintenance action._")
            || markdown.contains("_Готовый черновик вывода, сгенерированный из безопасного maintenance-действия._") {
            return .lessonPromotion
        }
        if markdown.contains("_Redirect stub generated from a safe lesson-promotion action._")
            || markdown.contains("_Redirect stub, сгенерированный из safe lesson-promotion action._")
            || markdown.contains("_Редирект, сгенерированный из safe lesson-promotion action._")
            || markdown.contains("_Редирект, сгенерированный из безопасного действия повышения в вывод._") {
            return .lessonRedirect
        }
        if markdown.contains("_Redirect stub draft generated from a safe consolidation action._")
            || markdown.contains("_Redirect stub, сгенерированный из safe consolidation action._")
            || markdown.contains("_Редирект, сгенерированный из safe consolidation action._")
            || markdown.contains("_Редирект, сгенерированный из безопасного действия консолидации._") {
            return .redirect
        }
        return nil
    }

    private func parseMergeDraft(_ markdown: String) -> (
        sourceTitle: String,
        targetTitle: String,
        targetRelativePath: String,
        sourceOverview: String?,
        preservedSignals: [String]
    )? {
        guard let titleLine = markdown.components(separatedBy: .newlines).first(where: {
            $0.hasPrefix("# Merge Patch — ")
                || $0.hasPrefix("# Merge-патч — ")
                || $0.hasPrefix("# Патч слияния — ")
        }) else {
            return nil
        }
        let titlePayload: String
        if titleLine.hasPrefix("# Патч слияния — ") {
            titlePayload = String(titleLine.dropFirst("# Патч слияния — ".count))
        } else if titleLine.hasPrefix("# Merge-патч — ") {
            titlePayload = String(titleLine.dropFirst("# Merge-патч — ".count))
        } else {
            titlePayload = String(titleLine.dropFirst("# Merge Patch — ".count))
        }
        let titleParts = titlePayload.components(separatedBy: " → ")
        guard titleParts.count == 2 else { return nil }

        let sourceTitle = titleParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTitle = titleParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetRelativePath = targetRelativePath(from: markdown) else {
            return nil
        }

        let sourceOverview = extractFirstBullet(fromSection: "Сводка источника", markdown: markdown)
        let preservedSignals = extractBullets(fromSection: "Сигналы, которые нужно сохранить", markdown: markdown)

        return (
            sourceTitle: sourceTitle,
            targetTitle: targetTitle,
            targetRelativePath: targetRelativePath,
            sourceOverview: sourceOverview,
            preservedSignals: preservedSignals
        )
    }

    private func parseConsolidationRedirectStub(
        _ markdown: String,
        fallbackSourceTitle: String
    ) -> (
        sourceTitle: String,
        targetTitle: String,
        targetRelativePath: String,
        sourceOverview: String?,
        preservedSignals: [String],
        sourceAliases: [String]
    )? {
        guard markdown.contains("_Redirect stub draft generated from a safe consolidation action._")
                || markdown.contains("_Redirect stub, сгенерированный из safe consolidation action._")
                || markdown.contains("_Редирект, сгенерированный из safe consolidation action._")
                || markdown.contains("_Редирект, сгенерированный из безопасного действия консолидации._"),
              let targetLink = firstKnowledgeLink(in: markdown),
              let targetRelativePath = normalizedKnowledgeTarget(targetLink.target) else {
            return nil
        }
        let sourceTitle = extractedTitle(from: markdown) ?? fallbackSourceTitle
        let targetTitle = targetLink.label ?? ((targetRelativePath as NSString).deletingPathExtension as NSString).lastPathComponent
        let preservedSignals = extractBullets(fromSection: "Уникальный контекст, который надо сохранить", markdown: markdown)
        let aliases = extractBullets(fromSection: "След алиасов", markdown: markdown)

        return (
            sourceTitle: sourceTitle,
            targetTitle: targetTitle,
            targetRelativePath: targetRelativePath,
            sourceOverview: preservedSignals.first,
            preservedSignals: preservedSignals,
            sourceAliases: aliases
        )
    }

    private func extractedTitle(from markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func targetRelativePath(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        if let mergeIntentLine = lines.first(where: {
            ($0.contains("Fold [[Knowledge/") && $0.contains(" into [[Knowledge/"))
                || ($0.contains("Сложить [[Knowledge/") && $0.contains("]] в [[Knowledge/"))
        }),
           let target = knowledgeLinks(in: mergeIntentLine).last?.target {
            return normalizedKnowledgeTarget(target)
        }

        let allTargets = lines.flatMap(knowledgeLinks(in:)).map(\.target)
        if let target = allTargets.first,
           let normalized = normalizedKnowledgeTarget(target) {
            return normalized
        }
        return legacyTargetRelativePath(from: markdown)
    }

    private func firstKnowledgeLink(in markdown: String) -> (target: String, label: String?)? {
        for line in markdown.components(separatedBy: .newlines) {
            if let link = knowledgeLinks(in: line).first,
               normalizedKnowledgeTarget(link.target) != nil {
                return link
            }
        }
        return nil
    }

    private func knowledgeLinks(in line: String) -> [(target: String, label: String?)] {
        var targets: [(target: String, label: String?)] = []
        var searchRange = line.startIndex..<line.endIndex
        while let startRange = line.range(of: "[[Knowledge/", options: [], range: searchRange) {
            let suffix = line[startRange.upperBound...]
            guard let closing = suffix.firstIndex(of: "]") else { break }
            let token = String(suffix[..<closing])
            let parts = token.components(separatedBy: "|")
            let linkTarget = parts.first ?? token
            let label = parts.count > 1 ? parts[1] : nil
            targets.append((linkTarget, label))
            searchRange = closing..<line.endIndex
        }
        return targets
    }

    private func normalizedKnowledgeTarget(_ target: String) -> String? {
        guard target.hasPrefix("Topics/") || target.hasPrefix("Lessons/") || target.hasPrefix("Projects/") ||
                target.hasPrefix("Tools/") || target.hasPrefix("Models/") || target.hasPrefix("Issues/") else {
            return nil
        }
        return target.hasSuffix(".md") ? target : "\(target).md"
    }

    private func legacyTargetRelativePath(from markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            guard let range = line.range(of: "[[Knowledge/") else { continue }
            let suffix = line[range.upperBound...]
            guard let closing = suffix.firstIndex(of: "]") else { continue }
            let token = String(suffix[..<closing])
            let linkTarget = token.components(separatedBy: "|").first ?? token
            guard linkTarget.hasPrefix("Topics/") || linkTarget.hasPrefix("Lessons/") || linkTarget.hasPrefix("Projects/") ||
                    linkTarget.hasPrefix("Tools/") || linkTarget.hasPrefix("Models/") || linkTarget.hasPrefix("Issues/") else {
                continue
            }
            return linkTarget.hasSuffix(".md") ? linkTarget : "\(linkTarget).md"
        }
        return nil
    }

    private func extractFirstBullet(fromSection title: String, markdown: String) -> String? {
        extractBullets(fromSection: title, markdown: markdown).first
    }

    private func extractBullets(fromSection title: String, markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: .newlines)
        let variants = localizedSectionHeadingVariants(for: title)
        guard let sectionIndex = lines.firstIndex(where: { variants.contains($0) }) else { return [] }
        var bullets: [String] = []
        for line in lines[(sectionIndex + 1)...] {
            if line.hasPrefix("## ") {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("- ") {
                bullets.append(String(trimmed.dropFirst(2)))
            }
        }
        return bullets
    }

    private func localizedSectionHeadingVariants(for title: String) -> Set<String> {
        switch title {
        case "Сводка источника":
            return ["## Сводка источника", "## Source Summary"]
        case "Сигналы, которые нужно сохранить":
            return ["## Сигналы, которые нужно сохранить", "## Signals To Preserve"]
        case "Уникальный контекст, который надо сохранить":
            return ["## Уникальный контекст, который надо сохранить", "## Unique Context To Preserve"]
        case "След алиасов":
            return ["## След алиасов", "## Alias Trail"]
        default:
            return ["## \(title)"]
        }
    }

    private func appliedTimestamp(
        for sourceTitle: String,
        from appliedActions: [KnowledgeAppliedActionRecord]
    ) -> String? {
        appliedActions
            .filter { $0.title == sourceTitle || $0.targetTitle == sourceTitle }
            .map(\.appliedAt)
            .max()
    }

    private func syntheticMergeSourceEntityID(for sourceTitle: String) -> String {
        "merge-source|\(knowledgeSlug(for: sourceTitle))"
    }

    private func loadKnowledgeEntity(named canonicalName: String) -> KnowledgeEntityRecord? {
        let rows = try? db.query("""
            SELECT *
            FROM knowledge_entities
            WHERE canonical_name = ?
            LIMIT 1
        """, params: [.text(canonicalName)])
        return rows?.first.flatMap(KnowledgeEntityRecord.init(row:))
    }

    private func loadKnowledgeEntity(
        named canonicalName: String,
        constrainedToRelativePath relativePath: String
    ) -> KnowledgeEntityRecord? {
        let folder = (relativePath as NSString).pathComponents.first ?? ""
        let entityType: KnowledgeEntityType? = {
            switch folder {
            case "Projects": return .project
            case "Tools": return .tool
            case "Models": return .model
            case "Topics": return .topic
            case "Issues": return .issue
            case "Lessons": return .lesson
            default: return nil
            }
        }()

        let params: [SQLiteValue] = [
            .text(canonicalName),
            entityType.map { .text($0.rawValue) } ?? .null
        ]
        let rows = try? db.query("""
            SELECT *
            FROM knowledge_entities
            WHERE canonical_name = ?
              AND (? IS NULL OR entity_type = ?)
            LIMIT 1
        """, params: params + [entityType.map { .text($0.rawValue) } ?? .null])
        return rows?.first.flatMap(KnowledgeEntityRecord.init(row:))
    }

    private func aliases(for entity: KnowledgeEntityRecord) -> [String] {
        guard let aliasesJson = entity.aliasesJson,
              let data = aliasesJson.data(using: .utf8),
              let aliases = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(entity.canonicalName) != .orderedSame }
            .sorted()
    }

    private func loadAppliedKnowledgeTitle(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let markdown = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return extractedTitle(from: markdown)
    }

    private func relativeKnowledgePath(for absolutePath: String) -> String {
        let knowledgeRoot = knowledgeRootDirectory() + "/"
        if absolutePath.hasPrefix(knowledgeRoot) {
            return String(absolutePath.dropFirst(knowledgeRoot.count))
        }
        return (absolutePath as NSString).lastPathComponent
    }

    private func fileTimestamp(at path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let date = attributes?[.modificationDate] as? Date ?? Date()
        return dateSupport.isoString(from: date)
    }

    private func latestBackupPath(for relativePath: String) -> String? {
        let backupRoot = (knowledgeDraftsDirectory() as NSString).appendingPathComponent("AppliedBackup")
        guard FileManager.default.fileExists(atPath: backupRoot),
              let directories = try? FileManager.default.contentsOfDirectory(atPath: backupRoot) else {
            return nil
        }

        for directory in directories.sorted(by: >) {
            let candidate = (backupRoot as NSString).appendingPathComponent(directory)
            let path = (candidate as NSString).appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func mergedDraftMarkdownPreservingReviewDecision(
        for artifact: KnowledgeDraftArtifact,
        existingPath: String
    ) -> String {
        guard artifact.kind == .reviewDraft,
              artifact.reviewDecisionKind != nil,
              FileManager.default.fileExists(atPath: existingPath),
              let existing = try? String(contentsOfFile: existingPath, encoding: .utf8),
              let status = extractReviewDecisionStatus(from: existing) else {
            return artifact.markdown
        }

        return applyReviewDecisionStatus(status, to: artifact.markdown)
    }

    private func extractReviewDecisionStatus(from markdown: String) -> KnowledgeReviewDecisionStatus? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("decision:") else { continue }
            let rawValue = trimmed.dropFirst("Decision:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return KnowledgeReviewDecisionStatus(rawValue: rawValue.lowercased())
        }
        return nil
    }

    private func applyReviewDecisionStatus(
        _ status: KnowledgeReviewDecisionStatus,
        to markdown: String
    ) -> String {
        let replacement = "Decision: \(status.rawValue)"
        let lines = markdown.components(separatedBy: .newlines)
        var updated: [String] = []
        var replaced = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !replaced, trimmed.lowercased().hasPrefix("decision:") {
                updated.append(replacement)
                replaced = true
            } else {
                updated.append(line)
            }
        }
        if !replaced {
            updated.append(replacement)
        }
        return updated.joined(separator: "\n")
    }

    private func archiveResolvedReviewDraftIfNeeded(
        at path: String,
        relativePath: String,
        draftsRoot: String
    ) -> String? {
        guard relativePath.hasPrefix("Review/"),
              let markdown = try? String(contentsOfFile: path, encoding: .utf8),
              let status = extractReviewDecisionStatus(from: markdown),
              status != .pending else {
            return nil
        }

        let resolvedRoot = (draftsRoot as NSString).appendingPathComponent("ReviewResolved")
        let destinationPath = (resolvedRoot as NSString).appendingPathComponent((relativePath as NSString).lastPathComponent)
        try? FileManager.default.createDirectory(atPath: resolvedRoot, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationPath) {
            try? FileManager.default.removeItem(atPath: destinationPath)
        }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destinationPath)
            return destinationPath
        } catch {
            logger.error("Failed to archive resolved review draft at \(path): \(error.localizedDescription)")
            return nil
        }
    }

    private func reviewDecisionLinkTarget(for record: KnowledgeReviewDecisionRecord) -> String {
        if let range = record.path.range(of: "/Knowledge/_drafts/") {
            let relative = String(record.path[range.upperBound...]).replacingOccurrences(of: ".md", with: "")
            return "Knowledge/_drafts/\(relative)"
        }
        let draftName = ((record.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return "Knowledge/_drafts/Review/\(draftName)"
    }

    private func reviewMetadataValue(named key: String, in markdown: String) -> String? {
        let prefix = "<!-- \(key): "
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(" -->") else { continue }
            return String(trimmed.dropFirst(prefix.count).dropLast(4))
        }
        return nil
    }

    private func fileModificationISODate(at path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return dateSupport.isoString(from: modifiedAt)
    }

    private func appliedActionKey(kind: KnowledgeAppliedActionKind, relativePath: String) -> String {
        "\(kind.rawValue)|\(relativePath)"
    }

    private func appliedActionKey(for record: KnowledgeAppliedActionRecord) -> String {
        if record.kind == .mergeOverlay {
            return record.id
        }
        return appliedActionKey(kind: record.kind, relativePath: record.applyTargetRelativePath)
    }

    private func pruneEmptyDraftDirectories(under root: String) {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let directories = enumerator.compactMap { element -> URL? in
            guard let url = element as? URL else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true ? url : nil
        }.sorted { lhs, rhs in
            lhs.path.count > rhs.path.count
        }

        for directory in directories {
            guard directory.path != root else { continue }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func knowledgeSlug(for title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "note" : collapsed
    }

    private func stripTopHeading(from markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n")
        guard let first = lines.first,
              first.hasPrefix("# ") else {
            return trimmed + "\n"
        }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func richStructuredBody(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("# Daily Log —")
            || trimmed.hasPrefix("# Hourly Log —")
            || trimmed.hasPrefix("# Дневной лог —")
            || trimmed.hasPrefix("# Почасовой лог —") {
            return trimmed
        }

        if trimmed.contains("## Детальный таймлайн") && trimmed.contains("## Проекты и код") {
            return trimmed
        }

        return nil
    }
}
