import AppKit
import EventKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct KLMSControlCenterApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ControlCenterView()
        .environmentObject(model)
        .frame(minWidth: 1040, minHeight: 700)
        .onAppear {
          model.refresh()
        }
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("설정 새로고침") {
          model.refresh()
        }
        .keyboardShortcut("r", modifiers: [.command])
      }
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  struct SettingsDraft {
    var dashboardURL = "https://klms.kaist.ac.kr/my/"
    var loginURL = "https://klms.kaist.ac.kr/my/"
    var courseFilesRoot = ""
    var termFolder = "auto"
    var safariWaitSeconds = "4"
    var fetchMinWaitSeconds = "1.0"
    var fetchStablePolls = "1"
    var noticeEnabled = false
    var noticeSplitByCourseEnabled = true
    var remindersEnabled = true
    var examCalendarEnabled = true
    var examCalendarName = "시험"
    var helpDeskCalendarEnabled = true
    var helpDeskCalendarName = "기타"
    var keepFreshDownloads = false
    var autoLoginEnabled = false
  }

  enum RunState {
    case idle
    case running(String)
    case success(String)
    case failed(String)

    var title: String {
      switch self {
      case .idle: return "대기 중"
      case .running(let text): return text
      case .success(let text): return text
      case .failed(let text): return text
      }
    }

    var systemImage: String {
      switch self {
      case .idle: return "checkmark.circle"
      case .running: return "arrow.triangle.2.circlepath"
      case .success: return "checkmark.seal"
      case .failed: return "exclamationmark.triangle"
      }
    }

    var tint: Color {
      switch self {
      case .idle: return Color(red: 0.24, green: 0.50, blue: 0.92)
      case .running: return Color(red: 0.76, green: 0.46, blue: 0.16)
      case .success: return Color(red: 0.16, green: 0.56, blue: 0.40)
      case .failed: return Color(red: 0.82, green: 0.22, blue: 0.24)
      }
    }
  }

  @Published var state: RunState = .idle
  @Published var logText: String = ""
  @Published var configExists: Bool = false
  @Published var autoLoginEnabled: Bool = false
  @Published var backgroundSyncEnabled: Bool = false
  @Published var lastExitCode: Int32?
  @Published var projectRoot: URL = AppModel.resolveProjectRoot()
  @Published var progress: Double = 0
  @Published var currentStep: String = "준비됨"
  @Published var runningActionTitle: String = ""
  @Published var showErrorSheet: Bool = false
  @Published var showLogSheet: Bool = false
  @Published var showSettingsSheet: Bool = false
  @Published var errorTitle: String = ""
  @Published var errorLog: String = ""
  @Published var settingsDraft = SettingsDraft()

  private var currentProcess: Process?
  private var activeLogText = ""

  var configURL: URL {
    projectRoot.appendingPathComponent("config.env")
  }

  var exampleConfigURL: URL {
    projectRoot.appendingPathComponent("examples/config.env.example")
  }

  var canRun: Bool {
    currentProcess == nil
  }

  var isRunning: Bool {
    currentProcess != nil
  }

  var courseFilesRootURL: URL {
    let configured = readSetting("FILE_OUTPUT_ROOT")
    if let configured, !configured.isEmpty {
      return URL(fileURLWithPath: configured)
    }
    return projectRoot.appendingPathComponent("course_files")
  }

  static func resolveProjectRoot() -> URL {
    let fileManager = FileManager.default
    let environmentRoot = ProcessInfo.processInfo.environment["KLMS_SYNC_PROJECT_ROOT"]
    if let environmentRoot, fileManager.fileExists(atPath: environmentRoot) {
      return URL(fileURLWithPath: environmentRoot)
    }

    if let configured = Bundle.main.object(forInfoDictionaryKey: "KLMSProjectRoot") as? String,
       fileManager.fileExists(atPath: configured) {
      return URL(fileURLWithPath: configured)
    }

    let bundleURL = Bundle.main.bundleURL
    let candidates = [
      bundleURL.deletingLastPathComponent(),
      bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
      URL(fileURLWithPath: fileManager.currentDirectoryPath)
    ]

    for candidate in candidates {
      if fileManager.fileExists(atPath: candidate.appendingPathComponent("sync_klms_all.sh").path) {
        return candidate
      }
    }

    return URL(fileURLWithPath: fileManager.currentDirectoryPath)
  }

  func refresh() {
    projectRoot = Self.resolveProjectRoot()
    configExists = FileManager.default.fileExists(atPath: configURL.path)
    autoLoginEnabled = readSetting("KAIKEY_AUTO_LOGIN_ENABLED") == "1"
    settingsDraft = loadSettingsDraft()
    refreshBackgroundStatus()
  }

  func createConfigIfNeeded() {
    guard !configExists else { return }
    do {
      try FileManager.default.copyItem(at: exampleConfigURL, to: configURL)
      appendLog("config.env created from examples/config.env.example\n")
      refresh()
    } catch {
      state = .failed("설정 생성 실패")
      appendLog("config.env 생성 실패: \(error.localizedDescription)\n")
    }
  }

  func setAutoLoginEnabled(_ enabled: Bool) {
    do {
      if !configExists {
        createConfigIfNeeded()
      }
      try updateSetting("KAIKEY_AUTO_LOGIN_ENABLED", value: enabled ? "1" : "0")
      autoLoginEnabled = enabled
      appendLog("KAIKEY_AUTO_LOGIN_ENABLED=\(enabled ? "1" : "0")\n")
    } catch {
      autoLoginEnabled = !enabled
      state = .failed("자동 로그인 설정 실패")
      appendLog("자동 로그인 설정 실패: \(error.localizedDescription)\n")
    }
  }

  func openSettings() {
    if !configExists {
      createConfigIfNeeded()
    }
    settingsDraft = loadSettingsDraft()
    showSettingsSheet = true
  }

  func saveSettings() {
    do {
      if !configExists {
        createConfigIfNeeded()
      }
      try updateSetting("KLMS_DASHBOARD_URL", value: settingsDraft.dashboardURL)
      try updateSetting("KLMS_LOGIN_URL", value: settingsDraft.loginURL)
      try updateSetting("FILE_OUTPUT_ROOT", value: settingsDraft.courseFilesRoot)
      try updateSetting("FILE_TERM_FOLDER", value: settingsDraft.termFolder.isEmpty ? "auto" : settingsDraft.termFolder)
      try updateSetting("SAFARI_WAIT_SECONDS", value: settingsDraft.safariWaitSeconds)
      try updateSetting("FETCH_MIN_WAIT_SECONDS", value: settingsDraft.fetchMinWaitSeconds)
      try updateSetting("FETCH_STABLE_POLLS", value: settingsDraft.fetchStablePolls)
      try updateSetting("NOTICE_SUMMARY_ENABLED", value: settingsDraft.noticeEnabled ? "1" : "0")
      try updateSetting("NOTICE_SPLIT_BY_COURSE_ENABLED", value: settingsDraft.noticeSplitByCourseEnabled ? "1" : "0")
      try updateSetting("REMINDERS_SYNC_ENABLED", value: settingsDraft.remindersEnabled ? "1" : "0")
      try updateSetting("EXAM_CALENDAR_SYNC_ENABLED", value: settingsDraft.examCalendarEnabled ? "1" : "0")
      try updateSetting("EXAM_CALENDAR_NAME", value: settingsDraft.examCalendarName)
      try updateSetting("HELP_DESK_CALENDAR_SYNC_ENABLED", value: settingsDraft.helpDeskCalendarEnabled ? "1" : "0")
      try updateSetting("HELP_DESK_CALENDAR_NAME", value: settingsDraft.helpDeskCalendarName)
      try updateSetting("FILE_KEEP_FRESH_DOWNLOADS", value: settingsDraft.keepFreshDownloads ? "1" : "0")
      try updateSetting("KAIKEY_AUTO_LOGIN_ENABLED", value: settingsDraft.autoLoginEnabled ? "1" : "0")
      autoLoginEnabled = settingsDraft.autoLoginEnabled
      showSettingsSheet = false
      state = .success("설정 저장됨")
      currentStep = "설정이 저장되었습니다"
      refresh()
    } catch {
      presentError(title: "설정 저장 실패", log: error.localizedDescription)
    }
  }

  func chooseCourseFilesRoot() {
    let panel = NSOpenPanel()
    panel.title = "파일 저장 폴더 선택"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      settingsDraft.courseFilesRoot = url.path
    }
  }

  func runDefaultSync() {
    runWithCalendarPreflight {
      self.runScript("run_all.sh", title: "기본 동기화 실행 중")
    }
  }

  func runCoreSync() {
    runWithCalendarPreflight {
      self.runScript("sync_klms_core.sh", title: "KLMS 동기화 실행 중")
    }
  }

  func runNoticeSync() {
    runScript("sync_klms_notice.sh", title: "공지 정리 실행 중")
  }

  func runFilesSync() {
    runScript("refresh_course_files.sh", title: "파일 정리 실행 중")
  }

  func runFullSync() {
    runWithCalendarPreflight {
      self.runScript("run_all_full.sh", title: "전체 동기화 실행 중")
    }
  }

  func runVerification() {
    runWithCalendarPreflight {
      self.runScript("verify_sync_state.sh", title: "상태 점검 실행 중")
    }
  }

  func runAutoLoginNow() {
    runScript("kaikey_auto_login.sh", title: "Kaikey 자동 로그인 실행 중")
  }

  func registerKaikeyDevice() {
    let panel = NSOpenPanel()
    panel.title = "Kaikey QR 스크린샷 선택"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image]

    guard panel.runModal() == .OK, let url = panel.url else { return }
    runScript("kaikey_setup.sh", arguments: ["--config", configURL.path, "--qr-image", url.path], title: "Kaikey 기기 등록 중", includeConfigArgument: false)
  }

  func openSafariLogin() {
    let loginURL = readSetting("KLMS_LOGIN_URL")
      ?? readSetting("KLMS_DASHBOARD_URL")
      ?? "https://klms.kaist.ac.kr/my/"
    runCommand("/usr/bin/open", arguments: ["-a", "Safari", loginURL], title: "Safari 로그인 열기")
  }

  func openConfig() {
    openSettings()
  }

  func openRuntimeLogs() {
    let logsURL = projectRoot.appendingPathComponent("runtime/logs")
    if FileManager.default.fileExists(atPath: logsURL.path) {
      NSWorkspace.shared.open(logsURL)
    } else {
      NSWorkspace.shared.open(projectRoot.appendingPathComponent("runtime"))
    }
  }

  func openCourseFilesFolder() {
    let url = courseFilesRootURL
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      NSWorkspace.shared.open(url)
    } catch {
      presentError(title: "폴더 열기 실패", log: error.localizedDescription)
    }
  }

  func enableBackgroundSync() {
    runScript("install_launch_agent.sh", title: "백그라운드 자동 실행 켜는 중", includeConfigArgument: false) { [weak self] code in
      self?.backgroundSyncEnabled = code == 0
      self?.refreshBackgroundStatus()
    }
  }

  func disableBackgroundSync() {
    let label = readSetting("KLMS_LAUNCHD_LABEL") ?? "com.local.klms-notes-sync"
    let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist"
    runCommand("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", plistPath], title: "백그라운드 자동 실행 끄는 중") { [weak self] _ in
      self?.backgroundSyncEnabled = false
      self?.refreshBackgroundStatus()
    }
  }

  func clearLog() {
    logText = ""
  }

  func showLogs() {
    showLogSheet = true
  }

  func requestCalendarAccess() {
    requestCalendarAccessIfNeeded { _ in }
  }

  private func runWithCalendarPreflight(_ work: @escaping () -> Void) {
    guard calendarSyncIsEnabled() else {
      work()
      return
    }
    requestCalendarAccessIfNeeded { granted in
      if granted {
        work()
      }
    }
  }

  private func calendarSyncIsEnabled() -> Bool {
    let examEnabled = readSetting("EXAM_CALENDAR_SYNC_ENABLED") ?? "1"
    let helpDeskEnabled = readSetting("HELP_DESK_CALENDAR_SYNC_ENABLED") ?? "1"
    return examEnabled != "0" || helpDeskEnabled == "1"
  }

  private func requestCalendarAccessIfNeeded(completion: @escaping (Bool) -> Void) {
    let status = EKEventStore.authorizationStatus(for: .event)
    if calendarStatusGrantsFullAccess(status) {
      completion(true)
      return
    }

    if status == .denied || status == .restricted {
      state = .failed("Calendar 권한 필요")
      appendLog(
        """
        Calendar access was not granted.
        macOS 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 KLMS Sync 접근을 허용한 뒤 다시 실행해 주세요.

        """
      )
      completion(false)
      return
    }

    state = .running("Calendar 권한 요청 중")
    let store = EKEventStore()
    if #available(macOS 14.0, *) {
      store.requestFullAccessToEvents { [weak self] granted, error in
        DispatchQueue.main.async {
          self?.handleCalendarAccessResult(granted: granted, error: error, completion: completion)
        }
      }
    } else {
      store.requestAccess(to: .event) { [weak self] granted, error in
        DispatchQueue.main.async {
          self?.handleCalendarAccessResult(granted: granted, error: error, completion: completion)
        }
      }
    }
  }

  private func handleCalendarAccessResult(
    granted: Bool,
    error: Error?,
    completion: @escaping (Bool) -> Void
  ) {
    if granted {
      state = .success("Calendar 권한 허용됨")
      appendLog("Calendar access granted.\n")
      completion(true)
      return
    }

    state = .failed("Calendar 권한 필요")
    if let error {
      appendLog("Calendar access failed: \(error.localizedDescription)\n")
    }
    appendLog("Calendar access was not granted. 시스템 설정에서 KLMS Sync의 Calendar 접근을 허용해 주세요.\n")
    completion(false)
  }

  private func calendarStatusGrantsFullAccess(_ status: EKAuthorizationStatus) -> Bool {
    if #available(macOS 14.0, *) {
      return status == .fullAccess
    }
    return status == .authorized
  }

  private func runScript(
    _ scriptName: String,
    arguments: [String] = [],
    title: String,
    includeConfigArgument: Bool = true,
    completion: ((Int32) -> Void)? = nil
  ) {
    let scriptURL = projectRoot.appendingPathComponent(scriptName)
    var scriptArguments = [scriptURL.path]
    if includeConfigArgument {
      scriptArguments.append(configURL.path)
    }
    scriptArguments.append(contentsOf: arguments)
    runCommand("/bin/zsh", arguments: scriptArguments, title: title, completion: completion)
  }

  private func runCommand(
    _ executablePath: String,
    arguments: [String],
    title: String,
    completion: ((Int32) -> Void)? = nil
  ) {
    guard currentProcess == nil else {
      appendLog("이미 실행 중인 작업이 있어요.\n")
      return
    }

    if !configExists && !title.contains("설정") && !title.contains("Safari") {
      createConfigIfNeeded()
    }

    lastExitCode = nil
    progress = 0.03
    currentStep = "작업 준비 중"
    runningActionTitle = title
    activeLogText = ""
    state = .running(title)
    appendLog("\n$ \(executablePath) \(arguments.map(shellQuoted).joined(separator: " "))\n")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = projectRoot
    process.environment = ProcessInfo.processInfo.environment.merging([
      "KLMS_SYNC_PROJECT_ROOT": projectRoot.path
    ]) { _, newValue in newValue }

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async {
        self?.appendLog(text)
      }
    }

    process.terminationHandler = { [weak self] process in
      outputPipe.fileHandleForReading.readabilityHandler = nil
      DispatchQueue.main.async {
        self?.currentProcess = nil
        self?.lastExitCode = process.terminationStatus
        if process.terminationStatus == 0 {
          self?.state = .success("완료")
          self?.progress = 1
          self?.currentStep = "완료"
        } else {
          self?.state = .failed("실패: \(process.terminationStatus)")
          self?.currentStep = "문제가 발생했습니다"
          self?.presentError(
            title: "작업 실패",
            log: self?.activeLogText ?? self?.logText ?? ""
          )
        }
        self?.appendLog("\nexit \(process.terminationStatus)\n")
        completion?(process.terminationStatus)
        self?.refresh()
      }
    }

    do {
      currentProcess = process
      try process.run()
    } catch {
      currentProcess = nil
      state = .failed("실행 실패")
      let message = "실행 실패: \(error.localizedDescription)\n"
      appendLog(message)
      presentError(title: "실행 실패", log: message)
      completion?(1)
    }
  }

  private func refreshBackgroundStatus() {
    let label = readSetting("KLMS_LAUNCHD_LABEL") ?? "com.local.klms-notes-sync"
    DispatchQueue.global(qos: .utility).async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["print", "gui/\(getuid())/\(label)"]
      process.standardOutput = Pipe()
      process.standardError = Pipe()

      do {
        try process.run()
        process.waitUntilExit()
        let enabled = process.terminationStatus == 0
        DispatchQueue.main.async {
          self.backgroundSyncEnabled = enabled
        }
      } catch {
        DispatchQueue.main.async {
          self.backgroundSyncEnabled = false
        }
      }
    }
  }

  private func appendLog(_ text: String) {
    activeLogText += text
    logText += text
    if logText.count > 80_000 {
      logText = String(logText.suffix(60_000))
    }
    updateProgress(from: text)
  }

  private func presentError(title: String, log: String) {
    errorTitle = title
    errorLog = log.isEmpty ? "로그가 비어 있습니다." : String(log.suffix(30_000))
    showErrorSheet = true
  }

  private func updateProgress(from text: String) {
    let lower = text.lowercased()
    let checkpoints: [(String, Double, String)] = [
      ("klms-login-preflight", 0.08, "Safari 로그인 확인 중"),
      ("== core start", 0.14, "과제와 시험 정보를 읽는 중"),
      ("dashboard-fetch", 0.22, "KLMS 대시보드 분석 중"),
      ("course-fetch", 0.34, "강좌 페이지 수집 중"),
      ("supplemental-primary-fetch", 0.46, "공지와 보조 자료 확인 중"),
      ("detail", 0.58, "상세 페이지 확인 중"),
      ("calendar-sync", 0.72, "Calendar 업데이트 중"),
      ("status=ok scope=core", 0.78, "KLMS 동기화 완료"),
      ("== notice start", 0.82, "공지 정리 중"),
      ("scope=notice", 0.88, "공지 정리 확인 중"),
      ("manifest build start", 0.34, "파일 목록 만드는 중"),
      ("download start", 0.58, "첨부파일 다운로드 중"),
      ("prune start", 0.82, "파일 폴더 정리 중"),
      ("status=ok", 0.95, "마무리 중")
    ]

    for (needle, value, label) in checkpoints where lower.contains(needle) {
      progress = max(progress, value)
      currentStep = label
    }

    if lower.contains("failed") || lower.contains("traceback") || lower.contains("error:") {
      currentStep = "문제가 발생했습니다"
    }
  }

  private func loadSettingsDraft() -> SettingsDraft {
    SettingsDraft(
      dashboardURL: readSetting("KLMS_DASHBOARD_URL") ?? "https://klms.kaist.ac.kr/my/",
      loginURL: readSetting("KLMS_LOGIN_URL") ?? "https://klms.kaist.ac.kr/my/",
      courseFilesRoot: readSetting("FILE_OUTPUT_ROOT") ?? projectRoot.appendingPathComponent("course_files").path,
      termFolder: readSetting("FILE_TERM_FOLDER") ?? "auto",
      safariWaitSeconds: readSetting("SAFARI_WAIT_SECONDS") ?? "4",
      fetchMinWaitSeconds: readSetting("FETCH_MIN_WAIT_SECONDS") ?? "1.0",
      fetchStablePolls: readSetting("FETCH_STABLE_POLLS") ?? "1",
      noticeEnabled: readSetting("NOTICE_SUMMARY_ENABLED") == "1",
      noticeSplitByCourseEnabled: readSetting("NOTICE_SPLIT_BY_COURSE_ENABLED") != "0",
      remindersEnabled: readSetting("REMINDERS_SYNC_ENABLED") != "0",
      examCalendarEnabled: readSetting("EXAM_CALENDAR_SYNC_ENABLED") != "0",
      examCalendarName: readSetting("EXAM_CALENDAR_NAME") ?? "시험",
      helpDeskCalendarEnabled: readSetting("HELP_DESK_CALENDAR_SYNC_ENABLED") == "1",
      helpDeskCalendarName: readSetting("HELP_DESK_CALENDAR_NAME") ?? "기타",
      keepFreshDownloads: readSetting("FILE_KEEP_FRESH_DOWNLOADS") == "1",
      autoLoginEnabled: readSetting("KAIKEY_AUTO_LOGIN_ENABLED") == "1"
    )
  }

  private func readSetting(_ key: String) -> String? {
    guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
    for rawLine in content.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), line.hasPrefix("\(key)=") else { continue }
      var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value.removeFirst()
        value.removeLast()
      }
      return value.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }
    return nil
  }

  private func updateSetting(_ key: String, value: String) throws {
    let quotedValue = "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    var content = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    var lines = content.components(separatedBy: .newlines)
    var didUpdate = false

    for index in lines.indices {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("\(key)=") {
        lines[index] = "\(key)=\(quotedValue)"
        didUpdate = true
        break
      }
    }

    if !didUpdate {
      if !content.hasSuffix("\n") && !content.isEmpty {
        lines.append("")
      }
      lines.append("\(key)=\(quotedValue)")
    }

    content = lines.joined(separator: "\n")
    if !content.hasSuffix("\n") {
      content += "\n"
    }
    try content.write(to: configURL, atomically: true, encoding: .utf8)
  }

  private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

