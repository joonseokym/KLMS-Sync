import AppKit
import EventKit
import Foundation

struct SyncState: Decodable {
    let status: String
    let content: SyncContent?
}

struct SyncContent: Decodable {
    let kind: String
    let examItems: [SyncItem]?
    let helpDeskItems: [SyncItem]?

    enum CodingKeys: String, CodingKey {
        case kind
        case examItems = "exam_items"
        case helpDeskItems = "help_desk_items"
    }
}

struct SyncItem: Decodable {
    let url: String
    let course: String
    let title: String
    let due: String
    let submission: String
    let instructions: String
    let category: String?
    let timingPrecision: String?
    let syncStart: String?
    let syncDue: String?
    let sourceTitle: String?

    enum CodingKeys: String, CodingKey {
        case url
        case course
        case title
        case due
        case submission
        case instructions
        case category
        case timingPrecision = "timing_precision"
        case syncStart = "sync_start"
        case syncDue = "sync_due"
        case sourceTitle = "source_title"
    }
}

struct DesiredEvent {
    let identifier: String
    let title: String
    let startDate: Date?
    let dueDate: Date
    let notes: String
}

enum SyncBucket: String {
    case all
    case exam
    case helpdesk
}

let currentSyncMarkerPrefix = "KLMS_SYNC_ITEM_ID:"
let legacySyncMarkerPrefixes = ["KLMS_ASSIGN_ID:"]
let syncMarkerPrefixes = [currentSyncMarkerPrefix] + legacySyncMarkerPrefixes
let isClearOnly = CommandLine.arguments.dropFirst().first == "--clear"
let isDeleteOnly = CommandLine.arguments.dropFirst().first == "--delete-calendar"
let bucket = parseBucket(arguments: Array(CommandLine.arguments.dropFirst()))

if isClearOnly || isDeleteOnly {
    guard CommandLine.arguments.count >= 3 else {
        fputs("Usage: sync_klms_calendar --clear <calendar_name>\n", stderr)
        fputs("   or: sync_klms_calendar --delete-calendar <calendar_name>\n", stderr)
        exit(2)
    }
} else if CommandLine.arguments.count < 3 {
    fputs("Usage: sync_klms_calendar <state_json> <calendar_name> [duration_minutes] [--bucket=exam|helpdesk|all] [--lookback-days=365]\n", stderr)
    exit(2)
}

let calendarName = isClearOnly ? CommandLine.arguments[2] : CommandLine.arguments[2]
let minimumSpanMinutes = isClearOnly ? 15 : (CommandLine.arguments.count >= 4 ? Int(CommandLine.arguments[3]) ?? 15 : 15)
let lookbackDays = parseLookbackDays(arguments: Array(CommandLine.arguments.dropFirst()))

let store = EKEventStore()
guard requestAccess(store: store) else {
    fputs("Calendar access was not granted.\n", stderr)
    exit(1)
}

