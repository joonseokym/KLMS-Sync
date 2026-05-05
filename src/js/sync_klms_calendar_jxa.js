#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

const CURRENT_MARKER_PREFIX = "KLMS_SYNC_ITEM_ID:";
const LEGACY_MARKER_PREFIXES = ["KLMS_ASSIGN_ID:"];

function run(argv) {
  const args = parseArgs(argv || []);
  const state = JSON.parse(readText(args.stateJson));
  if (state.status !== "ok" || !state.content || state.content.kind !== "success") {
    throw new Error("State is not syncable.");
  }

  const items = (state.content.exam_items || []).concat(state.content.help_desk_items || []);
  const summaries = [];
  const calendarApp = Application("Calendar");

  if (args.examCalendar) {
    summaries.push(
      syncCalendar(calendarApp, args.examCalendar, "exam", items, args.durationMinutes, args.lookbackDays)
    );
  }
  if (args.helpdeskCalendar) {
    summaries.push(
      syncCalendar(
        calendarApp,
        args.helpdeskCalendar,
        "helpdesk",
        items,
        args.durationMinutes,
        args.lookbackDays
      )
    );
  }

  return summaries.join("\n");
}

function parseArgs(argv) {
  if (!argv.length) {
    throw new Error(
      "Usage: sync_klms_calendar_jxa.js <state_json> [--duration-minutes=15] [--lookback-days=365] [--exam-calendar=...] [--helpdesk-calendar=...]"
    );
  }

  const args = {
    stateJson: String(argv[0]),
    durationMinutes: 15,
    lookbackDays: 365,
    examCalendar: "",
    helpdeskCalendar: "",
  };

  argv.slice(1).forEach((arg) => {
    const value = String(arg || "");
    if (value.startsWith("--duration-minutes=")) {
      args.durationMinutes = Number(value.slice("--duration-minutes=".length)) || 15;
    } else if (value.startsWith("--lookback-days=")) {
      args.lookbackDays = Number(value.slice("--lookback-days=".length)) || 365;
    } else if (value.startsWith("--exam-calendar=")) {
      args.examCalendar = value.slice("--exam-calendar=".length);
    } else if (value.startsWith("--helpdesk-calendar=")) {
      args.helpdeskCalendar = value.slice("--helpdesk-calendar=".length);
    } else {
      throw new Error(`Unknown argument: ${value}`);
    }
  });

  return args;
}

function syncCalendar(calendarApp, calendarName, bucket, items, durationMinutes, lookbackDays) {
  const calendarRef = calendarApp.calendars.byName(calendarName);
  if (!calendarRef.exists()) {
    throw new Error(`Calendar does not exist: ${calendarName}`);
  }

  const desiredEvents = buildDesiredEvents(items, bucket, durationMinutes);
  const desiredMarkers = desiredEvents.map((event) => event.marker);
  const windowStart = new Date(Date.now() - Math.max(lookbackDays, 1) * 24 * 3600 * 1000);
  const windowEnd = new Date(Date.now() + 365 * 24 * 3600 * 1000);

  let created = 0;
  let updated = 0;
  let deleted = 0;

  [CURRENT_MARKER_PREFIX].concat(LEGACY_MARKER_PREFIXES).forEach((markerPrefix) => {
    const managedEvents = safeList(() =>
      calendarRef.events.whose({ description: { _contains: markerPrefix } })()
    );
    managedEvents.forEach((eventRef) => {
      const startDate = safeDate(() => eventRef.startDate());
      if (startDate && (startDate < windowStart || startDate > windowEnd)) {
        return;
      }
      const description = safeString(() => eventRef.description());
      const shouldKeep = desiredMarkers.some((marker) => description.includes(marker));
      if (!shouldKeep) {
        eventRef.delete();
        deleted += 1;
      }
    });
  });

  desiredEvents.forEach((desired) => {
    const matchingEvents = safeList(() =>
      calendarRef.events.whose({ description: { _contains: desired.marker } })()
    );
    const eventRef = matchingEvents[0] || null;
    if (eventRef) {
      eventRef.summary = desired.title;
      eventRef.startDate = desired.startDate;
      eventRef.endDate = desired.endDate;
      eventRef.location = desired.location;
      eventRef.description = desired.description;
      updated += 1;
      return;
    }

    calendarRef.events.push(
      calendarApp.Event({
        summary: desired.title,
        startDate: desired.startDate,
        endDate: desired.endDate,
        location: desired.location,
        description: desired.description,
      })
    );
    created += 1;
  });

  return `calendar=${calendarName} bucket=${bucket} created=${created} updated=${updated} deleted=${deleted} total=${desiredEvents.length}`;
}

function buildDesiredEvents(items, bucket, durationMinutes) {
  return items
    .filter((item) => {
      if (bucket === "exam") {
        return item.category === "exam";
      }
      return item.category === "help_desk";
    })
    .map((item) => buildDesiredEvent(item, durationMinutes))
    .filter(Boolean);
}