struct ControlCenterView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 0) {
      SidebarView()
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HeaderView()
          ProgressHeroView()
          QuickActionsView()
          AutomationView()
          SettingsPreviewView()
        }
        .padding(24)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .sheet(isPresented: $model.showErrorSheet) {
      ErrorSheetView()
        .environmentObject(model)
    }
    .sheet(isPresented: $model.showLogSheet) {
      LogSheetView()
        .environmentObject(model)
    }
    .sheet(isPresented: $model.showSettingsSheet) {
      SettingsSheetView()
        .environmentObject(model)
    }
  }
}

struct SidebarView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 10) {
        Image(systemName: "calendar.badge.clock")
          .font(.system(size: 36, weight: .semibold))
          .foregroundStyle(Color(red: 0.38, green: 0.70, blue: 0.92))

        VStack(alignment: .leading, spacing: 4) {
          Text("KLMS Sync")
            .font(.system(size: 26, weight: .bold, design: .rounded))
          Text("Control Center")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }

      StatusPill(state: model.state)

      VStack(alignment: .leading, spacing: 12) {
        SidebarMetric(title: "설정", value: model.configExists ? "준비됨" : "필요", image: "slider.horizontal.3")
        SidebarMetric(title: "자동 로그인", value: model.autoLoginEnabled ? "켜짐" : "꺼짐", image: "key.fill")
        SidebarMetric(title: "백그라운드", value: model.backgroundSyncEnabled ? "켜짐" : "꺼짐", image: "clock.arrow.circlepath")
      }

