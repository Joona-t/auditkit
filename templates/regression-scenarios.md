# Regression Scenarios

## Scenario: basic functionality
CHECK: "addEventListener" in popup.js
CHECK: "chrome.storage" in background.js
MANUAL: Open popup, verify all buttons respond to clicks

## Scenario: no debug artifacts
CHECK_NOT: "console.log" in background.js
CHECK_NOT: "debugger" in content.js

## Scenario: required exports
CHECK: "module.exports" in lib/utils.js
MANUAL: Verify library loads without errors
