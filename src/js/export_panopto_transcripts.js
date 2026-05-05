#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

function run(argv) {
  const options = parseArgs(argv);
  if (!options.matchTitle || !options.outDir) {
    throw new Error(
      "usage: export_panopto_transcripts.js --match-title TITLE --out-dir DIR"
    );
  }

  const safari = Application("/Applications/Safari.app");
  const tab = findPanoptoSessionListTab(safari, options.matchTitle);
  if (!tab) {
    throw new Error(`No Panopto session list tab matched: ${options.matchTitle}`);
  }

  const raw = safari.doJavaScript(extractionScript(), { in: tab });
  const payload = JSON.parse(String(raw || "[]"));
  const outDir = String(options.outDir);
  ensureDirectory(outDir);

  const indexLines = [
    "# Panopto Transcripts",
    "",
    `Source tab: ${safeString(() => tab.name())}`,
    `Exported at: ${new Date().toISOString()}`,
    "",
  ];

  for (let i = 0; i < payload.length; i += 1) {
    const item = payload[i];
    const baseName = `${String(i + 1).padStart(2, "0")} ${sanitizeFilename(
      item.sessionName || item.deliveryName || item.deliveryId || "session"
    )}`;
    const mdPath = `${outDir}/${baseName}.md`;
    const jsonPath = `${outDir}/${baseName}.captions.json`;
    writeText(mdPath, renderMarkdown(item));
    writeText(jsonPath, JSON.stringify(item, null, 2));
    indexLines.push(
      `- [${item.sessionName || item.deliveryName || item.deliveryId}](${baseName}.md) ` +
        `(${formatDuration(item.duration || 0)}, captions=${(item.captions || []).length})`
    );
  }

  writeText(`${outDir}/index.md`, indexLines.join("\n") + "\n");
  return JSON.stringify({
    status: "ok",
    count: payload.length,
    outDir,
    files: payload.map((item, index) =>
      `${String(index + 1).padStart(2, "0")} ${sanitizeFilename(
        item.sessionName || item.deliveryName || item.deliveryId || "session"
      )}.md`
    ),
  });
}

function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i]);
    if (arg === "--match-title") {
      options.matchTitle = String(argv[++i] || "");
    } else if (arg.startsWith("--match-title=")) {
      options.matchTitle = arg.slice("--match-title=".length);
    } else if (arg === "--out-dir") {
      options.outDir = String(argv[++i] || "");
    } else if (arg.startsWith("--out-dir=")) {
      options.outDir = arg.slice("--out-dir=".length);
    }
  }
  return options;
}

function findPanoptoSessionListTab(safari, matchTitle) {
  const needle = String(matchTitle || "").toLowerCase();
  const windows = safeList(() => safari.windows());
  for (const windowRef of windows) {
    for (const tab of safeList(() => windowRef.tabs())) {
      const url = safeString(() => tab.url()).toLowerCase();
      const name = safeString(() => tab.name()).toLowerCase();
      if (
        url.includes("kaist.ap.panopto.com/panopto/pages/sessions/list.aspx") &&
        name.includes(needle)
      ) {
        return tab;
      }
    }
  }
  return null;
}

