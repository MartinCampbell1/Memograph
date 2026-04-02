Да. Ниже — **инженерный пакет ТЗ** под разработку.

Сразу учёл твою правку:
**если программа не может вытащить текст через Accessibility / OCR / структуру окна, частота визуальных сэмплов должна повышаться**.
Но я заложу это **адаптивно**, а не тупо “всегда каждые 3 секунды”, потому что иначе можно убить батарею, диск и CPU. Правильнее так:

* **обычный режим** — редкие сэмплы
* **degraded mode** для “нечитаемых” окон — чаще
* **high-uncertainty mode** — очень часто, вплоть до **1–3 секунд**
* с автооткатом обратно, когда текст снова стал извлекаемым

Это даёт тебе именно то, что ты хочешь: если система “слепая”, она начинает смотреть чаще.

---

# Инженерный пакет ТЗ

## Проект: macOS-приложение для автологирования дня, OCR, AI-summary и экспорта в базу знаний

---

# 1. Продуктовая цель

Собрать **нативное macOS-приложение**, которое:

* отслеживает активные приложения и окна;
* делает визуальные сэмплы активного окна/экрана;
* извлекает текст через Accessibility и локальный OCR;
* строит таймлайн дня;
* формирует AI-сводки;
* сохраняет знания в локальную БД;
* экспортирует результат в Obsidian и опционально в Notion.

---

# 2. Границы MVP и v1

## MVP

Минимальная рабочая версия должна:

* отслеживать active app / active window;
* снимать скрины активного окна;
* запускать OCR локально;
* собирать таймлайн;
* генерировать дневной summary;
* экспортировать daily note в Obsidian.

## v1 Full

Полная первая версия должна дополнительно:

* иметь адаптивную частоту захвата;
* различать readable / unreadable / high-uncertainty окна;
* иметь очереди фоновых задач;
* сохранять OCR confidence и uncertainty score;
* иметь экран истории и фильтры;
* поддерживать Notion export;
* иметь rules engine для AI-чатов, браузеров, IDE и документов.

---

# 3. Архитектура системы

## 3.1 Верхнеуровневая схема

```text
[App/Window Monitor]
        |
        v
[Session Manager] ---> [Capture Policy Engine] ---> [Screen Capture Engine]
        |                                           |
        |                                           v
        |                                   [Image Preprocessor]
        |                                           |
        v                                           v
[Accessibility Context Engine]                [OCR Engine]
        |                                           |
        +-------------------> [Context Fusion Engine] <-------------------+
                                      |                                   |
                                      v                                   |
                               [Storage / Local DB]                       |
                                      |                                   |
                                      +------> [Summarization Engine] ----+
                                      |
                                      +------> [Knowledge Export Engine]
                                      |
                                      +------> [Timeline / UI]
```

---

# 4. Технологический стек

## 4.1 Язык и UI

* **Swift**
* **SwiftUI**
* точечно **AppKit**, если нужно для системных интеграций

## 4.2 Системные API

* `NSWorkspace` — active app / app switch / workspace events
* `ScreenCaptureKit` — захват окна/экрана
* `Accessibility API / AXUIElement` — UI context
* `Vision` можно использовать опционально как системный OCR fallback, если решишь не тащить только внешнюю OCR-модель

## 4.3 OCR

Базово проектируем так, чтобы OCR был **плагинным**:

### Вариант A

* локальный сервис OCR через **Ollama + GLM-OCR**

### Вариант B

* локальный OCR через отдельный Python/CLI worker

### Вариант C

* Apple Vision OCR как fallback

Лучше сделать **абстракцию OCRProvider**, чтобы потом менять движок без переписывания приложения.

## 4.4 БД

Рекомендация:

* **SQLite** как основной storage
* через лёгкий data access layer
* без Core Data на старте, чтобы было проще контролировать схему и миграции

## 4.5 Export / integration

* Obsidian: запись `.md` файлов + assets
* Notion: REST integration later
* AI summary: OpenRouter / OpenAI-compatible HTTP client

