# WaterSandbox Debug Log

## 2026-07-31

- Initial persistent-worker dispatch asserted before its first job because the
  completion count began at zero. Initialized it to the number of waiting worker
  threads after pool construction.
- Replaced separate `XFaceField` and `YFaceField` classes with one `FaceField`
  type. The previous types duplicated identical behavior and incorrectly made
  velocity components different C++ types.
- Added wet/dry pressure-face treatment so a level lake beside higher dry terrain
  remains at rest while lower dry terrain remains inundatable.
- The generated `#Preview` declaration could not expand under the command-line
  build sandbox (`swift-plugin-server` was denied). Removed this template-only
  declaration; the product build and XCTest bundle then compiled successfully.
- XCTest execution initially could not contact `testmanagerd` from the restricted
  sandbox. Re-ran the identical commands with the required macOS test-runner
  permission. Debug, Address Sanitizer, and Thread Sanitizer suites all passed.