function extractionScript() {
  return `
(() => {
  const instance = window.Panopto?.SessionList?.defaultInstance;
  const rows = instance?._resultsDataView?._data || [];

  function postForm(params) {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", "/Panopto/Pages/Viewer/DeliveryInfo.aspx", false);
    xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
    const body = new URLSearchParams(params);
    xhr.send(body.toString());
    if (xhr.status !== 200) {
      throw new Error("Panopto request failed: " + xhr.status);
    }
    return JSON.parse(xhr.responseText || "null");
  }

  function firstCaptionLanguage(info) {
    const captions = info?.Delivery?.AvailableCaptions || info?.AvailableCaptions || [];
    if (captions.length && captions[0].Language !== undefined) {
      return String(captions[0].Language);
    }
    const languages = info?.Delivery?.AvailableLanguages || [];
    return languages.length ? String(languages[0]) : "0";
  }

  return JSON.stringify(rows.map((row) => {
    const deliveryId = row.DeliveryID || row.DeliveryId || row.deliveryId;
    const info = postForm({
      deliveryId,
      isLiveNotes: "false",
      refreshAuthCookie: "false",
      isActiveBroadcast: "false",
      isEditing: "false",
      isKollectiveAgentInstalled: "false",
      isEmbed: "false",
      responseType: "json",
    });
    const language = firstCaptionLanguage(info);
    let captions = [];
    if (info?.Delivery?.HasCaptions || info?.Delivery?.AvailableCaptions?.length) {
      captions = postForm({
        deliveryId,
        getCaptions: "true",
        language,
        responseType: "json",
      }) || [];
    }
    return {
      deliveryId,
      sessionId: row.SessionID || info.SessionId,
      sessionName: row.SessionName || info?.Delivery?.SessionName || "",
      deliveryName: row.DeliveryName || info?.Delivery?.DeliveryName || "",
      folderName: row.FolderName || info?.Delivery?.SessionGroupLongName || "",
      duration: row.Duration || info?.Delivery?.Duration || 0,
      startTime: row.StartTime || info?.Delivery?.SessionStartTime || "",
      viewerUrl: row.ViewerUrl || "",
      embedUrl: row.EmbedUrl || info.EmbedUrl || "",
      hasCaptions: !!(info?.Delivery?.HasCaptions),
      captionLanguage: language,
      chapters: (info?.Delivery?.Timestamps || [])
        .filter((item) => item && item.ShowInTableOfContents && item.Caption)
        .map((item) => ({
          time: item.Time || 0,
          title: item.Caption || "",
          duration: item.Duration || 0,
        })),
      captions,
    };
  }));
})()
`;
}

function renderMarkdown(item) {
  const captions = item.captions || [];
  const chapters = item.chapters || [];
  const lines = [
    `# ${item.sessionName || item.deliveryName || item.deliveryId}`,
    "",
    `Course: ${item.folderName || ""}`,
    `Duration: ${formatDuration(item.duration || 0)}`,
    `Start: ${item.startTime || ""}`,
    `Viewer: ${item.viewerUrl || ""}`,
    `Captions: ${captions.length}`,
    "",
    "## Chapters",
    "",
  ];

  if (chapters.length) {
    for (const chapter of chapters) {
      lines.push(`[${formatDuration(chapter.time || 0)}] ${chapter.title || ""}`);
    }
  } else {
    lines.push("No chapter metadata found.");
  }

  lines.push(
    "",
    "## Transcript",
    ""
  );

  let chapterIndex = 0;
  for (const caption of captions) {
    while (
      chapterIndex < chapters.length &&
      Number(chapters[chapterIndex].time || 0) <= Number(caption.Time || 0)
    ) {
      lines.push("");
      lines.push(
        `### ${formatDuration(chapters[chapterIndex].time || 0)} ${
          chapters[chapterIndex].title || ""
        }`
      );
      lines.push("");
      chapterIndex += 1;
    }
    lines.push(`[${formatDuration(caption.Time || 0)}] ${caption.Caption || ""}`);
  }
  return lines.join("\n") + "\n";
}

function sanitizeFilename(value) {
  return String(value || "session")
    .replace(/[\\/:*?"<>|\n\r\t]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

function formatDuration(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = String(Math.floor(total / 3600)).padStart(2, "0");
  const m = String(Math.floor((total % 3600) / 60)).padStart(2, "0");
  const s = String(total % 60).padStart(2, "0");
  return `${h}:${m}:${s}`;
}

function ensureDirectory(path) {
  const fm = $.NSFileManager.defaultManager;
  const ok = fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
    $(path),
    true,
    $(),
    null
  );
  if (!ok) {
    throw new Error(`Failed to create directory: ${path}`);
  }
}

function writeText(path, text) {
  const ok = $.NSString.alloc
    .initWithUTF8String(String(text))
    .writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, null);
  if (!ok) {
    throw new Error(`Failed to write file: ${path}`);
  }
}

function safeString(fn) {
  try {
    const value = fn();
    return value === undefined || value === null ? "" : String(value);
  } catch (_) {
    return "";
  }
}

function safeList(fn) {
  try {
    const value = fn();
    return value || [];
  } catch (_) {
    return [];
  }
}
