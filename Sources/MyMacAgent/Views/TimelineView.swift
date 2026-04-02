import SwiftUI

struct TimelineView: View {
    let db: DatabaseManager
    @State private var selectedDate: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
    @State private var sessions: [TimelineSession] = []
    @State private var apps: [AppUsageSummary] = []
    @State private var dates: [String] = []
    @State private var searchText = ""
    @State private var searchResults: [ContextSnapshotRecord] = []

    var body: some View {
        HSplitView {
            // Left: date list
            List(dates, id: \.self, selection: $selectedDate) { date in
                Text(date)
            }
            .frame(minWidth: 120, maxWidth: 160)

            // Right: timeline content
            VStack(alignment: .leading, spacing: 12) {
                Text("Timeline — \(selectedDate)")
                    .font(.title2).fontWeight(.semibold)

                // Search bar
                TextField("Search context...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { performSearch() }

                if !searchResults.isEmpty {
                    searchResultsView
                } else {
                    timelineContentView
                }
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { loadData() }
        .onChange(of: selectedDate) { _ in loadData() }
    }

    private var timelineContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // App summary
                if !apps.isEmpty {
                    Text("Apps").font(.headline)
                    ForEach(apps, id: \.bundleId) { app in
                        HStack {
                            Text(app.appName).fontWeight(.medium)
                            Spacer()
                            Text(ObsidianExporter.formatDuration(minutes: app.totalMinutes))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }

                // Sessions
                Text("Sessions").font(.headline)
                ForEach(sessions, id: \.sessionId) { session in
                    SessionRowView(session: session)
                }
            }
        }
    }

    private var searchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search results for \"\(searchText)\"").font(.headline)
                ForEach(searchResults, id: \.id) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.appName ?? "Unknown").fontWeight(.medium)
                            Text(result.windowTitle ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Text(String(result.timestamp.prefix(16)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let text = result.mergedText {
                            Text(String(text.prefix(200)))
                                .font(.caption)
                                .lineLimit(3)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
        }
    }

    private func loadData() {
        let provider = TimelineDataProvider(db: db)
        dates = (try? provider.availableDates()) ?? []
        sessions = (try? provider.sessionsForDate(selectedDate)) ?? []
        apps = (try? provider.appSummaryForDate(selectedDate)) ?? []
        searchResults = []
        searchText = ""
    }

    private func performSearch() {
        guard !searchText.isEmpty else { searchResults = []; return }
        let engine = SearchEngine(db: db)
        searchResults = (try? engine.search(query: searchText)) ?? []
    }
}

struct SessionRowView: View {
    let session: TimelineSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.appName).fontWeight(.medium)
                    if session.uncertaintyMode != "normal" {
                        Text("(\(session.uncertaintyMode))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(formatTime(session.startedAt))–\(session.endedAt.map { formatTime($0) } ?? "ongoing")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ObsidianExporter.formatDuration(minutes: session.durationMinutes))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 11)
        let end = iso.index(start, offsetBy: 5)
        return String(iso[start..<end])
    }
}
