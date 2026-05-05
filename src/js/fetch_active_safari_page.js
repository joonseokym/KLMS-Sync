#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

function run(argv) {
  const waitArg = argv.find((arg) => arg.startsWith("--wait="));
  const outArg = argv.find((arg) => arg.startsWith("--out="));
  const waitSeconds = waitArg ? Number(waitArg.replace("--wait=", "")) : 6;
  const outPath = outArg ? outArg.replace("--out=", "") : "";

  if (!Number.isFinite(waitSeconds) || waitSeconds <= 0) {
    throw new Error(`Invalid wait seconds: ${waitArg}`);
  }

  const safari = Application("/Applications/Safari.app");
  safari.launch();

  const frontWindow = safeValue(() => safari.windows()[0]);
  if (!frontWindow) {
    throw new Error("Safari has no open windows.");
  }

  const tab = safeValue(() => frontWindow.currentTab());
  if (!tab) {
    throw new Error("Safari current tab is unavailable.");
  }

  const page = waitForPage(tab, waitSeconds);
  page.requestedUrl = page.url;
  const payload = JSON.stringify([page], null, 2);

  if (outPath) {
    writeText(outPath, payload);
    return `Wrote active page to ${outPath}`;
  }

  return payload;
}

function waitForPage(tab, waitSeconds) {
  const deadline = Date.now() + waitSeconds * 1000;
  let stableCount = 0;
  let lastSignature = "";
  let latest = {
    url: "",
    title: "",
    html: "",
  };

  while (Date.now() < deadline) {
    delay(0.5);
    latest = readTab(tab);

    const signature = `${latest.url}\n${latest.title}\n${latest.html.length}`;
    if (latest.html && signature === lastSignature) {
      stableCount += 1;
    } else {
      stableCount = 0;
      lastSignature = signature;
    }

    if (latest.html && latest.url && stableCount >= 2) {
      return latest;
    }
  }

  return latest;
}

function readTab(tab) {
  return {
    url: safeString(() => tab.url()),
    title: safeString(() => tab.name()),
    html: safeString(() => tab.source()),
  };
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (_error) {
    return "";
  }
}

function safeValue(getter) {
  try {
    return getter();
  } catch (_error) {
    return null;
  }
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
    throw new Error(`Failed to write ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`);
  }
}
