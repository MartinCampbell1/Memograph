import Foundation
import os

final class ContextFusionEngine {
    private let logger = Logger.fusion

    func fuse(
        sessionId: String, captureId: String?,
        appName: String, bundleId: String, windowTitle: String?,
        ax: AXSnapshotRecord?, ocr: OCRSnapshotRecord?,
        readableScore: Double, uncertaintyScore: Double
    ) -> ContextSnapshotRecord {
        let textSource: String
        let mergedText: String?
        let mergedTextHash: String?

        let axText = [ax?.focusedTitle, ax?.focusedValue, ax?.selectedText]
            .compactMap { $0 }
            .joined(separator: " ")
        let ocrText = ocr?.normalizedText

        switch (axText.isEmpty ? nil : axText, ocrText) {
        case let (ax?, ocr?):
            textSource = "ax+ocr"
            // Prefer OCR text as it's usually more complete, supplement with AX
            if ocr.contains(ax) || ax.count < 20 {
                mergedText = ocr
            } else {
                mergedText = ax + "\n---\n" + ocr
            }
        case let (ax?, nil):
            textSource = "ax"
            mergedText = ax
        case let (nil, ocr?):
            textSource = "ocr"
            mergedText = ocr
        case (nil, nil):
            textSource = "none"
            mergedText = nil
        }

        mergedTextHash = mergedText.map { TextNormalizer.hash($0) }

        let snapshot = ContextSnapshotRecord(
            id: UUID().uuidString,
            sessionId: sessionId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appName: appName, bundleId: bundleId, windowTitle: windowTitle,
            textSource: textSource, mergedText: mergedText,
            mergedTextHash: mergedTextHash, topicHint: nil,
            readableScore: readableScore, uncertaintyScore: uncertaintyScore,
            sourceCaptureId: captureId,
            sourceAxId: ax?.id, sourceOcrId: ocr?.id
        )

        logger.info("Context fused: source=\(textSource), readability=\(readableScore)")
        return snapshot
    }

    func persist(snapshot: ContextSnapshotRecord, db: DatabaseManager) throws {
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp,
                app_name, bundle_id, window_title, text_source,
                merged_text, merged_text_hash, topic_hint,
                readable_score, uncertainty_score,
                source_capture_id, source_ax_id, source_ocr_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(snapshot.id), .text(snapshot.sessionId), .text(snapshot.timestamp),
            snapshot.appName.map { .text($0) } ?? .null,
            snapshot.bundleId.map { .text($0) } ?? .null,
            snapshot.windowTitle.map { .text($0) } ?? .null,
            snapshot.textSource.map { .text($0) } ?? .null,
            snapshot.mergedText.map { .text($0) } ?? .null,
            snapshot.mergedTextHash.map { .text($0) } ?? .null,
            snapshot.topicHint.map { .text($0) } ?? .null,
            .real(snapshot.readableScore), .real(snapshot.uncertaintyScore),
            snapshot.sourceCaptureId.map { .text($0) } ?? .null,
            snapshot.sourceAxId.map { .text($0) } ?? .null,
            snapshot.sourceOcrId.map { .text($0) } ?? .null
        ])
    }
}