      Spacer()

      VStack(alignment: .leading, spacing: 8) {
        Button {
          model.openSettings()
        } label: {
          Label("설정", systemImage: "slider.horizontal.3")
        }
        Button {
          model.openCourseFilesFolder()
        } label: {
          Label("파일 폴더", systemImage: "folder")
        }
        Button {
          model.showLogs()
        } label: {
          Label("세부 로그", systemImage: "doc.text.magnifyingglass")
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 260)
    .background(
      ZStack {
        Color(nsColor: .underPageBackgroundColor)
        VStack {
          Rectangle()
            .fill(Color(red: 0.14, green: 0.30, blue: 0.46).opacity(0.16))
            .frame(height: 160)
          Spacer()
        }
      }
    )
  }
}

struct HeaderView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 6) {
          Text("동기화 대시보드")
            .font(.system(size: 30, weight: .bold))
          Text("KLMS 자료, 일정, 리마인더를 한 곳에서 정리합니다")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        Button {
          model.refresh()
        } label: {
          Label("새로고침", systemImage: "arrow.clockwise")
        }
        Button {
          model.openSettings()
        } label: {
          Label("설정", systemImage: "slider.horizontal.3")
        }
      }

      if !model.configExists {
        NoticeBanner(
          title: "config.env가 없습니다",
          systemImage: "exclamationmark.triangle.fill",
          tint: Color(red: 0.82, green: 0.44, blue: 0.18)
        ) {
          Button("예시 설정 만들기") {
            model.createConfigIfNeeded()
          }
        }
      }
    }
  }
}

