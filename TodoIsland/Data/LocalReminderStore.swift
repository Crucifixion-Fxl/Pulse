import Foundation
import SwiftData

enum LocalReminderSchemaV1: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)
  static var models: [any PersistentModel.Type] {
    [ListRecord.self, ReminderRecord.self]
  }

  @Model
  final class ListRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var accentRed: Double
    var accentGreen: Double
    var accentBlue: Double
    var accentAlpha: Double
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ReminderRecord.list)
    var reminders: [ReminderRecord] = []

    init(id: UUID = UUID(), title: String, accent: AccentSnapshot, createdAt: Date = Date()) {
      self.id = id
      self.title = title
      accentRed = accent.red
      accentGreen = accent.green
      accentBlue = accent.blue
      accentAlpha = accent.alpha
      self.createdAt = createdAt
    }
  }

  @Model
  final class ReminderRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var dueDate: Date?
    var includesTime: Bool
    var dueTimeZoneIdentifier: String?
    var priorityRawValue: Int
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    var list: ListRecord?

    init(
      id: UUID = UUID(),
      title: String,
      dueDate: Date? = nil,
      includesTime: Bool = false,
      dueTimeZoneIdentifier: String? = nil,
      priority: ReminderPriority = .none,
      isCompleted: Bool = false,
      completedAt: Date? = nil,
      createdAt: Date = Date(),
      list: ListRecord
    ) {
      self.id = id
      self.title = title
      self.dueDate = dueDate
      self.includesTime = includesTime
      self.dueTimeZoneIdentifier = dueTimeZoneIdentifier
      priorityRawValue = priority.rawValue
      self.isCompleted = isCompleted
      self.completedAt = completedAt
      self.createdAt = createdAt
      self.list = list
    }
  }
}

enum LocalReminderMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [LocalReminderSchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}

@MainActor
final class LocalReminderStore: ReminderBackend {
  typealias ListRecord = LocalReminderSchemaV1.ListRecord
  typealias ReminderRecord = LocalReminderSchemaV1.ReminderRecord

  let source = ReminderSource.local
  var onStoreChanged: (() -> Void)?
  let dataURL: URL?

  private let container: ModelContainer
  private let context: ModelContext

  init(storeURL: URL? = nil, isStoredInMemoryOnly: Bool = false) throws {
    let schema = Schema(versionedSchema: LocalReminderSchemaV1.self)
    let configuration: ModelConfiguration

    if isStoredInMemoryOnly {
      configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      dataURL = nil
    } else {
      let resolvedURL = try storeURL ?? Self.defaultStoreURL()
      configuration = ModelConfiguration(
        schema: schema,
        url: resolvedURL,
        cloudKitDatabase: .none
      )
      dataURL = resolvedURL
    }

    container = try ModelContainer(
      for: schema,
      migrationPlan: LocalReminderMigrationPlan.self,
      configurations: [configuration]
    )
    context = container.mainContext
  }

  static func defaultStoreURL() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appending(path: "TodoIsland", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory.appending(path: "LocalReminders.store")
  }