---

# 5. Основные модули

## 5.1 AppMonitor

Отвечает за:

* активное приложение
* bundle id
* process id
* launch / terminate
* app switch events

## 5.2 WindowMonitor

Отвечает за:

* заголовок активного окна
* window identity
* изменение активного окна
* попытку получить метаданные окна

## 5.3 SessionManager

Отвечает за:

* старт/стоп пользовательских сессий
* объединение событий в рабочие блоки
* idle detection
* closing / flushing sessions

## 5.4 CapturePolicyEngine

Сердце логики “как часто снимать”.

Принимает решение:

* нужен ли скрин
* нужен ли OCR
* нужен ли accessibility snapshot
* какой sampling mode сейчас включён

## 5.5 ScreenCaptureEngine

Отвечает за:

* захват активного окна
* fallback на активный экран
* сжатие изображения
* отдачу image blob в pipeline

## 5.6 AccessibilityContextEngine

Пытается вытащить:

* title
* role / subrole
* focused element
* selected text
* value/description
* прочие полезные AX-атрибуты

## 5.7 OCRPipeline

Выполняет:

* pre-processing
* OCR request
* normalization
* confidence scoring
* deduplication

## 5.8 ContextFusionEngine

Склеивает:

* app metadata
* window metadata
* accessibility text
* OCR text
* visual hashes
* session data

И строит единый **ContextSnapshot**.

## 5.9 SummarizationEngine

Готовит:

* session summaries
* daily summaries
* topic extraction
* distraction/context-switch patterns
* suggested notes

## 5.10 KnowledgeExportEngine

Экспортирует:

* daily note
* topic note
* session note
* weekly digest
* attachments

## 5.11 RulesEngine

Содержит правила:

* какие приложения исключать
* где нельзя делать OCR
* где делать частые скрины
* где текст считается unreadable
* AI-chat classifiers
* browser/document/IDE heuristics

## 5.12 Settings / Permissions Manager

Управляет:

* screen recording permission
* accessibility permission
* model settings
* OCR backend
* sampling modes
* privacy rules

---

# 6. Режимы захвата

## 6.1 Normal mode

Когда текст извлекается нормально.

Частоты:

* на входе в окно: 1 скрин
* через 10–15 сек: 1 повторный
* далее: раз в 30–90 сек
* OCR: по необходимости

## 6.2 Degraded mode

Когда текст извлекается плохо.

Частоты:

* 1 скрин на входе
* далее каждые 8–15 сек
* OCR чаще
* если 2–3 подряд OCR-попытки слабые, режим может перейти в high-uncertainty

## 6.3 High-uncertainty mode

Когда:

* Accessibility пустой
* OCR плохой
* окно сильно меняется
* визуально видно, что пользователь читает/работает
* но текст не извлекается

Частоты:

* каждые **1–3 секунды**
* по умолчанию рекомендую **3 сек**
* для конкретных приложений можно разрешить **1–2 сек**, но только ограниченными окнами

Это и есть твоя правка.

## 6.4 Recovery mode

Когда текст снова начал извлекаться:

* частота постепенно снижается
* сначала до 8–15 сек
* потом до normal mode

---

# 7. Правила повышения частоты скринов

## 7.1 Условия перехода в high-uncertainty mode

Если одновременно выполняются 2+ условий:

* `ocr_confidence < threshold_low`
* `ax_text_len == 0`
* `window_changed_visually == true`
* `active_duration > N sec`
* `user_input_activity_detected == true`
* `content_type in [canvas-like, remote app, image-heavy, protected UI]`

## 7.2 Политика частоты

Предлагаю в ТЗ прямо записать:

### По умолчанию

* high-uncertainty sampling interval = **3 sec**

### Опционально

* aggressive unreadable mode = **1 sec**

### Ограничения

* не более X минут подряд в aggressive mode
* не более Y снимков на сессию без компрессии
* если окно статично, частота снижается даже в unreadable mode

## 7.3 Умная коррекция

