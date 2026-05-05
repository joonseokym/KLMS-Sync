#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

const REMINDER_MARKER_PREFIX = "KLMS_SYNC_ITEM_ID:";
const LEGACY_REMINDER_MARKER_PREFIXES = ["KLMS_ASSIGN_ID:"];
const REMINDER_MARKER_PREFIXES = [REMINDER_MARKER_PREFIX].concat(LEGACY_REMINDER_MARKER_PREFIXES);
const ALERT_STAGES = [
  { key: "1d", seconds: 24 * 3600, label: "1일 전" },
  { key: "2h", seconds: 2 * 3600, label: "2시간 전" },
];

function run(argv) {
  const scriptDir = currentDirectory();
  const configPath = argv.length > 0 ? argv[0] : `${scriptDir}/config.env`;
  const statePath =
    argv.length > 1 ? argv[1] : `${scriptDir}/runtime/automation/reminder_alert_state.json`;
  const config = parseEnvFile(configPath);
  if (config.REMINDERS_SYNC_ENABLED !== "1") {
    return "status=skipped reminders-disabled";
  }

  ensureDir(parentDirectory(statePath));

  const remindersApp = Application("/System/Applications/Reminders.app");
  const currentApp = Application.currentApplication();
  currentApp.includeStandardAdditions = true;
  const listName = config.REMINDERS_LIST_NAME || "KLMS 과제";
  const list = findReminderList(remindersApp, listName);
  if (!list) {
    return `status=skipped list-missing name=${listName}`;
  }

  const state = loadState(statePath);
  const now = new Date();
  const lastCheckedAt = parseStateDate(state.lastCheckedAt) || now;
  const entries = state.entries || {};
  const activeKeys = {};
  let monitored = 0;
  let notified = 0;

  const listId = safeString(() => list.id());
  const reminders = remindersApp
    .reminders()
    .filter((item) => safeString(() => item.container().id()) === listId)
    .filter((item) => extractIdentifierFromText(safeString(() => item.body())))
    .filter((item) => !safeValue(() => item.completed()));

  reminders.forEach((reminder) => {
    const identifier = extractIdentifierFromText(safeString(() => reminder.body()));
    const dueDate = safeDate(() => reminder.dueDate());
    if (!identifier || !dueDate || dueDate.getTime() <= now.getTime()) {
      return;
    }

    monitored += 1;
    const reminderKey = `${identifier}|${dueDate.toISOString()}`;
    activeKeys[reminderKey] = true;

    const entry = normalizeEntry(entries[reminderKey]);
    const crossedStages = ALERT_STAGES.filter((stage) => {
      if (entry.sentStages[stage.key]) {
        return false;
      }
      const alertAt = new Date(dueDate.getTime() - stage.seconds * 1000);
      return alertAt.getTime() > lastCheckedAt.getTime() && alertAt.getTime() <= now.getTime();
    });

    if (crossedStages.length > 0) {
      const stageToNotify = crossedStages.sort((lhs, rhs) => lhs.seconds - rhs.seconds)[0];
      currentApp.displayNotification(`마감 ${formatSeoulDate(dueDate)}`, {
        withTitle: "KLMS 과제 알림",
        subtitle: `${stageToNotify.label}: ${safeString(() => reminder.name())}`,
      });
      notified += 1;

      crossedStages.forEach((stage) => {
        entry.sentStages[stage.key] = now.toISOString();
      });
    }

    entries[reminderKey] = entry;
  });

  Object.keys(entries).forEach((key) => {
    if (!activeKeys[key]) {
      delete entries[key];
    }
  });

  writeText(
    statePath,
    JSON.stringify(
      {
        lastCheckedAt: now.toISOString(),
        entries,
      },
      null,
      2
    )
  );

  return `status=ok notified=${notified} monitored=${monitored}`;
}

function findReminderList(remindersApp, listName) {
  const matches = remindersApp
    .lists()
    .filter((list) => safeString(() => list.name()) === listName);
  if (matches.length > 1) {
    throw new Error(`Multiple reminders lists found for '${listName}'.`);
  }
  return matches.length === 1 ? matches[0] : null;
}

