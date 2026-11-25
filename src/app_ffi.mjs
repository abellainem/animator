// Small browser helpers used by app.gleam.

// Set the value of the <select> tagged data-test-id=testId, if it exists.
export function setSelectValue(testId, value) {
  const select = document.querySelector(`select[data-test-id="${testId}"]`);
  if (select) select.value = value;
}

// Run callback after ms milliseconds.
export function after(ms, callback) {
  setTimeout(callback, ms);
}

// Focus the first element matching selector, if it exists.
export function focusSelector(selector) {
  const el = document.querySelector(selector);
  if (el && typeof el.focus === "function") el.focus();
}