Если кадры почти одинаковые:

* не запускать OCR каждый раз
* можно делать visual diff/hash
* сохранять не все изображения, а только дельты или опорные кадры

---

# 8. Сущности и таблицы БД

Ниже даю уже почти готовую схему.

---

## 8.1 apps

```sql
CREATE TABLE apps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bundle_id TEXT UNIQUE,
    app_name TEXT NOT NULL,
    category TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

---

## 8.2 windows

```sql
CREATE TABLE windows (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id INTEGER NOT NULL,
    window_title TEXT,
    window_role TEXT,
    first_seen_at DATETIME,
    last_seen_at DATETIME,
    fingerprint TEXT,
    FOREIGN KEY (app_id) REFERENCES apps(id)
);
```

---

## 8.3 sessions

```sql
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL,
    window_id INTEGER,
    session_type TEXT,
    started_at DATETIME NOT NULL,
    ended_at DATETIME,
    active_duration_ms INTEGER DEFAULT 0,
    idle_duration_ms INTEGER DEFAULT 0,
    confidence_score REAL DEFAULT 0,
    uncertainty_mode TEXT DEFAULT 'normal',
    top_topic TEXT,
    is_ai_related INTEGER DEFAULT 0,
    summary_status TEXT DEFAULT 'pending',
    FOREIGN KEY (app_id) REFERENCES apps(id),
    FOREIGN KEY (window_id) REFERENCES windows(id)
);
```

---

## 8.4 session_events

```sql
CREATE TABLE session_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    payload_json TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id)
);
```

Типы событий:

* app_activated
* window_changed
* capture_taken
* ocr_requested
* ocr_completed
* ax_snapshot_taken
* mode_changed
* summary_generated
* export_completed
* idle_started
* idle_ended

---

## 8.5 captures

```sql
CREATE TABLE captures (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    capture_type TEXT NOT NULL,
    image_path TEXT,
    thumb_path TEXT,
    width INTEGER,
    height INTEGER,
    file_size_bytes INTEGER,
    visual_hash TEXT,
    perceptual_hash TEXT,
    diff_score REAL DEFAULT 0,
    sampling_mode TEXT,
    retained INTEGER DEFAULT 1,
    FOREIGN KEY (session_id) REFERENCES sessions(id)
);
```

---

## 8.6 ax_snapshots

```sql
CREATE TABLE ax_snapshots (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    capture_id TEXT,
    timestamp DATETIME NOT NULL,
    focused_role TEXT,
    focused_subrole TEXT,
    focused_title TEXT,
    focused_value TEXT,
    selected_text TEXT,
    text_len INTEGER DEFAULT 0,
    extraction_status TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    FOREIGN KEY (capture_id) REFERENCES captures(id)
);
```

---

## 8.7 ocr_snapshots

```sql
CREATE TABLE ocr_snapshots (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    capture_id TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    provider TEXT NOT NULL,
    raw_text TEXT,
    normalized_text TEXT,
    text_hash TEXT,
    confidence REAL DEFAULT 0,
    language TEXT,
    processing_ms INTEGER,
    extraction_status TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    FOREIGN KEY (capture_id) REFERENCES captures(id)
);
```

---

## 8.8 context_snapshots

```sql
CREATE TABLE context_snapshots (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    app_name TEXT,
    bundle_id TEXT,
    window_title TEXT,
    text_source TEXT,
    merged_text TEXT,
    merged_text_hash TEXT,
    topic_hint TEXT,
    readable_score REAL DEFAULT 0,
    uncertainty_score REAL DEFAULT 0,
    source_capture_id TEXT,
    source_ax_id TEXT,
    source_ocr_id TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id)
);
```

---

## 8.9 daily_summaries

```sql
CREATE TABLE daily_summaries (
    date TEXT PRIMARY KEY,
    summary_text TEXT,
    top_apps_json TEXT,
    top_topics_json TEXT,
    ai_sessions_json TEXT,
    context_switches_json TEXT,
    unfinished_items_json TEXT,
    suggested_notes_json TEXT,
    generated_at DATETIME,
    model_name TEXT,
    token_usage_input INTEGER DEFAULT 0,
    token_usage_output INTEGER DEFAULT 0,
    generation_status TEXT
);
```

---

## 8.10 knowledge_notes

```sql
CREATE TABLE knowledge_notes (
    id TEXT PRIMARY KEY,
    note_type TEXT NOT NULL,
    title TEXT NOT NULL,
    body_markdown TEXT NOT NULL,
    source_date TEXT,
    tags_json TEXT,
    links_json TEXT,
    export_obsidian_status TEXT DEFAULT 'pending',
    export_notion_status TEXT DEFAULT 'pending',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

---

## 8.11 app_rules

```sql
CREATE TABLE app_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bundle_id TEXT,
    rule_type TEXT NOT NULL,
    rule_value TEXT NOT NULL,
    enabled INTEGER DEFAULT 1
);
```

Примеры:

* exclude_capture
* exclude_ocr
* high_frequency_capture
* metadata_only
* privacy_mask
* ai_chat_hint

---

## 8.12 sync_queue

```sql
CREATE TABLE sync_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_type TEXT NOT NULL,
    entity_id TEXT,
    payload_json TEXT,
    status TEXT DEFAULT 'pending',
    retry_count INTEGER DEFAULT 0,
    scheduled_at DATETIME,
    started_at DATETIME,
    finished_at DATETIME,
    last_error TEXT
);
```

---

# 9. Очереди задач

Нужно явно разделить realtime и background.

## 9.1 RealtimeQueue

Высокий приоритет.

Задачи:

* app switch events
* window change events
* session start/stop
* capture scheduling decisions

Требование:

* не блокировать UI
* минимальные операции

## 9.2 CaptureQueue

Средний приоритет.

Задачи:

* захват окна
* сжатие изображения
* миниатюры
* hash / diff

## 9.3 OCRQueue

Средний/низкий приоритет.

Задачи:

* OCR по изображению
* нормализация текста
* confidence scoring

Особое правило:

* concurrency limit = 1–2
* если OCR backlog растёт, sampling policy должна деградировать и не создавать лавину

## 9.4 FusionQueue

Низкий/средний приоритет.

Задачи:

* склейка AX + OCR + metadata
* создание context snapshots
* dedup

## 9.5 SummaryQueue

Низкий приоритет.

Задачи:

* session summary
* daily summary
* topic extraction
* note suggestion

## 9.6 ExportQueue

Низкий приоритет.

Задачи:

* markdown export
* file assets export
* notion sync

---

# 10. Фоновые воркеры

## 10.1 SessionWorker

Постоянно слушает:

* активное приложение
* активное окно
* idle state

Создаёт/закрывает сессии.

## 10.2 CaptureSchedulerWorker

По событиям и по таймерам принимает решение:

* делать скрин или нет
* какой sampling mode сейчас включить

## 10.3 CaptureWorker

Делает:

* actual capture
* resize
* compress
* hashes

## 10.4 OCRWorker

Берёт capture из очереди:

* запускает OCR
* сохраняет результат
* выставляет confidence
* сигналит Policy Engine

## 10.5 AXWorker

Параллельно пытается снять accessibility context.

## 10.6 ContextFusionWorker

Склеивает результаты в единый снимок контекста.

## 10.7 SummaryWorker

По расписанию или по запросу:

* собирает сессии за день
* агрегирует
* отправляет в модель
* сохраняет summary и suggested notes

## 10.8 ExportWorker

Пишет:

* Obsidian markdown
* attachments
* optional Notion sync

## 10.9 RetentionWorker

Чистит:

* старые captures
* ненужные high-frequency кадры
* временные OCR blobs
* старые очереди

---

# 11. Логика принятия решений

## 11.1 Readability score

Нужно вычислять `readability_score` окна.

Формула может быть эвристической:

* есть AX text → +0.4
* OCR confidence высокий → +0.4
* текст длинный и осмысленный → +0.2
* частые изменения без текста → -0.3
* image-heavy / canvas-like content → -0.2

Итог:

* `> 0.7` → readable
* `0.3–0.7` → degraded
* `< 0.3` → unreadable/high-uncertainty

## 11.2 Uncertainty score

Учитывает:

* пустой текст
* низкий OCR confidence
* сильные визуальные изменения
* высокая активность пользователя
* отсутствие стабильного контекста

Если высокий, повышаем частоту захвата.

## 11.3 Visual change score

На основе:

* perceptual hash difference
* brightness/layout diff
* edge histogram diff

Если окно почти не меняется, можно:

* не сохранять каждый скрин
* не запускать OCR на каждый кадр

---

# 12. Политика скриншотов для unreadable страниц

Вот это я рекомендую прямо вставить в ТЗ почти дословно.

## 12.1 Требование

Если приложение или окно не позволяют достоверно извлечь контекст через Accessibility и OCR, система должна автоматически повышать частоту визуальных сэмплов для сохранения непрерывности контекста пользовательской деятельности.

## 12.2 Частоты

* normal readable mode: 30–90 сек
* degraded mode: 8–15 сек
* unreadable mode: 3 сек
* aggressive unreadable mode: 1–2 сек для явно важных/активных окон

## 12.3 Ограничение нагрузки

В unreadable mode:

* можно сохранять каждый N-й кадр полноценно
* промежуточные кадры использовать только для diff/decision
* OCR запускать не на каждый кадр, а на:

  * первый
  * каждый третий
  * или при значительном изменении

## 12.4 Примеры окон

High-frequency unreadable candidates:

* canvas-heavy web apps
* remote desktops
* custom chat UIs
* image/video editing contexts
* non-accessible proprietary desktop apps

---

# 13. Формат summary pipeline

## 13.1 Session summary input

На каждую сессию:

* app name
* window title
* duration
* text excerpts
* OCR excerpts
* top visual moments
* uncertainty/readability markers

## 13.2 Daily summary input

За день:

* grouped sessions
* durations
* app categories
* AI-related sessions
* extracted topics
* context switching stats
* notable unreadable sessions

## 13.3 Output

* summary paragraph
* bullet timeline
* top topics
* likely tasks
* distractions
* suggested notes
* tomorrow continuation

---

# 14. Формат экспорта в Obsidian

## 14.1 Daily note template

```md
# Daily Log — {{date}}

## Summary
...

## Main apps
- Chrome — 2h 14m
- Cursor — 1h 08m

## Main topics
- ...
- ...

## AI sessions
- ChatGPT: ...
- Claude: ...

## Timeline
- 09:10–09:32 — ...
- 09:35–10:20 — ...

## Unreadable / visually tracked sessions
- Remote app / canvas-like UI / OCR-poor window

## Suggested notes
- [[Topic 1]]
- [[Topic 2]]

## Continue tomorrow
- ...
```

## 14.2 Assets

* `/Assets/YYYY-MM-DD/...`
* thumbnails
* optional “important moments” only

---

# 15. Режимы хранения

## 15.1 Raw

Хранить всё.

Для отладки, не по умолчанию.

## 15.2 Balanced

Хранить:

* все summaries
* все context snapshots
* не все captures
* unreadable captures частично прореживать позже

## 15.3 Compact

Хранить:

* summaries
* ключевые snapshots
* ключевые OCR excerpts
* минимум изображений

---

# 16. Разработка по спринтам

## Sprint 0 — Project bootstrap

Цель:

* каркас приложения
* permissions onboarding
* SQLite setup
* logging infra
* basic settings

Результат:

* приложение запускается
* permissions screen работает
* БД подключена
* можно логировать app/window events

## Sprint 1 — App & window tracking

Цель:

* отслеживать active app/window
* создавать сессии
* фиксировать длительности
* idle detection

Результат:

* дневной таймлайн по приложениям уже есть

## Sprint 2 — Screen capture pipeline

Цель:

* подключить ScreenCaptureKit
* делать скрины активного окна
* compression + hashes
* сохранять captures

Результат:

* визуальные сэмплы уже пишутся

## Sprint 3 — Accessibility pipeline

Цель:

* AX snapshots
* focused element
* title/value extraction
* selected text where possible

Результат:

* readable окна начинают давать текст без OCR

## Sprint 4 — OCR pipeline

Цель:

* интеграция OCR provider
* OCR queue
* normalization
* confidence score

Результат:

* скрины превращаются в текст

## Sprint 5 — Adaptive capture policy

Цель:

* readability score
* uncertainty score
* degraded/high-uncertainty modes
* unreadable capture every 3 sec
* optional aggressive 1–2 sec mode

Результат:

* “слепые” окна начинают отслеживаться плотнее

## Sprint 6 — Context fusion & dedup

Цель:

* объединение AX/OCR/app metadata
* dedup
* topic hints
* quality scoring

Результат:

* контекст становится пригодным для summary

## Sprint 7 — Daily summary engine

Цель:

* OpenRouter integration
* session summaries
* daily summaries
* suggested notes

Результат:

* приложение реально пишет осмысленный итог дня

## Sprint 8 — Obsidian export

Цель:

* markdown templates
* assets export
* daily note generation
* topic notes

Результат:

* всё падает в vault

## Sprint 9 — UI / Timeline / Review

Цель:

* timeline UI
* filters
* search
* manual regenerate summary
* session drill-down

Результат:

* приложением можно пользоваться как системой памяти

## Sprint 10 — Optimization pass

Цель:

* CPU/RAM profiling
* backlog control
* capture throttling
* OCR queue tuning
* retention cleanup

Результат:

* usable production-ready v1

## Sprint 11 — Notion export

Опционально.

---

# 17. Приоритеты разработки

## Must-have

* app/window tracking
* capture
* OCR
* adaptive unreadable mode
* daily summary
* local DB
* Obsidian export

## Should-have

* timeline UI
* rules engine
* per-app settings
* note suggestions
* session summaries

## Nice-to-have

* Notion
* weekly review
* semantic search
* assistant chat over memory

---

# 18. Риски

## 18.1 Нагрузка при high-frequency capture

Риск:

* unreadable mode 1–3 сек может быть тяжёлым

Смягчение:

* adaptive backoff
* hashes before OCR
* partial retention
* OCR not on every frame

## 18.2 Разная доступность текста по приложениям

Риск:

* где-то только скрины

Смягчение:

* layered extraction
* rules engine
* more frequent capture for unreadable apps

## 18.3 Рост объёма данных

Риск:

* много скринов

Смягчение:

* retention policy
* thumbnails
* dedup
* compact mode

---

# 19. Формулировка для разработчика

Если коротко, задача такая:

> Сделать macOS menu bar app, которое отслеживает активные приложения и окна, делает адаптивные визуальные сэмплы активного окна, пытается извлечь текст через Accessibility и локальный OCR, хранит таймлайн дня в SQLite, а затем формирует AI-summary и экспортирует итог в Obsidian. Для окон, где текст не удаётся извлечь, частота захвата должна автоматически повышаться до 3 секунд, а в агрессивном режиме — до 1–2 секунд.

---

# 20. Что я бы ещё добавил в постановку агенту-разработчику

Прямо отдельным блоком:

## Acceptance requirements

* приложение должно стабильно работать 8+ часов
* unreadable windows должны реально трекаться чаще
* OCR backlog не должен бесконтрольно расти
* summary должен объяснять, чем пользователь занимался
* Obsidian daily note должен генерироваться автоматически
* privacy rules должны отключать capture/OCR для blacklist apps

---

Если хочешь, я следующим сообщением сделаю ещё один слой поверх этого: **готовую постановку для coding agent**, в формате “сгенерируй структуру проекта, файлы, протоколы модулей, интерфейсы Swift, SQL migration files и roadmap по коммитам”.
