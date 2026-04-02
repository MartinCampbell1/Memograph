import AppKit
import os

final class AccessibilityContextEngine {
    private let logger = Logger.accessibility

    // MARK: - Public API

    func extract(pid: pid_t, sessionId: String = "", captureId: String? = nil) -> AXSnapshotRecord? {
        let appRef = AXUIElementCreateApplication(pid)

        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )

        // Fall back to focused window if no focused element
        let element: AXUIElement
        if focusedResult == .success, let fe = focusedElement {
            element = fe as! AXUIElement
        } else {
            var focusedWindow: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(
                appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow
            )
            guard windowResult == .success, let fw = focusedWindow else {
                logger.info("No focused element or window for pid \(pid)")
                return AXSnapshotRecord(
                    id: UUID().uuidString, sessionId: sessionId, captureId: captureId,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    focusedRole: nil, focusedSubrole: nil,
                    focusedTitle: nil, focusedValue: nil, selectedText: nil,
                    textLen: 0, extractionStatus: "no_element"
                )
            }
            element = fw as! AXUIElement
        }

        let role = axStringAttribute(element, kAXRoleAttribute)
        let subrole = axStringAttribute(element, kAXSubroleAttribute)
        let title = axStringAttribute(element, kAXTitleAttribute)
        let value = axStringAttribute(element, kAXValueAttribute)
        let selectedText = axStringAttribute(element, kAXSelectedTextAttribute)
        let description = axStringAttribute(element, kAXDescriptionAttribute)

        let combinedValue = [value, description].compactMap { $0 }.joined(separator: " ")
        let textLen = [title, combinedValue, selectedText]
            .compactMap { $0 }
            .reduce(0) { $0 + $1.count }

        let status: String = textLen > 0 ? "success" : "empty"

        let snapshot = AXSnapshotRecord(
            id: UUID().uuidString, sessionId: sessionId, captureId: captureId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            focusedRole: role, focusedSubrole: subrole,
            focusedTitle: title,
            focusedValue: combinedValue.isEmpty ? nil : combinedValue,
            selectedText: selectedText,
            textLen: textLen, extractionStatus: status
        )

        logger.info("AX snapshot: role=\(role ?? "nil"), textLen=\(textLen), status=\(status)")
        return snapshot
    }

    func persist(snapshot: AXSnapshotRecord, db: DatabaseManager) throws {
        try db.execute("""
            INSERT INTO ax_snapshots (id, session_id, capture_id, timestamp,
                focused_role, focused_subrole, focused_title, focused_value,
                selected_text, text_len, extraction_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(snapshot.id),
            .text(snapshot.sessionId),
            snapshot.captureId.map { .text($0) } ?? .null,
            .text(snapshot.timestamp),
            snapshot.focusedRole.map { .text($0) } ?? .null,
            snapshot.focusedSubrole.map { .text($0) } ?? .null,
            snapshot.focusedTitle.map { .text($0) } ?? .null,
            snapshot.focusedValue.map { .text($0) } ?? .null,
            snapshot.selectedText.map { .text($0) } ?? .null,
            .integer(Int64(snapshot.textLen)),
            snapshot.extractionStatus.map { .text($0) } ?? .null
        ])
    }

    func extractAttributes(from pid: pid_t) -> [String: String]? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )
        guard result == .success, let element = focusedElement else { return nil }

        var attrs: [String: String] = [:]
        let axElement = element as! AXUIElement

        for attr in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                     kAXValueAttribute, kAXDescriptionAttribute, kAXSelectedTextAttribute] {
            if let value = axStringAttribute(axElement, attr) {
                attrs[attr as String] = value
            }
        }
        return attrs.isEmpty ? nil : attrs
    }

    // MARK: - Private

    private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }
}