if isDeleteOnly {
    guard let calendar = findCalendar(named: calendarName, store: store) else {
        print("calendar=\(calendarName) deleted=0 missing=1")
        exit(0)
    }

    do {
        try store.removeCalendar(calendar, commit: true)
    } catch {
        fputs("Failed to delete calendar '\(calendar.title)': \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    print("calendar=\(calendar.title) deleted=1 missing=0")
    exit(0)
}

if isClearOnly {
    guard let calendar = findCalendar(named: calendarName, store: store) else {
        print("calendar=\(calendarName) created=0 updated=0 deleted=0 total=0")
        exit(0)
    }

    let existingEvents = managedEvents(in: calendar, store: store, lookbackDays: lookbackDays)
    var deleted = 0

    for event in existingEvents {
        do {
            try store.remove(event, span: .thisEvent, commit: false)
            deleted += 1
        } catch {
            fputs("Failed to delete event '\(event.title ?? "(untitled)")': \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    do {
        try store.commit()
    } catch {
        fputs("Failed to commit calendar cleanup: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    print("calendar=\(calendar.title) created=0 updated=0 deleted=\(deleted) total=0")
    exit(0)
}

let statePath = CommandLine.arguments[1]
let stateURL = URL(fileURLWithPath: statePath)
let decoder = JSONDecoder()

let state: SyncState
do {
    let data = try Data(contentsOf: stateURL)
    state = try decoder.decode(SyncState.self, from: data)
} catch {
    fputs("Failed to load state JSON: \(error.localizedDescription)\n", stderr)
    exit(1)
}

guard state.status == "ok", let content = state.content, content.kind == "success" else {
    fputs("State is not syncable.\n", stderr)
    exit(1)
}

guard let calendar = resolveCalendar(named: calendarName, store: store) else {
    fputs("Could not resolve or create calendar: \(calendarName)\n", stderr)
    exit(1)
}

let desiredEvents = buildDesiredEvents(items: syncableItems(from: content, bucket: bucket))
let desiredByID = Dictionary(uniqueKeysWithValues: desiredEvents.map { ($0.identifier, $0) })
let existingEvents = managedEvents(in: calendar, store: store, lookbackDays: lookbackDays)

var created = 0
var updated = 0
var deleted = 0

for event in existingEvents {
    guard let identifier = extractIdentifier(from: event.notes) else { continue }
    guard let desired = desiredByID[identifier] else {
        do {
            try store.remove(event, span: .thisEvent, commit: false)
            deleted += 1
        } catch {
            fputs("Failed to delete event for \(identifier): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        continue
    }

    if applyIfNeeded(event: event, desired: desired, minimumSpanMinutes: minimumSpanMinutes) {
        do {
            try store.save(event, span: .thisEvent, commit: false)
            updated += 1
        } catch {
            fputs("Failed to update event for \(identifier): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

let existingIDs = Set(existingEvents.compactMap { extractIdentifier(from: $0.notes) })
for desired in desiredEvents where !existingIDs.contains(desired.identifier) {
    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = desired.title
    event.startDate =
        desired.startDate
        ?? resolvedStartDate(
            existingStart: nil,
            existingCreationDate: nil,
            dueDate: desired.dueDate,
            minimumSpanMinutes: minimumSpanMinutes
        )
    event.endDate = desired.dueDate
    event.notes = desired.notes
    event.timeZone = TimeZone(identifier: "Asia/Seoul")
    event.availability = .free
    event.alarms = buildAlarms(dueDate: desired.dueDate)

    do {
        try store.save(event, span: .thisEvent, commit: false)
        created += 1
    } catch {
        fputs("Failed to create event for \(desired.identifier): \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

do {
    try store.commit()
} catch {
    fputs("Failed to commit calendar changes: \(error.localizedDescription)\n", stderr)
    exit(1)
}

print("calendar=\(calendar.title) created=\(created) updated=\(updated) deleted=\(deleted) total=\(desiredEvents.count)")

func buildDesiredEvents(items: [SyncItem]) -> [DesiredEvent] {
    items.compactMap { item in
        guard let dueDate = parseDueDate(for: item) else { return nil }
        if !isCalendarNoticeItem(item) {
            guard dueDate > Date() else { return nil }
        }
        let explicitStartDate = parseStartDate(for: item)
        let calendarNotice = isCalendarNoticeItem(item)
        let identifier = itemIdentifier(for: item)
        let kindLabel = eventKindLabel(for: item)
        let scheduleLabel = calendarNotice ? "일정" : "마감"
        let sourceLine = (item.sourceTitle ?? "").isEmpty ? "" : "\n출처: \(item.sourceTitle!)"
        let timingLine =
            calendarNotice && item.timingPrecision == "date"
            ? "\n시간: KLMS에서 날짜만 확인됨"
            : ""
        let notes = """
\(currentSyncMarkerPrefix)\(identifier)
종류: \(kindLabel)
과목: \(item.course)
\(kindLabel): \(item.title)
\(scheduleLabel): \(item.due)\(timingLine)\(sourceLine)
제출 상태: \(item.submission)
메모: \(item.instructions)
링크: \(item.url)
"""
        let titlePrefix = calendarTitlePrefix(for: item)
        let title = item.course.isEmpty
            ? "\(titlePrefix) \(item.title)"
            : "\(titlePrefix) \(item.course) - \(item.title)"

        return DesiredEvent(
            identifier: identifier,
            title: title,
            startDate: explicitStartDate,
            dueDate: dueDate,
            notes: notes
        )
    }
}

func syncableItems(from content: SyncContent, bucket: SyncBucket) -> [SyncItem] {
    let items = (content.examItems ?? []) + (content.helpDeskItems ?? [])
    switch bucket {
    case .all:
        return items
    case .exam:
        return items.filter(isExamCalendarItem)
    case .helpdesk:
        return items.filter(isHelpDeskCalendarItem)
    }
}

func syncItemBaseIdentifier(from url: String) -> String {
    if let components = URLComponents(string: url),
       let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
       !id.isEmpty {
        return id
    }
    return url
}

func itemIdentifier(for item: SyncItem) -> String {
    let base = syncItemBaseIdentifier(from: item.url)
    if item.category == "exam" {
        let titlePart = identifierFragment(item.title)
        let duePart = identifierFragment(item.syncDue ?? item.due)
        return "exam:\(base):\(titlePart):\(duePart)"
    }

    if item.category == "help_desk" {
        let titlePart = identifierFragment(item.title)
        let duePart = identifierFragment(item.syncDue ?? item.due)
        return "helpdesk:\(base):\(titlePart):\(duePart)"
    }

    return base
}

func parseDueDate(for item: SyncItem) -> Date? {
    if let syncDue = item.syncDue, let isoDate = parseISODate(syncDue) {
        return isoDate
    }
    return parseDueDate(item.due)
}

func parseStartDate(for item: SyncItem) -> Date? {
    guard let syncStart = item.syncStart else { return nil }
    return parseISODate(syncStart)
}

func parseBucket(arguments: [String]) -> SyncBucket {
    guard let rawValue = arguments.first(where: { $0.hasPrefix("--bucket=") })?
        .split(separator: "=", maxSplits: 1)
        .last
    else {
        return .all
    }

    return SyncBucket(rawValue: String(rawValue)) ?? .all
}

func parseLookbackDays(arguments: [String]) -> Int {
    guard let rawValue = arguments.first(where: { $0.hasPrefix("--lookback-days=") })?
        .split(separator: "=", maxSplits: 1)
        .last,
        let value = Int(rawValue)
    else {
        return 365
    }

    return max(1, value)
}

func isCalendarNoticeItem(_ item: SyncItem) -> Bool {
    isExamCalendarItem(item) || isHelpDeskCalendarItem(item)
}

func isExamCalendarItem(_ item: SyncItem) -> Bool {
    item.category == "exam"
}

func isHelpDeskCalendarItem(_ item: SyncItem) -> Bool {
    item.category == "help_desk"
}

func eventKindLabel(for item: SyncItem) -> String {
    if item.category == "exam" {
        return "시험 일정"
    }
    if item.category == "help_desk" {
        return "헬프데스크 안내"
    }
    return "과제"
}

func calendarTitlePrefix(for item: SyncItem) -> String {
    if item.category == "exam" {
        return "[KLMS 시험]"
    }
    if item.category == "help_desk" {
        return "[KLMS 헬프데스크]"
    }
    return "[KLMS]"
}

func parseDueDate(_ text: String) -> Date? {
    if let koreanDue = parseKoreanDueDate(text) {
        return koreanDue
    }
    if let rangeDue = parseDottedRangeDueDate(text) {
        return rangeDue
    }
    return parseDottedDateDueDate(text)
}

func parseKoreanDueDate(_ text: String) -> Date? {
    let pattern = #"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일.*?(오전|오후)\s*(\d{1,2}):(\d{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 7 else {
        return nil
    }

    let year = Int(nsText.substring(with: match.range(at: 1))) ?? 0
    let month = Int(nsText.substring(with: match.range(at: 2))) ?? 0
    let day = Int(nsText.substring(with: match.range(at: 3))) ?? 0
    let meridiem = nsText.substring(with: match.range(at: 4))
    var hour = Int(nsText.substring(with: match.range(at: 5))) ?? 0
    let minute = Int(nsText.substring(with: match.range(at: 6))) ?? 0

    hour = hour % 12
    if meridiem == "오후" {
        hour += 12
    }

    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(identifier: "Asia/Seoul")
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date
}

func parseDottedRangeDueDate(_ text: String) -> Date? {
    let pattern = #"(\d{4})\.(\d{1,2})\.(\d{1,2})\s*~\s*(\d{4})\.(\d{1,2})\.(\d{1,2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 7 else {
        return nil
    }

    let year = Int(nsText.substring(with: match.range(at: 4))) ?? 0
    let month = Int(nsText.substring(with: match.range(at: 5))) ?? 0
    let day = Int(nsText.substring(with: match.range(at: 6))) ?? 0
    return buildSeoulDate(year: year, month: month, day: day, hour: 23, minute: 59)
}

func parseDottedDateDueDate(_ text: String) -> Date? {
    let pattern = #"(\d{4})\.(\d{1,2})\.(\d{1,2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 4 else {
        return nil
    }

    let year = Int(nsText.substring(with: match.range(at: 1))) ?? 0
    let month = Int(nsText.substring(with: match.range(at: 2))) ?? 0
    let day = Int(nsText.substring(with: match.range(at: 3))) ?? 0
    return buildSeoulDate(year: year, month: month, day: day, hour: 23, minute: 59)
}

func parseISODate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

func identifierFragment(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
}

func buildSeoulDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(identifier: "Asia/Seoul")
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date
}

func requestAccess(store: EKEventStore) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false

    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { accessGranted, _ in
            granted = accessGranted
            semaphore.signal()
        }
    } else {
        store.requestAccess(to: .event) { accessGranted, _ in
            granted = accessGranted
            semaphore.signal()
        }
    }

    semaphore.wait()
    return granted
}

func resolveCalendar(named calendarName: String, store: EKEventStore) -> EKCalendar? {
    if let existing = findCalendar(named: calendarName, store: store) {
        applyCalendarAppearance(calendar: existing, store: store)
        return existing
    }

    let calendar = EKCalendar(for: .event, eventStore: store)
    calendar.title = calendarName

    if let source = store.defaultCalendarForNewEvents?.source
        ?? store.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .mobileMe || $0.sourceType == .local }) {
        calendar.source = source
    } else {
        return nil
    }

    applyCalendarAppearance(calendar: calendar, store: store)
    do {
        try store.saveCalendar(calendar, commit: true)
        return calendar
    } catch {
        return nil
    }
}

func applyCalendarAppearance(calendar: EKCalendar, store: EKEventStore) {
    let desiredColor = desiredCalendarColor(named: calendar.title)
    if calendar.cgColor != desiredColor.cgColor {
        calendar.cgColor = desiredColor.cgColor
    }

    do {
        try store.saveCalendar(calendar, commit: false)
    } catch {
        // Ignore appearance-only failures.
    }
}

func desiredCalendarColor(named calendarName: String) -> NSColor {
    switch calendarName {
    case "시험":
        return NSColor(
            calibratedRed: 185.0 / 255.0,
            green: 70.0 / 255.0,
            blue: 54.0 / 255.0,
            alpha: 1
        )
    case "기타":
        return NSColor(
            calibratedRed: 148.0 / 255.0,
            green: 163.0 / 255.0,
            blue: 184.0 / 255.0,
            alpha: 1
        )
    case "헬프데스크":
        return NSColor(
            calibratedRed: 201.0 / 255.0,
            green: 122.0 / 255.0,
            blue: 16.0 / 255.0,
            alpha: 1
        )
    default:
        return NSColor(
            calibratedRed: 79.0 / 255.0,
            green: 70.0 / 255.0,
            blue: 229.0 / 255.0,
            alpha: 1
        )
    }
}

func findCalendar(named calendarName: String, store: EKEventStore) -> EKCalendar? {
    store.calendars(for: .event).first(where: { $0.title == calendarName })
}

func managedEvents(in calendar: EKCalendar, store: EKEventStore, lookbackDays: Int) -> [EKEvent] {
    let normalizedLookbackDays = max(1, lookbackDays)
    let windowStart = Calendar.current.date(byAdding: .day, value: -normalizedLookbackDays, to: Date()) ?? Date()
    let windowEnd = Calendar.current.date(byAdding: .day, value: 365, to: Date()) ?? Date()
    let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
    return store.events(matching: predicate).filter { event in
        guard let notes = event.notes else { return false }
        return syncMarkerPrefixes.contains(where: { notes.contains($0) })
    }
}

func extractIdentifier(from notes: String?) -> String? {
    guard let notes else { return nil }
    for line in notes.split(separator: "\n") {
        for markerPrefix in syncMarkerPrefixes where line.hasPrefix(markerPrefix) {
            return String(line.dropFirst(markerPrefix.count))
        }
    }
    return nil
}

func applyIfNeeded(event: EKEvent, desired: DesiredEvent, minimumSpanMinutes: Int) -> Bool {
    var changed = false
    let desiredStartDate =
        desired.startDate
        ?? resolvedStartDate(
            existingStart: event.startDate,
            existingCreationDate: event.creationDate,
            dueDate: desired.dueDate,
            minimumSpanMinutes: minimumSpanMinutes
        )

    if event.title != desired.title {
        event.title = desired.title
        changed = true
    }
    if abs(event.startDate.timeIntervalSince(desiredStartDate)) > 1 {
        event.startDate = desiredStartDate
        changed = true
    }
    if abs(event.endDate.timeIntervalSince(desired.dueDate)) > 1 {
        event.endDate = desired.dueDate
        changed = true
    }
    if event.notes != desired.notes {
        event.notes = desired.notes
        changed = true
    }

    let desiredAlarms = buildAlarms(dueDate: desired.dueDate)
    if !sameAlarms(lhs: event.alarms ?? [], rhs: desiredAlarms) {
        event.alarms = desiredAlarms
        changed = true
    }

    event.timeZone = TimeZone(identifier: "Asia/Seoul")
    event.availability = .free
    return changed
}

func buildAlarms(dueDate: Date) -> [EKAlarm] {
    let now = Date()
    var alarms: [EKAlarm] = []

    if dueDate.timeIntervalSince(now) > 24 * 3600 {
        alarms.append(EKAlarm(relativeOffset: -24 * 3600))
    }
    if dueDate.timeIntervalSince(now) > 2 * 3600 {
        alarms.append(EKAlarm(relativeOffset: -2 * 3600))
    } else if dueDate.timeIntervalSince(now) > 15 * 60 {
        alarms.append(EKAlarm(relativeOffset: -15 * 60))
    }

    return alarms
}

func resolvedStartDate(existingStart: Date?, existingCreationDate: Date?, dueDate: Date, minimumSpanMinutes: Int) -> Date {
    let minimumSpan = TimeInterval(max(minimumSpanMinutes, 1) * 60)
    let fallbackStart = max(Date(), dueDate.addingTimeInterval(-minimumSpan))

    guard let existingStart else {
        return fallbackStart
    }

    // Migrate legacy 15-minute events to start from when we first created them.
    if dueDate.timeIntervalSince(existingStart) <= minimumSpan + 1,
       let existingCreationDate,
       existingCreationDate < dueDate {
        return existingCreationDate
    }

    if existingStart < dueDate {
        return existingStart
    }

    return fallbackStart
}

func sameAlarms(lhs: [EKAlarm], rhs: [EKAlarm]) -> Bool {
    let left = lhs.compactMap(\.relativeOffset).sorted()
    let right = rhs.compactMap(\.relativeOffset).sorted()
    return left == right
}
