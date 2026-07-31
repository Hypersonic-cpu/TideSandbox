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

## 2026-08-01 — Phase 3

- Running UI tests with code signing disabled caused macOS to report
  `TideSandboxUITests-Runner` as damaged. The product was not corrupt; Gatekeeper
  rejected the deliberately unsigned UI runner. All UI verification now uses
  Xcode's normal signing path, and the signed suite passes.
- `XCUIApplication.screenshot()` captured the primary desktop on this two-display
  system even though the app window was on display 2. Replaced every UI
  attachment with `app.windows.firstMatch.screenshot()`. Final visual inspection
  uses the window-only attachment and an explicit `screencapture -D 2` capture.
- The all-presets UI test initially waited on the diagnostic element's `label`.
  SwiftUI exposes the combined row text as its accessibility `value`; changing
  the predicate to that documented attribute made the test track asynchronous
  scene publication correctly.
- A concurrency audit found the snapshot callback being assigned on the main
  actor while the timer could read it from the runtime queue. Replaced the public
  mutable callback with queue-confined installation and invocation.