struct ProgressHeroView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 16) {
        ZStack {
          Circle()
            .stroke(Color.primary.opacity(0.08), lineWidth: 12)
          Circle()
            .trim(from: 0, to: max(0.04, model.progress))
            .stroke(model.state.tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            .rotationEffect(.degrees(-90))
          Text("\(Int(model.progress * 100))%")
            .font(.system(size: 22, weight: .bold, design: .rounded))
        }
        .frame(width: 104, height: 104)

        VStack(alignment: .leading, spacing: 8) {
          Text(model.isRunning ? model.runningActionTitle : model.state.title)
            .font(.system(size: 24, weight: .bold))
          Text(model.currentStep)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)

          ProgressView(value: model.progress)
            .progressViewStyle(.linear)
            .tint(model.state.tint)
            .frame(maxWidth: 420)
        }

        Spacer()

        Button {
          model.showLogs()
        } label: {
          Label("세부 보기", systemImage: "list.bullet.rectangle")
        }
      }
    }
    .padding(22)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.08, green: 0.20, blue: 0.30).opacity(0.92),
          Color(red: 0.10, green: 0.44, blue: 0.52).opacity(0.88)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .foregroundStyle(.white)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.14), lineWidth: 1)
    )
  }
}

struct QuickActionsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    SectionPanel(title: "작업", subtitle: "원하는 정리 작업을 선택하세요") {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
        ActionButton(title: "한 번에 정리", subtitle: "과제와 공지", image: "play.fill", tint: Color(red: 0.18, green: 0.50, blue: 0.86)) {
          model.runDefaultSync()
        }
        ActionButton(title: "일정 정리", subtitle: "시험, 리마인더", image: "checklist", tint: Color(red: 0.18, green: 0.56, blue: 0.40)) {
          model.runCoreSync()
        }
        ActionButton(title: "공지 정리", subtitle: "공지 메모 갱신", image: "text.badge.checkmark", tint: Color(red: 0.54, green: 0.36, blue: 0.72)) {
          model.runNoticeSync()
        }
        ActionButton(title: "파일 모으기", subtitle: "학기/과목별 저장", image: "tray.and.arrow.down", tint: Color(red: 0.74, green: 0.42, blue: 0.18)) {
          model.runFilesSync()
        }
        ActionButton(title: "전체 동기화", subtitle: "과제 + 공지 + 파일", image: "sparkles", tint: Color(red: 0.12, green: 0.58, blue: 0.66)) {
          model.runFullSync()
        }
        ActionButton(title: "점검", subtitle: "결과 확인", image: "stethoscope", tint: Color(red: 0.55, green: 0.48, blue: 0.30)) {
          model.runVerification()
        }
      }
      .disabled(!model.canRun)
    }
  }
}

