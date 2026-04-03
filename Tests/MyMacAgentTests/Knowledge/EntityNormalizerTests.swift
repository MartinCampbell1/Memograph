import Testing
@testable import MyMacAgent

struct EntityNormalizerTests {
    @Test("Strips explanatory suffix from lessons")
    func stripsExplanatorySuffixFromLessons() {
        let normalizer = EntityNormalizer()
        let entity = normalizer.normalize(
            rawName: "Three-Layer Knowledge Base Architecture — детальное описание слоев Raw, Claims и Wiki",
            typeHint: .lesson
        )

        #expect(entity?.canonicalName == "Three-Layer Knowledge Base Architecture")
        #expect(entity?.entityType == .lesson)
    }

    @Test("Canonical phrase map expands compact duplicate titles")
    func canonicalPhraseMapExpandsCompactTitles() {
        let normalizer = EntityNormalizer()
        let entity = normalizer.normalize(
            rawName: "Three-Layer KB",
            typeHint: .topic
        )

        #expect(entity?.canonicalName == "Three-Layer Knowledge Base Architecture")
        #expect(entity?.entityType == .topic)
    }

    @Test("Keeps project aliases mapped to Memograph")
    func keepsProjectAliasesMapped() {
        let normalizer = EntityNormalizer()
        let entity = normalizer.normalize(rawName: "MyMacAgent")

        #expect(entity?.canonicalName == "Memograph")
        #expect(entity?.entityType == .project)
    }

    @Test("Treats roadmap and benchmark titles as lessons before model keywords")
    func classifiesLessonSignalsBeforeModelKeywords() {
        let normalizer = EntityNormalizer()
        let lesson = normalizer.normalize(rawName: "Gemini 3 Flash Preview Benchmarks")
        let roadmap = normalizer.normalize(rawName: "Memograph Open Source Roadmap")

        #expect(lesson?.entityType == .lesson)
        #expect(roadmap?.entityType == .lesson)
    }

    @Test("Maps Claude desktop variants to tool instead of model")
    func mapsClaudeDesktopVariantsToTool() {
        let normalizer = EntityNormalizer()
        let entity = normalizer.normalize(rawName: "Claude.app")

        #expect(entity?.canonicalName == "Claude")
        #expect(entity?.entityType == .tool)
    }

    @Test("Maps geminicode to project")
    func mapsGeminicodeToProject() {
        let normalizer = EntityNormalizer()
        let entity = normalizer.normalize(rawName: "geminicode")

        #expect(entity?.canonicalName == "geminicode")
        #expect(entity?.entityType == .project)
    }

    @Test("Removes app suffix and invisible markers from tool names")
    func canonicalizesAppSuffixAndInvisibleMarkers() {
        let normalizer = EntityNormalizer()
        let lmStudio = normalizer.normalize(rawName: "LM Studio.app")
        let whatsapp = normalizer.normalize(rawName: "\u{200E}WhatsApp")

        #expect(lmStudio?.canonicalName == "LM Studio")
        #expect(lmStudio?.entityType == .tool)
        #expect(whatsapp?.canonicalName == "WhatsApp")
        #expect(whatsapp?.entityType == .tool)
    }

    @Test("Canonicalizes known tool names instead of preserving raw app suffixes")
    func canonicalizesKnownToolNames() {
        let normalizer = EntityNormalizer()
        let entity = normalizer.normalize(
            rawName: "LM Studio.app",
            knownToolNames: ["LM Studio.app"]
        )

        #expect(entity?.canonicalName == "LM Studio")
        #expect(entity?.entityType == .tool)
    }

    @Test("Canonicalizes app store nonbreaking space variant")
    func canonicalizesAppStoreVariant() {
        let normalizer = EntityNormalizer()
        let entity = normalizer.normalize(
            rawName: "App\u{00A0}Store",
            knownToolNames: ["App\u{00A0}Store"]
        )

        #expect(entity?.canonicalName == "App Store")
        #expect(entity?.entityType == .tool)
    }

    @Test("Canonicalizes localized system app names into a consistent English layer")
    func canonicalizesLocalizedSystemApps() {
        let normalizer = EntityNormalizer()
        let terminal = normalizer.normalize(rawName: "Терминал")
        let settings = normalizer.normalize(rawName: "Системные настройки")
        let notes = normalizer.normalize(rawName: "Заметки")

        #expect(terminal?.canonicalName == "Terminal")
        #expect(terminal?.entityType == .tool)
        #expect(settings?.canonicalName == "System Settings")
        #expect(settings?.entityType == .tool)
        #expect(notes?.canonicalName == "Notes")
        #expect(notes?.entityType == .tool)
    }

    @Test("Canonicalizes decomposed Cyrillic variants for localized aliases")
    func canonicalizesDecomposedCyrillicVariants() {
        let normalizer = EntityNormalizer()
        let settings = normalizer.normalize(rawName: "Системные настрои\u{0306}ки")
        let accessibility = normalizer.normalize(rawName: "Универсальныи\u{0306} доступ")

        #expect(settings?.canonicalName == "System Settings")
        #expect(settings?.entityType == .tool)
        #expect(accessibility?.canonicalName == "Accessibility Permissions")
        #expect(accessibility?.entityType == .topic)
    }

    @Test("Canonicalizes localized permissions topics")
    func canonicalizesLocalizedPermissionTopics() {
        let normalizer = EntityNormalizer()
        let accessibility = normalizer.normalize(rawName: "Универсальный доступ")
        let privacy = normalizer.normalize(rawName: "Конфиденциальность и безопасность")

        #expect(accessibility?.canonicalName == "Accessibility Permissions")
        #expect(accessibility?.entityType == .topic)
        #expect(privacy?.canonicalName == "Privacy & Security")
        #expect(privacy?.entityType == .topic)
    }
}
