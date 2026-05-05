#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

function run(argv) {
  const options = parseArgs(argv);
  if (!options.manifestPath || !options.outputRoot || !options.downloadsDir || !options.logPath) {
    throw new Error(
      "Usage: download_klms_media_via_safari.js --manifest=/path/manifest.json --output-root=/path --downloads-dir=/path --log=/path/log.json [--timeout=900]"
    );
  }

  const manifestPath = standardizePath(options.manifestPath);
  const outputRoot = standardizePath(options.outputRoot);
  const downloadsDir = standardizePath(options.downloadsDir);
  const logPath = standardizePath(options.logPath);
  const timeoutSeconds = Math.max(30, Number(options.timeoutSeconds || "900"));
  const manifest = readJson(manifestPath);
  if (!Array.isArray(manifest)) {
    throw new Error(`Manifest must be an array: ${manifestPath}`);
  }

  ensureDir(outputRoot);
  ensureDir(downloadsDir);
  ensureDir(directoryName(logPath));

  const safari = Application("/Applications/Safari.app");
  safari.launch();
  delay(0.5);
  const windowRef = resolveWindow(safari);
  const tab = resolveTab(windowRef);
  const results = [];

  manifest.forEach((entry, index) => {
    const relativePath = String(entry.relative_path || entry.filename || `media-${index + 1}.mp4`);
    const destinationPath = standardizePath(joinPath(outputRoot, relativePath));
    ensureDir(directoryName(destinationPath));

    if (isRegularFile(destinationPath)) {
      results.push(resultFor(entry, index, destinationPath, "", "skipped-existing"));
      writeJson(logPath, { manifestPath, outputRoot, downloadsDir, results });
      return;
    }

    const beforeSignatures = directorySignatures(downloadsDir);
    const targetUrl = withForcedDownload(String(entry.url || ""));
    if (!targetUrl) {
      throw new Error(`Missing url for manifest item ${index + 1}`);
    }

    tab.url = targetUrl;
    const downloadedPath = waitForNewMediaFile(downloadsDir, beforeSignatures, timeoutSeconds);
    if (!downloadedPath) {
      throw new Error(`Timed out waiting for media download: ${targetUrl}`);
    }

    copyFile(downloadedPath, destinationPath);
    results.push(resultFor(entry, index, destinationPath, downloadedPath, "fresh-download"));
    writeJson(logPath, { manifestPath, outputRoot, downloadsDir, results });
  });

  const payload = { manifestPath, outputRoot, downloadsDir, results };
  writeJson(logPath, payload);
  return JSON.stringify(payload, null, 2);
}

function parseArgs(argv) {
  const options = {};
  argv.forEach((arg) => {
    if (arg.startsWith("--manifest=")) {
      options.manifestPath = arg.slice("--manifest=".length);
    } else if (arg.startsWith("--output-root=")) {
      options.outputRoot = arg.slice("--output-root=".length);
    } else if (arg.startsWith("--downloads-dir=")) {
      options.downloadsDir = arg.slice("--downloads-dir=".length);
    } else if (arg.startsWith("--log=")) {
      options.logPath = arg.slice("--log=".length);
    } else if (arg.startsWith("--timeout=")) {
      options.timeoutSeconds = arg.slice("--timeout=".length);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  });
  return options;
}

function waitForNewMediaFile(downloadsDir, beforeSignatures, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    delay(1);
    const afterSignatures = directorySignatures(downloadsDir);
    const candidates = Object.keys(afterSignatures).filter((path) => {
      const name = baseName(path);
      if (name.startsWith(".") || name.endsWith(".download")) {
        return false;
      }
      if (!/\.(mp4|m4v|mov|mp3|m4a|wav)$/i.test(name)) {
        return false;
      }
      return beforeSignatures[path] !== afterSignatures[path];
    });

    for (const candidate of candidates) {
      if (isStableFile(candidate)) {
        return candidate;
      }
    }
  }
  return "";
}

function directorySignatures(path) {
  const names = listDirectory(path);
  const signatures = {};
  names.forEach((name) => {
    const candidate = joinPath(path, name);
    if (!fileExists(candidate)) {
      return;
    }
    signatures[candidate] = entrySignature(candidate);
  });
  return signatures;
}

function entrySignature(path) {
  const error = Ref();
  const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(
    $(path).stringByStandardizingPath,
    error
  );
  if (!attributes) {
    return "";
  }
  const size = Number(ObjC.deepUnwrap(attributes.objectForKey($.NSFileSize)) || 0);
  const modifiedAt = ObjC.deepUnwrap(attributes.objectForKey($.NSFileModificationDate));
  const timestamp =
    modifiedAt && typeof modifiedAt.timeIntervalSince1970 === "function"
      ? Number(modifiedAt.timeIntervalSince1970())
      : 0;
  return `${size}:${timestamp}`;
}

function isStableFile(path) {
  if (!isRegularFile(path)) {
    return false;
  }
  const first = fileSize(path);
  if (!first) {
    return false;
  }
  delay(1);
  return first === fileSize(path);
}

