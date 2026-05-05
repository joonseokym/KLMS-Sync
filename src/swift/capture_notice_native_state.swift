#!/usr/bin/env swift

import ApplicationServices
import AppKit
import Foundation

struct NoticeDigest: Decodable {
    let generatedAt: String

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
    }
}

struct LineRange: Codable {
    let location: Int
    let length: Int
}

struct NoticeInteractionState: Codable {
    var title: String?
    var course: String?
    var url: String?
    var fingerprint: String?
    var readFingerprint: String?
    var readAt: String?
    var important: Bool?
    var importantAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case title
        case course
        case url
        case fingerprint
        case readFingerprint = "read_fingerprint"
        case readAt = "read_at"
        case important
        case importantAt = "important_at"
        case updatedAt = "updated_at"
    }
}

struct NoticeUserStateFile: Codable {
    var version: Int
    var updatedAt: String
    var notices: [String: NoticeInteractionState]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case notices
    }
}

struct RenderedNoticeState: Codable {
    let noticeId: String
    let course: String
    let title: String
    let fingerprint: String
    let sectionRange: LineRange
    let readChecklistRange: LineRange
    let importantChecklistRange: LineRange

    enum CodingKeys: String, CodingKey {
        case noticeId = "notice_id"
        case course
        case title
        case fingerprint
        case sectionRange = "section_range"
        case readChecklistRange = "read_checklist_range"
        case importantChecklistRange = "important_checklist_range"
    }
}

struct NoticeRenderStateFile: Codable {
    let version: Int
    let updatedAt: String
    let noteTitle: String
    let noteID: String?
    let renderedNotices: [RenderedNoticeState]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case noteTitle = "note_title"
        case noteID = "note_id"
        case renderedNotices = "rendered_notices"
    }
}

struct NotesCaptureContext {
    let runningApp: NSRunningApplication
    let app: AXUIElement
    let textArea: AXUIElement
}

let defaultNoteTitle = "KLMS 공지"
let readChecklistLabel = "읽음"
let importantChecklistLabel = "중요"

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

func defaultPath(near digestPath: String, fileName: String) -> String {
    URL(fileURLWithPath: digestPath).deletingLastPathComponent().appendingPathComponent(fileName).path
}

func parseArgs() -> (
    noteTitle: String,
    noteID: String?,
    digestPath: String,
    noticeStatePath: String,
    renderStatePath: String
) {
    var noteTitle = defaultNoteTitle
    var noteID: String?
    var digestPath: String?
    var noticeStatePath: String?
    var renderStatePath: String?
    var index = 1
    let arguments = CommandLine.arguments

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--note-title":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --note-title")
            }
            noteTitle = arguments[index]
        case "--note-id":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --note-id")
            }
            noteID = arguments[index]
        case "--notice-state-json":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --notice-state-json")
            }
            noticeStatePath = arguments[index]
        case "--render-state-json":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --render-state-json")
            }
            renderStatePath = arguments[index]
        default:
            if digestPath == nil {
                digestPath = argument
            } else {
                fail("Unexpected argument: \(argument)")
            }
        }
        index += 1
    }

    guard let digestPath else {
        fail(
            "Usage: capture_notice_native_state.swift [--note-title \"KLMS 공지\"] "
                + "[--notice-state-json <path>] [--render-state-json <path>] <notice_digest.json>"
        )
    }

    return (
        noteTitle,
        noteID,
        digestPath,
        noticeStatePath ?? defaultPath(near: digestPath, fileName: "notice_user_state.json"),
        renderStatePath ?? defaultPath(near: digestPath, fileName: "notice_note_render_state.json")
    )
}

func loadJSON<T: Decodable>(_ type: T.Type, path: String) -> T {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(type, from: data)
    } catch {
        fail("Failed to read JSON at \(path): \(error)")
    }
}

func loadOptionalJSON<T: Decodable>(_ type: T.Type, path: String) -> T? {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }

    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        return nil
    }
}

