import AppKit
import Foundation
import os

final class OCRPipeline {
    private let provider: any OCRProvider
    private let db: DatabaseManager
    nonisolated(unsafe) private let logger = Logger.ocr

    init(provider: any OCRProvider, db: DatabaseManager) {
        self.provider = provider
        self.db = db
    }

    /// Runs OCR on the given image for the specified capture and session.
    /// - Parameters:
    ///   - image: The image to process.
    ///   - captureId: The ID of the capture record this OCR belongs to.
    ///   - sessionId: The ID of the session the capture belongs to.
    ///   - previousHash: Optional hash of the previous OCR result for duplicate detection.
    /// - Returns: A persisted `OCRSnapshotRecord`.
    func process(
        image: NSImage,
        captureId: String,
        sessionId: String,
        previousHash: String? = nil
    ) async throws -> OCRSnapshotRecord {
        let ocrResult = try await provider.recognizeText(in: image)

        let normalizedText = TextNormalizer.normalize(ocrResult.rawText)
        let textHash: String? = normalizedText.map { TextNormalizer.hash($0) }

        let extractionStatus: String
        if normalizedText == nil || normalizedText?.isEmpty == true {
            extractionStatus = "empty"
        } else if ocrResult.confidence < 0.3 {
            extractionStatus = "low_confidence"
        } else if let hash = textHash, let prevHash = previousHash, hash == prevHash {
            extractionStatus = "duplicate"
        } else {
            extractionStatus = "success"
        }

        let id = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let record = OCRSnapshotRecord(
            id: id,
            sessionId: sessionId,
            captureId: captureId,
            timestamp: timestamp,
            provider: provider.name,
            rawText: ocrResult.rawText.isEmpty ? nil : ocrResult.rawText,
            normalizedText: normalizedText,
            textHash: textHash,
            confidence: ocrResult.confidence,
            language: ocrResult.language,
            processingMs: ocrResult.processingMs,
            extractionStatus: extractionStatus
        )

        try persist(record)

        logger.info("OCR snapshot \(id) saved: status=\(extractionStatus) confidence=\(ocrResult.confidence)")

        return record
    }

    // MARK: - Private

    private func persist(_ record: OCRSnapshotRecord) throws {
        try db.execute(
            """
            INSERT INTO ocr_snapshots
                (id, session_id, capture_id, timestamp, provider,
                 raw_text, normalized_text, text_hash,
                 confidence, language, processing_ms, extraction_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            params: [
                .text(record.id),
                .text(record.sessionId),
                .text(record.captureId),
                .text(record.timestamp),
                .text(record.provider),
                record.rawText.map { .text($0) } ?? .null,
                record.normalizedText.map { .text($0) } ?? .null,
                record.textHash.map { .text($0) } ?? .null,
                .real(record.confidence),
                record.language.map { .text($0) } ?? .null,
                record.processingMs.map { .integer(Int64($0)) } ?? .null,
                record.extractionStatus.map { .text($0) } ?? .null
            ]
        )
    }
}