struct AutomationView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    SectionPanel(title: "로그인과 자동 실행", subtitle: "수동 로그인을 기본값으로 둡니다") {
      VStack(spacing: 12) {
        HStack(spacing: 12) {
          Button {
            model.requestCalendarAccess()
          } label: {
            Label("Calendar 권한", systemImage: "calendar.badge.checkmark")
              .frame(maxWidth: .infinity)
          }
          .disabled(!model.canRun)

          Button {
            model.openSafariLogin()
          } label: {
            Label("Safari 로그인", systemImage: "safari")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)

          Button {
            model.runAutoLoginNow()
          } label: {
            Label("자동 로그인 실행", systemImage: "key.radiowaves.forward")
              .frame(maxWidth: .infinity)
          }
          .disabled(!model.canRun)

          Button {
            model.registerKaikeyDevice()
          } label: {
            Label("Kaikey 등록", systemImage: "qrcode.viewfinder")
              .frame(maxWidth: .infinity)
          }
          .disabled(!model.canRun)
        }

        ToggleRow(
          title: "Kaikey 자동 로그인",
          subtitle: "KAIKEY_AUTO_LOGIN_ENABLED",
          image: "key.fill",
          isOn: Binding(
            get: { model.autoLoginEnabled },
            set: { model.setAutoLoginEnabled($0) }
          )
        )

        ToggleRow(
          title: "백그라운드 자동 실행",
          subtitle: "LaunchAgent",
          image: "clock.badge.checkmark",
          isOn: Binding(
            get: { model.backgroundSyncEnabled },
            set: { enabled in
              enabled ? model.enableBackgroundSync() : model.disableBackgroundSync()
            }
          )
        )
        .disabled(!model.canRun)
      }
    }
  }
}

