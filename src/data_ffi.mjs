// The browser features behind data.gleam.

import { Result$Ok, Result$Error } from "./gleam.mjs";

// localStorage can throw: when the browser blocks it for this site, or (on a
// write) when the site is out of space.
export function storageGet(key) {
  try {
    const value = globalThis.localStorage.getItem(key);
    return value === null ? Result$Error(undefined) : Result$Ok(value);
  } catch {
    return Result$Error(undefined);
  }
}

export function storageSet(key, value) {
  try {
    globalThis.localStorage.setItem(key, value);
  } catch (error) {
    console.error(`Couldn't save: ${error.message}`);
  }
}

// window.prompt is often swallowed on Windows/Chrome when it runs in the same
// turn as a <select> closing its native dropdown: the call returns null
// immediately, which looks like the user cancelled. We treat a too-fast null
// as a blocked prompt so the app can show an on-page name field instead.
let lastPromptBlocked = false;

// Ask the user to name a new drawing; "" (empty string) means they cancelled.
export function promptDrawingName() {
  lastPromptBlocked = false;
  const started = performance.now();
  let name = null;
  try {
    name = window.prompt("Name for the new drawing:");
  } catch {
    lastPromptBlocked = true;
    return "";
  }
  // A real cancel takes a human a moment; a blocked prompt returns at once.
  if (name === null && performance.now() - started < 50) {
    lastPromptBlocked = true;
  }
  return name === null ? "" : name;
}

export function promptWasBlocked() {
  return lastPromptBlocked;
}
