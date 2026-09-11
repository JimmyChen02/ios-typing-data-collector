# Apple keyboard coordinate probe

This is an isolated experiment for keeping Apple's actual keyboard and its
predictions while observing touch coordinates through `UIApplication.sendEvent`.
It does not replace the keyboard, synthesize predictions, or modify FreeTypeRecorder.
Intent collection remains deferred.

## Current evidence — September 11, 2026

**Physical-phone CSV verified, alongside the positive simulator result.**

The user supplied [the phone's measured CSV](evidence/phone-native-keyboard-probe-1789135198.csv)
after running the installed probe. It contains seven `UIRemoteKeyboardWindow`
touch-downs and six text changes: `Q` → `Qw` → `Qwe` → `Qw` → `Q` → empty.
Every coordinate is finite and inside the reported keyboard rectangle
`(x: 0, y: 539, width: 402, height: 335)` points; timestamps are ordered.
The first three measured screen points are `(28.667, 618.333)`,
`(67.000, 615.667)`, and `(99.333, 622.000)`. Their keyboard-local positions are
`(28.667, 79.333)`, `(67.000, 76.667)`, and `(99.333, 83.000)`.
The final touch has no text-change row and is not assigned to an inferred key.
This verifies coordinate delivery on the tested phone. It does not by itself
validate every native keyboard feature or the integrated collector's recording flow.

Direct UI clicks
on the native keyboard in the iPhone 16 Pro / iOS 18.3.1 simulator produced:

| Input | Measured screen coordinates (points) | Touch window |
| --- | --- | --- |
| Q | 19, 610 | UIRemoteKeyboardWindow |
| W | 59, 610 | UIRemoteKeyboardWindow |
| E | 99, 610 | UIRemoteKeyboardWindow |

The editor received `Q`, `Qw`, then `Qwe`. Apple's prediction bar was visible;
on leaving the editor, Apple subsequently corrected the text to `Wee`.
The observer forwarded every original event to `super.sendEvent`.

The measured export is [evidence/simulator-ios18-direct-clicks.csv](evidence/simulator-ios18-direct-clicks.csv).
These are computer-generated Simulator clicks, **not participant finger data**.
The export includes one calibration touch and the later export-button touch.
The three letter labels above describe the test actions; the CSV does not infer
keys or pretend that text changes have a guaranteed one-to-one relationship to taps.

Both iOS 26.1 and iOS 18.3.1 XCUITest runs failed their native-text insertion
check: synthetic key-element coordinate taps entered no text. The initial 26.1
run also had offscreen keyboard elements. These failed checks are inconclusive
about native touch availability. Direct Simulator UI clicks, separately observed
and exported, provided the positive result above. The automated test is kept as
a diagnostic, and a passing app build is not a successful coordinate measurement.

A signed device build succeeded and `Keyboard Probe` was installed on the
connected iPhone 17 Pro running iOS 26.6.1. Launch was rejected with the system's
generic code-signature/entitlements/developer-trust error. Local strict signature
verification passed; the generated development profile includes this device,
matches the bundle identifier, and expires September 18, 2026. The user subsequently
ran the phone check and reported `In keyboard: 3`, then supplied the CSV verified
above. FreeTypeRecorder now
has the corresponding observer in source, but its integrated build and full
recording flow still need runtime validation.

## Run the hardware check

1. Open **Keyboard Probe**. If iOS reports an untrusted developer, review your
   own development certificate in Settings → General → VPN & Device Management.
   Apple's [sample-app instructions](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app)
   describe this personal-team signing step.
2. Tap **Start probe**, then **Check app touch** once. `App touches` should be 1.
3. Type `qwe` by touching Apple's onscreen keys. Read `In keyboard` and `Text changes`.
4. Tap **Stop & export CSV**. The file is also saved in the app's Documents folder.

Three keyboard touches and three text changes establish basic event visibility.
Before integrating into the collector, repeat with clearly off-center touches,
prediction taps, corrections, Shift, deletion, emoji, and swipe typing. Verify
that observed coordinates follow finger position, while text behavior remains
native. An on-screen keyboard bounding rectangle is not Apple's individual key
geometry or its adaptive hit-test region. This probe exports screen coordinates
and the contemporaneous keyboard rectangle, without inventing key geometry.

## Build

```sh
xcodegen generate --spec experiments/AppleKeyboardProbe/project.yml
open experiments/AppleKeyboardProbe/AppleKeyboardProbe.xcodeproj
```

Select the `AppleKeyboardProbe` scheme and the research phone. The deployment
target is iOS 15 so the same probe can also test older devices; the main collector
keeps its existing target. Recording begins only with Start and stops when the
app resigns active. Data stays in the probe until the user exports it.

## Other routes investigated

- **iOS 15/16 device:** a credible next test if modern hardware doesn't expose
  events. Apple says the keyboard ran within the app before iOS 17. That makes
  observation plausible, but this session did not test old physical hardware.
  Predictions would be Apple's predictions for that OS, not guaranteed identical
  to iOS 26. [Apple architecture explanation](https://developer.apple.com/videos/play/wwdc2023/10281/)
- **Instrumented research phone:** historical work demonstrates keyboard/touch
  observation with elevated device access. Feasibility depends on exact hardware
  and OS. The current [Dopamine compatibility list](https://github.com/opa334/Dopamine)
  does not cover the connected iPhone 17 Pro on iOS 26.6.1.
  [Original touchlogging research](https://www.levelblue.com/blogs/spiderlabs-blog/touchlogging-part-1-ios)
- **SensorKit:** Apple's published keyboard metrics include counts and timing
  distributions, but no per-touch x/y stream.
  [SRKeyboardMetrics](https://developer.apple.com/documentation/sensorkit/srkeyboardmetrics)
- **External camera:** can preserve the actual device keyboard while estimating
  screen contact position. This is an estimate with calibration/occlusion error,
  not the touch digitizer's measured coordinate; it does not meet an exact-coordinate
  requirement without relaxing that requirement.
- **UI recording / developer services:** found interaction replay and event
  synthesis capabilities, but did not verify a physical-finger keyboard-coordinate
  recording stream. Synthetic input coordinates are not measurements of user input.
- **Apple Security Research Device:** gives deep access, but Apple's stated scope
  is controlled security research, not a generally available typing-study device.
  [Program scope](https://security.apple.com/research-device/)

The public event-observation mechanism is documented by Apple:
[UIApplication.sendEvent](https://developer.apple.com/documentation/uikit/uiapplication/sendevent(_:)).
Its availability does not guarantee which keyboard events a particular device
delivers to the app. That is what this experiment measures.
