import SwiftUI
import SwiftData

struct ProfileTabView: View {
  @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
  @Query private var words: [CapturedWord]
  @Query private var passages: [CapturedPassage]
  @Query private var sessions: [ReadingSession]
  @Query(sort: \QuizResult.date, order: .reverse) private var quizzes: [QuizResult]

  @AppStorage(Handedness.userDefaultsKey) private var handednessRaw: String = Handedness.right.rawValue

  @Environment(\.modelContext) private var modelContext

  @State private var selectedDay: DaySelection?
  @State private var showResetConfirm = false
  @State private var resetError: String?

  private var activityMap: [Date: Int] {
    ReadingStatsService.activityMap(
      words: words,
      passages: passages,
      sessions: sessions,
      quizzes: quizzes
    )
  }

  private var masteryHistogram: [Int] {
    ReadingStatsService.masteryHistogram(words: words)
  }

  private var streakDays: Int {
    ReadingStatsService.currentStreak(activityMap: activityMap)
  }

  private var dueCount: Int {
    ReadingStatsService.dueForReview(words: words)
  }

  private var lifetimeReadingTime: TimeInterval {
    ReadingStatsService.totalReadingTime(sessions: sessions)
  }

  private var totalPagesRead: Int {
    books.reduce(0) { $0 + ReadingStatsService.pagesRead(for: $1) }
  }

  private var quizAccuracy: Double? {
    ReadingStatsService.accuracy(quizzes: quizzes)
  }

  private var finishedCount: Int {
    books.filter(\.isFinished).count
  }