function buildDesiredEvent(item, durationMinutes) {
  const endDate = parseItemDueDate(item);
  if (!endDate) {
    return null;
  }
  const startDate =
    parseISODate(item.sync_start || "") ||
    new Date(endDate.getTime() - Math.max(durationMinutes, 1) * 60 * 1000);
  const identifier = itemIdentifier(item);
  const kindLabel = eventKindLabel(item);
  const sourceLine = item.source_title ? `\n출처: ${item.source_title}` : "";
  const timingLine = item.timing_precision === "date" ? "\n시간: KLMS에서 날짜만 확인됨" : "";
  const location = item.category === "exam" ? resolveExamLocation(item) : "";
  const coverage = item.category === "exam" ? extractExamCoverage(item.instructions || "") : "";
  const coverageLine = coverage ? `시험 범위: ${coverage}\n` : "";
  const description = `${CURRENT_MARKER_PREFIX}${identifier}
종류: ${kindLabel}
과목: ${item.course || ""}
${kindLabel}: ${item.title || ""}
일정: ${item.due || ""}${timingLine}${sourceLine}
${coverageLine}위치: ${location || ""}
제출 상태: ${item.submission || ""}
메모: ${item.instructions || ""}
링크: ${item.url || ""}
`;
  const titlePrefix = calendarTitlePrefix(item);
  const title = item.course
    ? `${titlePrefix} ${item.course} - ${item.title || ""}`
    : `${titlePrefix} ${item.title || ""}`;

  return {
    marker: `${CURRENT_MARKER_PREFIX}${identifier}`,
    title,
    startDate,
    endDate,
    location,
    description,
  };
}

function extractExamLocation(text) {
  const compact = normalizeWhitespace(text);
  return firstCapture(compact, [
    /(?:시험\s*)?(?:장소|고사장)\s*[:：]\s*(.+?)(?=\s*(?:시험\s*범위|범위|Date\s*&\s*Time|Coverage|Range|Time|Place|Location|$))/i,
    /\b(?:Location|Place|Venue|Room)\s*:\s*(.+?)(?=\s*(?:Range|Coverage|Exam\s*Range|Time|Date\s*&\s*Time|시험\s*범위|시험\s*일시|$))/i,
  ]);
}

function resolveExamLocation(item) {
  const explicitLocation = extractExamLocation(item.instructions || "");
  if (explicitLocation) {
    return explicitLocation;
  }

  const url = String(item.url || "");
  if (/\/mod\/(?:assign|quiz)\/view\.php/i.test(url)) {
    return url;
  }
  return "";
}

function extractExamCoverage(text) {
  const compact = normalizeWhitespace(text);
  return firstCapture(compact, [
    /(?:시험\s*)?범위\s*[:：]\s*(.+?)(?=\s*(?:Date\s*&\s*Time|Location|Place|Venue|Room|Coverage|Range|Time|시험\s*일시|시험\s*장소|$))/i,
    /\b(?:Coverage|Range|Exam\s*Range)\s*:\s*(.+?)(?=\s*(?:[•⦁]|Time|Date\s*&\s*Time|Location|Place|Venue|Room|시험\s*일시|시험\s*장소|$))/i,
  ]);
}

function firstCapture(text, patterns) {
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match && match[1]) {
      return cleanupExtractedField(match[1]);
    }
  }
  return "";
}

function cleanupExtractedField(text) {
  return normalizeWhitespace(text)
    .replace(/[.;,\s]+$/g, "")
    .trim();
}

function normalizeWhitespace(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

function parseItemDueDate(item) {
  return parseISODate(item.sync_due || "") || parseKoreanDueDate(item.due || "");
}

function parseISODate(text) {
  if (!text) {
    return null;
  }
  const date = new Date(text);
  return Number.isNaN(date.getTime()) ? null : date;
}

function parseKoreanDueDate(text) {
  const match = String(text || "").match(
    /(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일.*?(오전|오후)\s*(\d{1,2}):(\d{2})/
  );
  if (!match) {
    return null;
  }
  const year = Number(match[1]);
  const month = Number(match[2]) - 1;
  const day = Number(match[3]);
  let hour = Number(match[5]) % 12;
  const minute = Number(match[6]);
  if (match[4] === "오후") {
    hour += 12;
  }
  return new Date(year, month, day, hour, minute, 0);
}

function itemIdentifier(item) {
  const base = syncItemBaseIdentifier(item.url || "");
  const titlePart = identifierFragment(item.title || "");
  const duePart = identifierFragment(item.sync_due || item.due || "");
  if (item.category === "exam") {
    return `exam:${base}:${titlePart}:${duePart}`;
  }
  if (item.category === "help_desk") {
    return `helpdesk:${base}:${titlePart}:${duePart}`;
  }
  return base;
}

function syncItemBaseIdentifier(url) {
  const match = String(url || "").match(/[?&]id=([^&]+)/);
  return match ? decodeURIComponent(match[1]) : String(url || "");
}

function identifierFragment(text) {
  return encodeURIComponent(String(text || "").trim().toLowerCase()).replace(
    /[!'()*_.~-]/g,
    (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

function eventKindLabel(item) {
  if (item.category === "exam") {
    return "시험 일정";
  }
  if (item.category === "help_desk") {
    return "헬프데스크 안내";
  }
  return "과제";
}

function calendarTitlePrefix(item) {
  if (item.category === "exam") {
    return "[KLMS 시험]";
  }
  if (item.category === "help_desk") {
    return "[KLMS 헬프데스크]";
  }
  return "[KLMS]";
}

function readText(path) {
  const nsPath = $(path).stringByStandardizingPath;
  const error = Ref();
  const text = $.NSString.stringWithContentsOfFileEncodingError(
    nsPath,
    $.NSUTF8StringEncoding,
    error
  );
  if (text == null) {
    throw new Error(`Failed to read ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`);
  }
  return ObjC.unwrap(text);
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (_error) {
    return "";
  }
}

function safeDate(getter) {
  try {
    const value = getter();
    return value instanceof Date ? value : null;
  } catch (_error) {
    return null;
  }
}

function safeList(getter) {
  try {
    const value = getter();
    return Array.isArray(value) ? value : [];
  } catch (_error) {
    return [];
  }
}
