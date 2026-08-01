# TideSandbox agent notes

Run commands from the repository root. Preserve unrelated working-tree changes.
Use `const` wherever possible; use inheritance only for genuine framework or
substitutability relationships. Keep X/Y face velocity represented by the same
type. Put scientific tests in `TideSandboxTests/`, not `/tmp`.

## Build

```sh
# Debug
xcodebuild -project TideSandbox.xcodeproj -scheme TideSandbox \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataDebug build

# Release
xcodebuild -project TideSandbox.xcodeproj -scheme TideSandbox \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataRelease build
```

Products are under `.build/DerivedData{Debug,Release}/Build/Products/`.
If Xcode reports that `metal` is unavailable, install/enable Xcode's matching
Metal Toolchain component; do not remove the `.metal` sources from the product.

## Non-interactive tests

These do not drive the mouse. Run the scientific suite serially because its
512² cases can terminate parallel test hosts under memory pressure:

```sh
xcodebuild -project TideSandbox.xcodeproj -scheme TideSandbox \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataDebug test \
  -parallel-testing-enabled NO -only-testing:TideSandboxTests
```

## UI automation (moves/clicks the mouse)

XCUITest visibly takes over the pointer and keyboard: to the user, the mouse
moves and clicks by itself. Do not merely launch the app and ask the user to
interact. Quit stale windows, then invoke the UI-test target. Keep normal code
signing enabled—`CODE_SIGNING_ALLOWED=NO` produces a damaged UI-test runner.

```sh
osascript -e 'tell application "TideSandbox" to quit'
xcodebuild -project TideSandbox.xcodeproj -scheme TideSandbox \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataUI test \
  -only-testing:TideSandboxUITests/TideSandboxUITests/test3DCameraInteractionSessionAndDebugControls
```

Grant Accessibility/Automation and Screen Recording permission to Terminal,
Xcode, and `TideSandboxUITests-Runner` when macOS requests it. Prefer one focused
UI scenario; use unit/offscreen tests for solver correctness and inspect every
retained UI screenshot visually.