  // Today-only helpers
  private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }
  private var wordsToday: Int {
    words.filter { Calendar.current.startOfDay(for: $0.capturedAt) == todayStart }.count
  }
  private var minutesToday: Int {
    let secs = sessions
      .filter { Calendar.current.startOfDay(for: $0.startedAt) == todayStart }
      .reduce(0.0) { acc, s in
        let end = s.endedAt ?? s.startedAt
        return acc + max(0, end.timeIntervalSince(s.startedAt))
      }
    return Int(secs / 60)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.xl) {
        todaySection
        activitySection
        lifetimeSection
        masterySection
        perBookSection
        settingsSection
        footer
      }
      .padding(Spacing.lg)
    }
    .background(Color.parchment.ignoresSafeArea())
    .navigationTitle("Profile")
    .navigationBarTitleDisplayMode(.large)
    .sheet(item: $selectedDay) { selection in
      dayDetailSheet(for: selection)
    }
    .confirmationDialog(
      "Reset all app data?",
      isPresented: $showResetConfirm,
      titleVisibility: .visible
    ) {
      Button("Delete everything", role: .destructive) {
        resetAllData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes every book, captured word, passage, reading session, and quiz result. Glasses registration is kept. This cannot be undone.")
    }
    .alert("Reset failed", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(resetError ?? "")
    }
  }

  // MARK: - Today

  private var todaySection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader("Today")
      HStack(spacing: Spacing.md) {
        miniStat(icon: "textformat.abc", value: "\(wordsToday)", label: "words")
        miniStat(icon: "clock", value: "\(minutesToday)m", label: "read")
        miniStat(icon: "brain.head.profile", value: "\(dueCount)", label: "due")
        miniStat(icon: "flame.fill", value: "\(streakDays)", label: "streak")
      }
    }
  }

  private func miniStat(icon: String, value: String, label: String) -> some View {
    VStack(spacing: 2) {
      Image(systemName: icon)
        .font(.footnote)
        .foregroundStyle(.amber)
      Text(value)
        .font(.serif(.title3, weight: .bold))
        .foregroundStyle(.ink)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.leather)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.md)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow()
  }

  // MARK: - Activity calendar

  private var activitySection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader("Reading activity")
      ReadingActivityCalendarView(activity: activityMap) { day, score in
        selectedDay = DaySelection(day: day, score: score)
      }
      .padding(Spacing.md)
      .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
      .warmShadow()
    }
  }

  // MARK: - Lifetime

  private var lifetimeSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader("Lifetime")
      LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.md), GridItem(.flexible(), spacing: Spacing.md)], spacing: Spacing.md) {
        StatCardView(
          icon: "books.vertical.fill",
          label: "Library",
          value: "\(books.count)",
          secondary: finishedCount > 0 ? "\(finishedCount) finished" : nil
        )
        StatCardView(
          icon: "book.pages",
          label: "Pages read",
          value: "\(totalPagesRead)"
        )
        StatCardView(
          icon: "clock.fill",
          label: "Reading time",
          value: ReadingStatsService.formatDuration(lifetimeReadingTime)
        )
        StatCardView(
          icon: "flame.fill",
          label: "Current streak",
          value: "\(streakDays)",
          secondary: streakDays == 1 ? "day" : "days",
          tint: .brick
        )
        StatCardView(
          icon: "textformat.abc",
          label: "Words captured",
          value: "\(words.count)"
        )
        StatCardView(
          icon: "quote.opening",
          label: "Passages",
          value: "\(passages.count)"
        )
        StatCardView(
          icon: "brain.head.profile",
          label: "Words reviewed",
          value: "\(quizzes.reduce(0) { $0 + $1.totalQuestions })"
        )
        StatCardView(
          icon: "checkmark.seal.fill",
          label: "Quiz accuracy",
          value: quizAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
          tint: .sage
        )
      }
    }
  }

  // MARK: - Mastery distribution

  private var masterySection: some View {
    let buckets = masteryHistogram
    let maxBucket = max(buckets.max() ?? 0, 1)
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader("Mastery")
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(alignment: .bottom, spacing: Spacing.sm) {
          ForEach(0..<6, id: \.self) { level in
            VStack(spacing: 4) {
              Text("\(buckets[level])")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.ink)
              RoundedRectangle(cornerRadius: 4)
                .fill(level == 5 ? Color.sage : .amber.opacity(0.4 + Double(level) * 0.1))
                .frame(height: max(6, CGFloat(buckets[level]) / CGFloat(maxBucket) * 80))
              Text("L\(level)")
                .font(.caption2)
                .foregroundStyle(.leather)
            }
            .frame(maxWidth: .infinity)
          }
        }
        Text("Level 5 = mastered (30-day interval)")
          .font(.caption2)
          .foregroundStyle(.leather)
      }
      .padding(Spacing.md)
      .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
      .warmShadow()
    }
  }

  // MARK: - Per-book

  private var perBookSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader("Books")
      if books.isEmpty {
        Text("No books in your library yet.")
          .font(.footnote)
          .foregroundStyle(.leather)
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
      } else {
        VStack(spacing: Spacing.sm) {
          ForEach(sortedBooks) { book in
            bookRow(book)
          }
        }
      }
    }
  }

  private var sortedBooks: [Book] {
    books.sorted { lhs, rhs in
      let lhsLast = lhs.sessions.compactMap(\.endedAt).max() ?? lhs.dateAdded
      let rhsLast = rhs.sessions.compactMap(\.endedAt).max() ?? rhs.dateAdded
      return lhsLast > rhsLast
    }
  }

  private func bookRow(_ book: Book) -> some View {
    let pages = ReadingStatsService.pagesRead(for: book)
    let time = ReadingStatsService.totalReadingTime(sessions: book.sessions)
    let wordCount = book.words.count
    return HStack(alignment: .top, spacing: Spacing.md) {
      cover(for: book)
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(book.title)
            .font(.serif(.headline, weight: .semibold))
            .foregroundStyle(.ink)
            .lineLimit(2)
          if book.isFinished {
            Image(systemName: "checkmark.seal.fill")
              .font(.caption)
              .foregroundStyle(.sage)
          }
        }
        Text(book.author)
          .font(.caption)
          .foregroundStyle(.leather)
          .lineLimit(1)
        HStack(spacing: Spacing.md) {
          metaLabel(icon: "book.pages", text: "\(pages) pages")
          metaLabel(icon: "clock", text: ReadingStatsService.formatDuration(time))
          metaLabel(icon: "textformat.abc", text: "\(wordCount) words")
        }
        .padding(.top, 2)
      }
      Spacer(minLength: 0)
    }
    .padding(Spacing.md)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow()
  }

  private func cover(for book: Book) -> some View {
    Group {
      if let data = book.coverImageData, let img = UIImage(data: data) {
        Image(uiImage: img)
          .resizable()
          .scaledToFill()
      } else {
        RoundedRectangle(cornerRadius: CornerRadius.cover)
          .fill(.amber.opacity(0.3))
          .overlay(
            Image(systemName: "book.closed")
              .foregroundStyle(.leather)
          )
      }
    }
    .frame(width: 44, height: 64)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.cover))
  }

  private func metaLabel(icon: String, text: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon).font(.caption2)
      Text(text).font(.caption2)
    }
    .foregroundStyle(.leather)
  }

  // MARK: - Settings

  private var settingsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader("Settings")
      VStack(alignment: .leading, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Handedness")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.ink)
          Text("Determines which page edge feeds page tracking during gestures. Pick the hand you use to pinch while reading.")
            .font(.caption2)
            .foregroundStyle(.leather)
          Picker("Handedness", selection: $handednessRaw) {
            Text("Right-handed").tag(Handedness.right.rawValue)
            Text("Left-handed").tag(Handedness.left.rawValue)
          }
          .pickerStyle(.segmented)
          .padding(.top, Spacing.xs)
        }
      }
      .padding(Spacing.md)
      .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
      .warmShadow()

      dangerZone
    }
  }

  private var dangerZone: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Danger zone")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.brick)
        .padding(.top, Spacing.md)

      Button(role: .destructive) {
        showResetConfirm = true
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "trash.fill")
          Text("Reset all data")
            .fontWeight(.semibold)
          Spacer()
        }
        .foregroundStyle(.white)
        .padding(Spacing.md)
        .background(.brick, in: RoundedRectangle(cornerRadius: CornerRadius.button))
      }
      .buttonStyle(.plain)

      Text("Deletes every book, word, passage, reading session, and quiz result. Glasses registration is preserved.")
        .font(.caption2)
        .foregroundStyle(.leather)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(spacing: 2) {
      Text("LuminaReading")
        .font(.serif(.headline, weight: .semibold))
        .foregroundStyle(.leather)
      if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
        Text("Version \(version)")
          .font(.caption2)
          .foregroundStyle(.leather.opacity(0.7))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Spacing.lg)
  }

  // MARK: - Helpers

  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.serif(.title3, weight: .semibold))
      .foregroundStyle(.ink)
  }

  // MARK: - Reset

  private func resetAllData() {
    // Per-object delete (not batch) because Book↔ReadingSession has a
    // mandatory nullify inverse that Core Data's batch path trips on.
    // Deleting Books first cascades their ReadingSessions via the model's
    // `.cascade` rule and nullifies CapturedWord.book via its `.nullify`
    // inverse — so we still have to explicitly delete words and passages.
    do {
      for quiz in try modelContext.fetch(FetchDescriptor<QuizResult>()) {
        modelContext.delete(quiz)
      }
      for passage in try modelContext.fetch(FetchDescriptor<CapturedPassage>()) {
        modelContext.delete(passage)
      }
      for word in try modelContext.fetch(FetchDescriptor<CapturedWord>()) {
        modelContext.delete(word)
      }
      for book in try modelContext.fetch(FetchDescriptor<Book>()) {
        modelContext.delete(book)
      }
      // Any orphan sessions (book == nil) that weren't cascade-deleted.
      for session in try modelContext.fetch(FetchDescriptor<ReadingSession>()) {
        modelContext.delete(session)
      }
      try modelContext.save()
    } catch {
      resetError = error.localizedDescription
    }
  }

  // MARK: - Day detail sheet

  private func dayDetailSheet(for selection: DaySelection) -> some View {
    let day = selection.day
    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
    let dayWords = words.filter { $0.capturedAt >= day && $0.capturedAt < dayEnd }
    let dayPassages = passages.filter { $0.capturedAt >= day && $0.capturedAt < dayEnd }
    let daySessions = sessions.filter { $0.startedAt >= day && $0.startedAt < dayEnd }
    let dayQuizzes = quizzes.filter { $0.date >= day && $0.date < dayEnd }
    let minutes = Int(ReadingStatsService.totalReadingTime(sessions: daySessions) / 60)
    return NavigationStack {
      List {
        Section {
          HStack {
            Label("\(dayWords.count) words", systemImage: "textformat.abc")
            Spacer()
          }
          HStack {
            Label("\(dayPassages.count) passages", systemImage: "quote.opening")
            Spacer()
          }
          HStack {
            Label("\(minutes)m reading", systemImage: "clock")
            Spacer()
          }
          HStack {
            Label("\(dayQuizzes.reduce(0) { $0 + $1.totalQuestions }) questions", systemImage: "brain.head.profile")
            Spacer()
          }
        }
        if !dayWords.isEmpty {
          Section("Words") {
            ForEach(dayWords) { w in
              Text(w.text).font(.serif(.body))
            }
          }
        }
      }
      .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium, .large])
  }
}

private struct DaySelection: Identifiable {
  let day: Date
  let score: Int
  var id: Date { day }
}