struct SettingsPreviewView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    SectionPanel(title: "저장 위치", subtitle: "파일은 학기 폴더와 과목 폴더로 정리됩니다") {
      HStack(spacing: 12) {
        Image(systemName: "folder.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(Color(red: 0.18, green: 0.50, blue: 0.86))
          .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 4) {
          Text(model.courseFilesRootURL.path)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
          Text("예: 26S / 과목명 / 파일명")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }

        Spacer()
        Button {
          model.openCourseFilesFolder()
        } label: {
          Label("폴더 열기", systemImage: "arrow.up.forward.app")
        }
      }
    }
  }
}

struct SectionPanel<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 18, weight: .semibold))
          Text(subtitle)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      content
    }
    .padding(18)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

struct ActionButton: View {
  let title: String
  let subtitle: String
  let image: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: image)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 38, height: 38)
          .background(tint)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 15, weight: .semibold))
          Text(subtitle)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
      }
      .frame(minHeight: 58)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

struct ToggleRow: View {
  let title: String
  let subtitle: String
  let image: String
  @Binding var isOn: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: image)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color(red: 0.24, green: 0.50, blue: 0.92))
        .frame(width: 32, height: 32)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
        Text(subtitle)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      Spacer()
      Toggle("", isOn: $isOn)
        .labelsHidden()
    }
    .padding(12)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