function normalizeEntry(entry) {
  if (!entry || typeof entry !== "object") {
    return { sentStages: {} };
  }
  return {
    sentStages: entry.sentStages && typeof entry.sentStages === "object" ? entry.sentStages : {},
  };
}

function loadState(path) {
  try {
    return JSON.parse(readText(path));
  } catch (error) {
    return {};
  }
}

function parseStateDate(value) {
  if (!value) {
    return null;
  }
  const parsed = new Date(String(value));
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function formatSeoulDate(date) {
  return [
    date.getFullYear(),
    "-",
    pad2(date.getMonth() + 1),
    "-",
    pad2(date.getDate()),
    " ",
    pad2(date.getHours()),
    ":",
    pad2(date.getMinutes()),
    " KST",
  ].join("");
}

function pad2(value) {
  return value < 10 ? `0${value}` : String(value);
}

function extractIdentifierFromText(text) {
  const lines = String(text || "").split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    for (let j = 0; j < REMINDER_MARKER_PREFIXES.length; j += 1) {
      if (lines[i].startsWith(REMINDER_MARKER_PREFIXES[j])) {
        return lines[i].slice(REMINDER_MARKER_PREFIXES[j].length);
      }
    }
  }
  return "";
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (error) {
    return "";
  }
}

function safeValue(getter) {
  try {
    return getter();
  } catch (error) {
    return null;
  }
}

function safeDate(getter) {
  const value = safeValue(getter);
  if (!value) {
    return null;
  }
  return value instanceof Date ? value : new Date(value);
}

function parseEnvFile(path) {
  const content = readText(path);
  const config = {};

  content.split(/\r?\n/).forEach((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      return;
    }

    const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) {
      return;
    }

    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    config[match[1]] = value;
  });

  return config;
}

function ensureDir(path) {
  runCommand(["/bin/mkdir", "-p", path], currentDirectory());
}

function parentDirectory(path) {
  return ObjC.unwrap($(path).stringByStandardizingPath.stringByDeletingLastPathComponent);
}

function readText(path) {
  const nsPath = $(path).stringByStandardizingPath;
  const error = Ref();
  const text = $.NSString.stringWithContentsOfFileEncodingError(
    nsPath,
    $.NSUTF8StringEncoding,
    error
  );
  if (!text) {
    throw new Error(
      `Failed to read ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`
    );
  }
  return ObjC.unwrap(text);
}

function writeText(path, text) {
  const nsPath = $(path).stringByStandardizingPath;
  const nsText = $(text);
  const error = Ref();
  const ok = nsText.writeToFileAtomicallyEncodingError(
    nsPath,
    true,
    $.NSUTF8StringEncoding,
    error
  );
  if (!ok) {
    throw new Error(
      `Failed to write ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`
    );
  }
}

function currentDirectory() {
  return ObjC.unwrap($.NSFileManager.defaultManager.currentDirectoryPath);
}

function runCommand(argv, cwd) {
  const task = $.NSTask.alloc.init;
  task.setLaunchPath($(argv[0]));
  task.setArguments($(argv.slice(1)));
  if (cwd) {
    task.setCurrentDirectoryPath($(cwd));
  }

  const stdoutPipe = $.NSPipe.pipe;
  const stderrPipe = $.NSPipe.pipe;
  task.setStandardOutput(stdoutPipe);
  task.setStandardError(stderrPipe);

  task.launch;
  task.waitUntilExit;

  if (task.terminationStatus !== 0) {
    const stderrText = nsDataToString(stderrPipe.fileHandleForReading.readDataToEndOfFile);
    throw new Error(
      `Command failed (${argv.join(" ")}): ${stderrText.trim() || `exit ${task.terminationStatus}`}`
    );
  }
}

function nsDataToString(data) {
  if (!data || data.length === 0) {
    return "";
  }
  const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  return ObjC.unwrap(text) || "";
}