function resultFor(entry, index, destinationPath, downloadedPath, status) {
  return {
    index: index + 1,
    course: String(entry.course || ""),
    status,
    source_url: String(entry.source_url || ""),
    url: String(entry.url || ""),
    destination_path: destinationPath,
    downloaded_path: downloadedPath,
    bytes: fileSize(destinationPath),
  };
}

function resolveWindow(safari) {
  const windows = safeList(() => safari.windows());
  if (windows.length) {
    return windows[0];
  }
  safari.make({ new: "document" });
  delay(0.5);
  const nextWindows = safeList(() => safari.windows());
  if (!nextWindows.length) {
    throw new Error("No Safari window is available.");
  }
  return nextWindows[0];
}

function resolveTab(windowRef) {
  const tab = safeValue(() => windowRef.currentTab());
  if (!tab) {
    throw new Error("No Safari tab is available.");
  }
  return tab;
}

function withForcedDownload(url) {
  if (!url) {
    return "";
  }
  if (/([?&])forcedownload=1(?:&|$)/i.test(url)) {
    return url;
  }
  return url.includes("?") ? `${url}&forcedownload=1` : `${url}?forcedownload=1`;
}

function readJson(path) {
  const data = $.NSData.dataWithContentsOfFile($(path).stringByStandardizingPath);
  if (!data) {
    throw new Error(`Failed to read ${path}`);
  }
  const error = Ref();
  const obj = $.NSJSONSerialization.JSONObjectWithDataOptionsError(data, 0, error);
  if (!obj) {
    throw new Error(`Failed to parse ${path}: ${unwrapError(error)}`);
  }
  return ObjC.deepUnwrap(obj);
}

function writeJson(path, value) {
  const text = JSON.stringify(value, null, 2);
  const error = Ref();
  const ok = $(text).writeToFileAtomicallyEncodingError(
    $(path).stringByStandardizingPath,
    true,
    $.NSUTF8StringEncoding,
    error
  );
  if (!ok) {
    throw new Error(`Failed to write ${path}: ${unwrapError(error)}`);
  }
}

function listDirectory(path) {
  const error = Ref();
  const items = $.NSFileManager.defaultManager.contentsOfDirectoryAtPathError(
    $(path).stringByStandardizingPath,
    error
  );
  if (!items) {
    throw new Error(`Failed to read directory ${path}: ${unwrapError(error)}`);
  }
  const unwrapped = ObjC.deepUnwrap(items);
  return Array.isArray(unwrapped) ? unwrapped : [];
}

function copyFile(sourcePath, destinationPath) {
  ensureDir(directoryName(destinationPath));
  const fileManager = $.NSFileManager.defaultManager;
  if (fileExists(destinationPath)) {
    const removeError = Ref();
    const removed = fileManager.removeItemAtPathError($(destinationPath).stringByStandardizingPath, removeError);
    if (!removed) {
      throw new Error(`Failed to replace ${destinationPath}: ${unwrapError(removeError)}`);
    }
  }
  const error = Ref();
  const ok = fileManager.copyItemAtPathToPathError(
    $(sourcePath).stringByStandardizingPath,
    $(destinationPath).stringByStandardizingPath,
    error
  );
  if (!ok) {
    throw new Error(`Failed to copy ${sourcePath} to ${destinationPath}: ${unwrapError(error)}`);
  }
}

function ensureDir(path) {
  const error = Ref();
  const ok = $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
    $(path).stringByStandardizingPath,
    true,
    $.NSDictionary.dictionary,
    error
  );
  if (!ok) {
    throw new Error(`Failed to create ${path}: ${unwrapError(error)}`);
  }
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath($(path).stringByStandardizingPath);
}

function isRegularFile(path) {
  const isDirectory = Ref();
  const exists = $.NSFileManager.defaultManager.fileExistsAtPathIsDirectory(
    $(path).stringByStandardizingPath,
    isDirectory
  );
  return Boolean(exists) && !Boolean(isDirectory[0]);
}

function fileSize(path) {
  if (!isRegularFile(path)) {
    return 0;
  }
  const error = Ref();
  const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(
    $(path).stringByStandardizingPath,
    error
  );
  if (!attributes) {
    return 0;
  }
  return Number(ObjC.deepUnwrap(attributes.objectForKey($.NSFileSize)) || 0);
}

function joinPath(left, right) {
  if (!left) {
    return right;
  }
  if (!right) {
    return left;
  }
  return `${String(left).replace(/\/+$/, "")}/${String(right).replace(/^\/+/, "")}`;
}

function directoryName(path) {
  return ObjC.unwrap($(path).stringByDeletingLastPathComponent);
}

function baseName(path) {
  return ObjC.unwrap($(path).lastPathComponent);
}

function standardizePath(path) {
  return ObjC.unwrap($(String(path)).stringByStandardizingPath);
}

function safeValue(getter) {
  try {
    return getter();
  } catch (_error) {
    return null;
  }
}

function safeList(getter) {
  const value = safeValue(getter);
  return Array.isArray(value) ? value : [];
}

function unwrapError(errorRef) {
  if (!errorRef || !errorRef[0]) {
    return "unknown error";
  }
  return ObjC.unwrap(errorRef[0].localizedDescription);
}