struct StatusPill: View {
  let state: AppModel.RunState

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: state.systemImage)
      Text(state.title)
        .font(.system(size: 14, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(state.tint)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(state.tint.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct SidebarMetric: View {
  let title: String
  let value: String
  let image: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: image)
        .frame(width: 20)
        .foregroundStyle(.secondary)
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.semibold)
    }
    .font(.system(size: 13))
  }
}

struct NoticeBanner<Accessory: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let accessory: Accessory

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
      Text(title)
        .font(.system(size: 14, weight: .semibold))
      Spacer()
      accessory
    }
    .padding(12)
    .background(tint.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct ErrorSheetView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.24))
        VStack(alignment: .leading, spacing: 4) {
          Text(model.errorTitle.isEmpty ? "작업 실패" : model.errorTitle)
            .font(.system(size: 22, weight: .bold))
          Text("아래 세부 내용을 확인해 주세요.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      LogTextBox(text: model.errorLog)

      HStack {
        Button {
          model.openRuntimeLogs()
        } label: {
          Label("로그 폴더 열기", systemImage: "folder")
        }
        Spacer()
        Button("닫기") {
          model.showErrorSheet = false
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 760, height: 520)
  }
}

struct LogSheetView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("세부 로그")
            .font(.system(size: 22, weight: .bold))
          Text(model.lastExitCode.map { "최근 종료 코드: \($0)" } ?? "최근 작업 로그")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("닫기") {
          model.showLogSheet = false
        }
      }

      LogTextBox(text: model.logText.isEmpty ? "아직 실행 로그가 없습니다." : model.logText)
    }
    .padding(24)
    .frame(width: 820, height: 560)
  }
}