  func fetchLists() async throws -> [ReminderListSnapshot] {
    try allLists()
      .map(Self.snapshot)
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] {
    guard let list = try list(id: listID) else { throw ReminderStoreError.listNotFound }
    return list.reminders
      .filter { !$0.isCompleted }
      .map(Self.snapshot)
  }

  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] {
    try context.fetch(FetchDescriptor<ReminderRecord>())
      .filter { record in
        guard let dueDate = record.dueDate else { return false }
        return dueDate >= dueFrom && dueDate <= through
      }
      .map(Self.snapshot)
  }

  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] {
    try context.fetch(FetchDescriptor<ReminderRecord>())
      .filter { $0.dueDate == nil && !$0.isCompleted }
      .map(Self.snapshot)
  }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ReminderStoreError.emptyTitle }
    guard let list = try list(id: listID) else { throw ReminderStoreError.listNotFound }

    let record = ReminderRecord(title: normalized, list: list)
    if let dueComponents {
      record.dueDate = Calendar.current.date(from: dueComponents)
      record.includesTime = dueComponents.hour != nil
      record.dueTimeZoneIdentifier = dueComponents.timeZone?.identifier
    }
    context.insert(record)
    try save()
  }

  func updateReminder(id: String, from draft: ReminderDraft) async throws {
    guard !draft.normalizedTitle.isEmpty else { throw ReminderStoreError.emptyTitle }
    guard let reminder = try reminder(id: id) else {
      throw ReminderStoreError.reminderNotFound
    }

    reminder.title = draft.normalizedTitle
    reminder.dueDate = draft.hasDueDate ? draft.dueDate : nil
    reminder.includesTime = draft.hasDueDate && draft.includesTime
    reminder.dueTimeZoneIdentifier = reminder.includesTime ? draft.dueTimeZone?.identifier : nil
    reminder.priorityRawValue = draft.priority.rawValue
    try save()
  }

  func setCompleted(_ completed: Bool, reminderID: String) async throws {
    guard let reminder = try reminder(id: reminderID) else {
      throw ReminderStoreError.reminderNotFound
    }
    reminder.isCompleted = completed
    reminder.completedAt = completed ? Date() : nil
    try save()
  }

  func deleteReminder(id: String) async throws {
    guard let reminder = try reminder(id: id) else {
      throw ReminderStoreError.reminderNotFound
    }
    context.delete(reminder)
    try save()
  }

  func createList(title: String) async throws -> ReminderListSnapshot {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ReminderStoreError.emptyListTitle }
    guard try !containsList(named: normalized) else {
      throw ReminderStoreError.duplicateListName
    }

    let id = UUID()
    let record = ListRecord(id: id, title: normalized, accent: Self.accent(for: id))
    context.insert(record)
    try save()
    return Self.snapshot(record)
  }

  func renameList(id: String, title: String) async throws {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ReminderStoreError.emptyListTitle }
    guard let target = try list(id: id) else { throw ReminderStoreError.listNotFound }
    guard try !allLists().contains(where: {
      $0.id != target.id && Self.namesMatch($0.title, normalized)
    }) else {
      throw ReminderStoreError.duplicateListName
    }
    target.title = normalized
    try save()
  }

  func deletionSummary(forListID id: String) async throws -> ReminderListDeletionSummary {
    guard let list = try list(id: id) else { throw ReminderStoreError.listNotFound }
    return ReminderListDeletionSummary(
      list: Self.snapshot(list),
      pendingCount: list.reminders.filter { !$0.isCompleted }.count,
      completedCount: list.reminders.filter(\.isCompleted).count
    )
  }

  func deleteList(id: String) async throws {
    guard let list = try list(id: id) else { throw ReminderStoreError.listNotFound }
    context.delete(list)
    try save()
  }

  private func allLists() throws -> [ListRecord] {
    try context.fetch(FetchDescriptor<ListRecord>())
  }

  private func list(id: String) throws -> ListRecord? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    return try allLists().first { $0.id == uuid }
  }

  private func reminder(id: String) throws -> ReminderRecord? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    return try context.fetch(FetchDescriptor<ReminderRecord>()).first { $0.id == uuid }
  }

  private func containsList(named title: String) throws -> Bool {
    try allLists().contains { Self.namesMatch($0.title, title) }
  }

  private func save() throws {
    try context.save()
    onStoreChanged?()
  }

  private static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }

  private static func snapshot(_ list: ListRecord) -> ReminderListSnapshot {
    ReminderListSnapshot(
      id: list.id.uuidString,
      title: list.title,
      accent: AccentSnapshot(
        red: list.accentRed,
        green: list.accentGreen,
        blue: list.accentBlue,
        alpha: list.accentAlpha
      ),
      source: .local
    )
  }

  private static func snapshot(_ reminder: ReminderRecord) -> ReminderSnapshot {
    let components: DateComponents?
    if let dueDate = reminder.dueDate {
      var selected = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
      if reminder.includesTime {
        let time = Calendar.current.dateComponents([.hour, .minute], from: dueDate)
        selected.hour = time.hour
        selected.minute = time.minute
        selected.timeZone = reminder.dueTimeZoneIdentifier.flatMap(TimeZone.init(identifier:))
      }
      components = selected
    } else {
      components = nil
    }

    return ReminderSnapshot(
      id: reminder.id.uuidString,
      listID: reminder.list?.id.uuidString ?? "",
      source: .local,
      title: reminder.title,
      dueDateComponents: components,
      priority: ReminderPriority(rawValue: reminder.priorityRawValue) ?? .none,
      isRecurring: false,
      isCompleted: reminder.isCompleted
    )
  }

  private static func accent(for id: UUID) -> AccentSnapshot {
    let palette = [
      AccentSnapshot(red: 0.20, green: 0.62, blue: 0.98, alpha: 1),
      AccentSnapshot(red: 0.35, green: 0.78, blue: 0.48, alpha: 1),
      AccentSnapshot(red: 0.96, green: 0.58, blue: 0.20, alpha: 1),
      AccentSnapshot(red: 0.70, green: 0.45, blue: 0.94, alpha: 1),
      AccentSnapshot(red: 0.94, green: 0.35, blue: 0.49, alpha: 1),
      AccentSnapshot(red: 0.22, green: 0.76, blue: 0.74, alpha: 1),
    ]
    let stableValue = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
    return palette[Int(stableValue.magnitude % UInt(palette.count))]
  }
}
