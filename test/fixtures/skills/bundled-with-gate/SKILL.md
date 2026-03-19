---
name: bundled-with-gate
description: A bundled skill that requires a nonexistent binary.
metadata:
  openclaw:
    requires:
      bins:
        - __bundled_test_nonexistent_binary__
---
# Bundled With Gate
This skill should be filtered out by the gate mechanism.