func writeJSON<T: Encodable>(_ value: T, path: String) {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    } catch {
        fail("Failed to write JSON at \(path): \(error)")
    }
}

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success, let value else {
        return nil
    }
    return value as? T
}

func findFirst(_ element: AXUIElement, role targetRole: String) -> AXUIElement? {
    let role: String = attr(element, kAXRoleAttribute) ?? ""
    if role == targetRole {
        return element
    }
    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        if let found = findFirst(child, role: targetRole) {
            return found
        }
    }
    return nil
}

func findMenuItem(named target: String, in element: AXUIElement) -> AXUIElement? {
    if let title: String = attr(element, kAXTitleAttribute), title == target {
        let role: String = attr(element, kAXRoleAttribute) ?? ""
        if role == kAXMenuItemRole as String {
            return element
        }
    }

    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        if let found = findMenuItem(named: target, in: child) {
            return found
        }
    }
    return nil
}

@discardableResult
func pressMenuIfAvailable(_ app: AXUIElement, _ titles: [String]) -> Bool {
    guard let menuBar: AXUIElement = attr(app, kAXMenuBarAttribute) else {
        return false
    }

    for title in titles {
        if let item = findMenuItem(named: title, in: menuBar) {
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
    }
    return false
}

func runProcess(_ launchPath: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("Failed to launch \(launchPath): \(error)")
    }

    if process.terminationStatus != 0 {
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let message = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        fail(message ?? "Command failed: \(launchPath)")
    }
}

func jsStringLiteral(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [text], options: [])
    let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
}

func showNote(noteID: String) {
    let noteLiteral = jsStringLiteral(noteID)
    let script = """
const noteId = \(noteLiteral);
const notes = Application("/System/Applications/Notes.app");
const allNotes = notes.notes();
for (let i = 0; i < allNotes.length; i += 1) {
  try {
    if (String(allNotes[i].id()) === noteId) {
      notes.activate();
      allNotes[i].show();
      break;
    }
  } catch (error) {}
}
"""

    runProcess("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
}

func resolveNoteID(noteTitle: String) -> String? {
    let noteLiteral = jsStringLiteral(noteTitle)
    let script = """
function noteModifiedAt(note) {
  try {
    const raw = note.modificationDate();
    const time = new Date(raw).getTime();
    return Number.isFinite(time) ? time : 0;
  } catch (error) {
    return 0;
  }
}
const noteName = \(noteLiteral);
const normalizedNoteName = String(noteName || "").normalize("NFC");
const notes = Application("/System/Applications/Notes.app");
const matches = [];
const allNotes = notes.notes();
for (let i = 0; i < allNotes.length; i += 1) {
  try {
    if (String(allNotes[i].name() || "").normalize("NFC") === normalizedNoteName) {
      matches.push({ id: String(allNotes[i].id()), modifiedAt: noteModifiedAt(allNotes[i]) });
    }
  } catch (error) {}
}
matches.sort((left, right) => right.modifiedAt - left.modifiedAt);
if (matches.length > 0) {
  console.log(matches[0].id);
}
"""

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", script]
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func ensureNoteVisible(noteTitle: String, noteID: String?) {
    let resolvedNoteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? noteID!
        : resolveNoteID(noteTitle: noteTitle)
    guard let resolvedNoteID else {
        fail("Could not locate note: \(noteTitle)")
    }
    showNote(noteID: resolvedNoteID)
    Thread.sleep(forTimeInterval: 0.35)
}

func resolveNotesCaptureContext(retries: Int = 20, retryDelay: TimeInterval = 0.15) -> NotesCaptureContext? {
    guard let notesApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Notes" }) else {
        return nil
    }

    notesApp.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.2)

    for _ in 0..<retries {
        let app = AXUIElementCreateApplication(notesApp.processIdentifier)
        let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        if let window = windows.first,
           let textArea = findFirst(window, role: kAXTextAreaRole as String) {
            return NotesCaptureContext(runningApp: notesApp, app: app, textArea: textArea)
        }
        Thread.sleep(forTimeInterval: retryDelay)
    }

    return nil
}

