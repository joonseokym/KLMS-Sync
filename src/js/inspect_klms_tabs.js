#!/usr/bin/osascript -l JavaScript

function run() {
  const safari = Application("/Applications/Safari.app");
  const windows = safari.windows();
  const tabs = [];

  for (let windowIndex = 0; windowIndex < windows.length; windowIndex += 1) {
    const windowRef = windows[windowIndex];
    const windowTabs = safeList(() => windowRef.tabs());

    for (let tabIndex = 0; tabIndex < windowTabs.length; tabIndex += 1) {
      const tab = windowTabs[tabIndex];
      tabs.push({
        windowIndex,
        tabIndex,
        url: safeString(() => tab.url()),
        title: safeString(() => tab.name()),
      });
    }
  }

  return JSON.stringify({ status: "ok", tabs });
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (error) {
    return "";
  }
}

function safeList(getter) {
  try {
    return getter() || [];
  } catch (error) {
    return [];
  }
}
