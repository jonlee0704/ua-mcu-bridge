# P0 Testing Policy: Test-Driven Development & Regression Prevention

Whenever any new feature is added, modified, or refactored in UA-MCU Bridge:

1. **Test Coverage is Mandatory:**
   - Every new feature, bug fix, or protocol handler MUST be accompanied by unit test assertions in `Tests/`.
   - Never consider a feature complete until corresponding automated tests are written and passing.

2. **Pre-Commit / Pre-Completion Verification:**
   - Always run `./run_tests.sh` to confirm that all test suites pass with 0 failures and 0 warnings.
   - Any regression is treated as a P0 blocker that must be resolved immediately.

3. **Test Plans and Documentation Sync:**
   - Keep `FEATURES.md` and test fixtures aligned with the actual hardware protocol and behavior.