struct SettingsSheetView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("설정")
            .font(.system(size: 24, weight: .bold))
          Text("변경 사항은 config.env에 저장됩니다.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          SettingsGroup(title: "KLMS") {
            SettingsTextField(title: "대시보드 URL", text: $model.settingsDraft.dashboardURL)
            SettingsTextField(title: "로그인 URL", text: $model.settingsDraft.loginURL)
          }

          SettingsGroup(title: "파일 저장") {
            HStack {
              SettingsTextField(title: "저장 폴더", text: $model.settingsDraft.courseFilesRoot)
              Button {
                model.chooseCourseFilesRoot()
              } label: {
                Image(systemName: "folder")
              }
            }
            SettingsTextField(title: "학기 폴더", text: $model.settingsDraft.termFolder)
            Text("auto는 현재 날짜 기준으로 26S, 25F처럼 계산합니다.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
            Toggle("다운로드 보관 사본 유지", isOn: $model.settingsDraft.keepFreshDownloads)
          }

          SettingsGroup(title: "동기화") {
            Toggle("공지 정리 사용", isOn: $model.settingsDraft.noticeEnabled)
            Toggle("공지 메모를 학기/과목별로 나누기", isOn: $model.settingsDraft.noticeSplitByCourseEnabled)
            Toggle("Reminders 동기화", isOn: $model.settingsDraft.remindersEnabled)
            Toggle("시험 Calendar 동기화", isOn: $model.settingsDraft.examCalendarEnabled)
            SettingsTextField(title: "시험 캘린더", text: $model.settingsDraft.examCalendarName)
            Toggle("헬프데스크 Calendar 동기화", isOn: $model.settingsDraft.helpDeskCalendarEnabled)
            SettingsTextField(title: "헬프데스크 캘린더", text: $model.settingsDraft.helpDeskCalendarName)
          }

          SettingsGroup(title: "로그인") {
            Toggle("Kaikey 자동 로그인", isOn: $model.settingsDraft.autoLoginEnabled)
          }

          SettingsGroup(title: "속도") {
            SettingsTextField(title: "Safari 최대 대기 시간(초)", text: $model.settingsDraft.safariWaitSeconds)
            SettingsTextField(title: "최소 안정화 대기(초)", text: $model.settingsDraft.fetchMinWaitSeconds)
            SettingsTextField(title: "안정화 확인 횟수", text: $model.settingsDraft.fetchStablePolls)
            Text("낮을수록 빨라지지만 KLMS 페이지가 느린 날에는 일부 페이지를 다시 시도할 수 있습니다.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
      }

      HStack {
        Button("취소") {
          model.showSettingsSheet = false
        }
        Spacer()
        Button {
          model.saveSettings()
        } label: {
          Label("저장", systemImage: "checkmark")
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 760, height: 660)
  }
}

struct SettingsGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }
}

struct SettingsTextField: View {
  let title: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      TextField(title, text: $text)
        .textFieldStyle(.roundedBorder)
    }
  }
}

struct LogTextBox: View {
  let text: String

  var body: some View {
    ScrollView {
      Text(text)
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(14)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}
