## Scenario: core functions
CHECK: "calculateScore" in new-feature.js
CHECK: "greet" in sub/code.js
CHECK_NOT: "eval" in new-feature.js