func oneLine(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func loadExpandedText(_ context: NotesCaptureContext, expectedTitles: [String]) -> String {
    _ = pressMenuIfAvailable(context.app, ["모든 섹션 펼치기", "Expand All Sections"])
    Thread.sleep(forTimeInterval: 0.5)

    let normalizedTitles = expectedTitles.map(oneLine).filter { !$0.isEmpty }
    var lastText = ""

    for _ in 0..<50 {
        let currentText: String = attr(context.textArea, kAXValueAttribute) ?? ""
        lastText = currentText
        let normalizedText = oneLine(currentText)
        let hasTitle = normalizedTitles.isEmpty || normalizedTitles.contains { normalizedText.contains($0) }
        let hasChecklist = normalizedText.contains(readChecklistLabel) || normalizedText.contains(importantChecklistLabel)
        if hasTitle && hasChecklist {
            return currentText
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    return lastText
}

func cfRangeValue(_ range: LineRange) -> AXValue {
    var raw = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &raw) else {
        fail("Failed to create accessibility range value.")
    }
    return value
}

func attributedString(for textArea: AXUIElement, range: LineRange) -> NSAttributedString? {
    var value: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
        textArea,
        kAXAttributedStringForRangeParameterizedAttribute as CFString,
        cfRangeValue(range),
        &value
    )
    guard error == .success, let value else {
        return nil
    }
    return value as? NSAttributedString
}

func prefixText(from attributes: [NSAttributedString.Key: Any], key: NSAttributedString.Key) -> String? {
    if let prefix = attributes[key] as? String {
        return prefix
    }
    if let prefix = attributes[key] as? NSAttributedString {
        return prefix.string
    }
    return nil
}

func checklistState(from prefix: String) -> Bool? {
    let normalized = prefix
        .lowercased()
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    if normalized.contains("완료되지 않")
        || normalized.contains("체크 해제")
        || normalized.contains("선택 해제")
        || normalized.contains("not completed")
        || normalized.contains("not checked")
        || normalized.contains("not selected")
        || normalized.contains("unchecked")
        || normalized.contains("unselected")
    {
        return false
    }
    if normalized.contains("완료됨")
        || normalized.range(of: #"\b(completed|checked|selected)\b"#, options: .regularExpression) != nil
    {
        return true
    }
    return nil
}

func captureChecklistValue(
    textArea: AXUIElement,
    currentText: String,
    range: LineRange,
    expectedLabel: String
) -> Bool? {
    let nsText = currentText as NSString
    let upperBound = range.location + range.length
    guard range.location >= 0, range.length >= 0, upperBound <= nsText.length else {
        return nil
    }
    guard nsText.substring(with: NSRange(location: range.location, length: range.length)) == expectedLabel else {
        return nil
    }
    guard let attributed = attributedString(for: textArea, range: range), attributed.length > 0 else {
        return nil
    }

    let attributes = attributed.attributes(at: 0, effectiveRange: nil)
    let prefixKey = NSAttributedString.Key("AXListItemPrefix")
    guard let prefix = prefixText(from: attributes, key: prefixKey) else {
        return nil
    }
    return checklistState(from: prefix)
}

func findNoticeTitleRange(currentText: String, title: String, cursor: inout Int) -> LineRange? {
    let normalizedTitle = oneLine(title)
    guard !normalizedTitle.isEmpty else {
        return nil
    }

    let nsText = currentText as NSString
    let searchLength = max(0, nsText.length - cursor)
    guard searchLength > 0 else {
        return nil
    }

    let found = nsText.range(
        of: normalizedTitle,
        options: [],
        range: NSRange(location: cursor, length: searchLength)
    )
    guard found.location != NSNotFound else {
        return nil
    }

    cursor = found.location + found.length
    return LineRange(location: found.location, length: found.length)
}

func findChecklistRangeNearTitle(currentText: String, titleRange: LineRange, label: String) -> LineRange? {
    let nsText = currentText as NSString
    let titleEnd = titleRange.location + titleRange.length
    let windowLength = min(120, max(0, nsText.length - titleEnd))
    guard windowLength > 0 else {
        return nil
    }

    let found = nsText.range(of: label, options: [], range: NSRange(location: titleEnd, length: windowLength))
    guard found.location != NSNotFound else {
        return nil
    }
    return LineRange(location: found.location, length: found.length)
}

let arguments = parseArgs()
let digest = loadJSON(NoticeDigest.self, path: arguments.digestPath)
var userState = loadOptionalJSON(NoticeUserStateFile.self, path: arguments.noticeStatePath)
    ?? NoticeUserStateFile(version: 1, updatedAt: digest.generatedAt, notices: [:])
guard let renderState = loadOptionalJSON(NoticeRenderStateFile.self, path: arguments.renderStatePath) else {
    writeJSON(userState, path: arguments.noticeStatePath)
    print("Captured native notice note state: \(arguments.noteTitle) read=0 important=0")
    exit(0)
}

let effectiveNoteID = arguments.noteID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    ? arguments.noteID
    : renderState.noteID

ensureNoteVisible(noteTitle: arguments.noteTitle, noteID: effectiveNoteID)
guard var context = resolveNotesCaptureContext() else {
    fail("Could not locate the editable Notes text area.")
}

var currentText = loadExpandedText(context, expectedTitles: renderState.renderedNotices.map(\.title))
if !currentText.contains(readChecklistLabel) && !currentText.contains(importantChecklistLabel) {
    ensureNoteVisible(noteTitle: arguments.noteTitle, noteID: effectiveNoteID)
    if let refreshedContext = resolveNotesCaptureContext() {
        context = refreshedContext
        currentText = loadExpandedText(context, expectedTitles: renderState.renderedNotices.map(\.title))
    }
}

var titleCursor = 0
for rendered in renderState.renderedNotices {
    var state = userState.notices[rendered.noticeId] ?? NoticeInteractionState()
    state.title = rendered.title
    state.course = rendered.course
    state.fingerprint = rendered.fingerprint
    state.updatedAt = digest.generatedAt

    let titleRange = findNoticeTitleRange(currentText: currentText, title: rendered.title, cursor: &titleCursor)
    let readRange = titleRange.flatMap {
        findChecklistRangeNearTitle(currentText: currentText, titleRange: $0, label: readChecklistLabel)
    } ?? rendered.readChecklistRange
    let importantRange = titleRange.flatMap {
        findChecklistRangeNearTitle(currentText: currentText, titleRange: $0, label: importantChecklistLabel)
    } ?? rendered.importantChecklistRange

    if let readChecked = captureChecklistValue(
        textArea: context.textArea,
        currentText: currentText,
        range: readRange,
        expectedLabel: readChecklistLabel
    ) {
        if readChecked {
            state.readFingerprint = rendered.fingerprint
            state.readAt = digest.generatedAt
        } else if state.readFingerprint == rendered.fingerprint {
            state.readFingerprint = nil
            state.readAt = nil
        }
    }

    if let importantChecked = captureChecklistValue(
        textArea: context.textArea,
        currentText: currentText,
        range: importantRange,
        expectedLabel: importantChecklistLabel
    ) {
        state.important = importantChecked
        state.importantAt = importantChecked ? digest.generatedAt : nil
    }

    userState.notices[rendered.noticeId] = state
}

userState.updatedAt = digest.generatedAt
writeJSON(userState, path: arguments.noticeStatePath)

let readCount = userState.notices.values.reduce(into: 0) { count, state in
    let fingerprint = state.fingerprint ?? ""
    if !fingerprint.isEmpty, state.readFingerprint == fingerprint {
        count += 1
    }
}
let importantCount = userState.notices.values.reduce(into: 0) { count, state in
    if state.important == true {
        count += 1
    }
}

print("Captured native notice note state: \(arguments.noteTitle) read=\(readCount) important=\(importantCount)")
