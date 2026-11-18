# Architecture and validation

- `WindowService` owns window metadata, Accessibility handles, window lifecycle notifications, and bounded screenshot caches. UI code receives value snapshots.
- `SwitchController` owns a switching session, uses shared per-window recency, filters before optional app grouping, and fills static previews after the panel becomes visible. While the list is open it watches the on-screen window set every 200 ms; windows already shown keep their places, new ones are appended, and recency reordering waits for the next open.
- High preview quality scales the visible thumbnail box by the display backing scale. Low previews cap the longest edge at 200 pixels. Idle-time prefetching fills up to 32 previews sequentially per round, with missing or undersized images first and a resource check between captures. Foreground and background captures share the WindowServer backend, with ScreenCaptureKit as a fallback. Newer prefetched images are applied before the panel appears. An open panel shows cached previews unchanged and only fills windows that have none (cross-faded from empty).
- Background metadata maintenance is event-driven, with a slow fallback sweep. Preloading is user-configurable and backs off under load, heat, low-power mode, or user activity.
- Cached lists reconcile the current foreground PID and exact focused window before applying recency. After a verified switch, the destination leads and the observed origin follows. Quick switches prepare their window snapshot on key-down, then recheck its focus/inventory revision on commit. A visible target can reuse its exact cached AX handle; native activation still validates the live PID/window ID. Each submitted switch remembers its own Tab release (up to a 250 ms fallback), so a subsequent Tab press cannot extend the previous switch's wait. A Tab key-up without a key-down since the modifier went down is still treated as a quick tap, as a fallback.
- `DockFocusController` uses a dedicated event-tap thread. A single click owns the restore, exact-window activation, and readback sequence. Other displays' visible windows are protected when hidden/minimized siblings are restored. Drag and long-press gestures are passed through.
- `NativeCaptureBridge` and `NativeSpaceBridge` check optional system symbols. The capture bridge falls back to ScreenCaptureKit. The Space bridge retains the applicable third-party MIT notice.
- The close affordance uses a system symbol. App artwork is in `Design/`.

## Validation

Run `Scripts/test.sh` for pure selection, recency, grouping, filtering, resource-policy, preview-quality, and layout tests.

An already-authorized build can run disposable real-window fixtures:

```sh
./Scripts/verify-functional.sh --app /absolute/path/WindowSwitch.app --focus-only
./Scripts/verify-functional.sh --app /absolute/path/WindowSwitch.app --quick-switch
./Scripts/verify-functional.sh --app /absolute/path/WindowSwitch.app --extended --focus-stress
```

The focus-only suite disables previews for the test session. It exercises two app identities and three-window recency, including missed notifications, queued taps, optional app grouping, and switching between displays. The socket roundtrip checks frontmost PID, AX window ID and the compositor stacking order of overlapping fixture windows. Its report includes median and 95th-percentile timings.

Quick-switch diagnostics measure submission to verified completion, queueing, waiting for Tab release, the activation request, focus readback and retry waits. The request includes setting the process frontmost, posting window events, and raising the exact window. The report also measures elapsed time from the final native set-front return through completion, and from verification through publication on the main actor. The AX read is part of readback. These nested intervals should be interpreted separately.

The verifier restricts mutations to the exact bundle path, PID, and random session of its temporary fixtures. It does not operate on user documents or change Dock/TCC settings. `--dock-input` additionally permits one strictly hit-tested click on that session's real Dock icon, using a temporary event tap. Reports and screenshots are written to temporary storage and are not part of the repository.

GitHub Actions runs unit tests and builds both architectures. It cannot replace real multi-display, Accessibility, Screen Recording, or future-OS validation. The x86_64 slice is compiled but not executed on the arm64 runner.

## First-run permissions and updates

`PermissionReadiness` gates all input hooks and metadata maintenance: Accessibility is always required; Screen Recording is required only when previews are enabled. The first-run wizard checks without prompting, explains the capabilities, and requests them only on explicit button clicks. Already-granted permissions are skipped. Diagnostics and setup smoke tests never request permissions automatically.

`UpdateController` uses Sparkle's native UI and settings. Startup/background checks begin after setup is ready; manual checks are also available. GitHub Pages publishes the signed appcast, GitHub Releases stores the signed ZIPs, and RC channel filtering is independent of window-switching state. Update downloads/installations are opt-in and do not share the screenshot worker. The pure feed tests reject missing signatures, mismatched versions, and foreign archive URLs.

The six settings panes are General, App Switcher, Appearance, Performance, Updates, and About. They use small native controls, a 640×400 content area, and a system-drawn toolbar segmented control on the traffic-light row (no custom glass), over a full-size content view with a transparent titlebar so the header shares the window background. No settings pane has a scrolling container. Functional defaults live in a resource plist; authorization status and recent-document data are excluded.

## Direct shortcut input

The Performance preference is opt-in. Karabiner-Elements 16.2 or later supplies the local datagram sender and the persistent variable CLI. WindowSwitch adds one tagged rule after the user's rules in the selected profile, preserving other mappings and JSON comments. The rule forwards only window-switch gestures and modifier edges. The normal event tap continues to serve other keys and devices. Direct gestures own their modifier release and use the same window selection and hold timer as the standard shortcut.

The receiver binds a socket in a private user directory before renewing a five-second rule expiry. Pausing, opening setup or quitting revokes the lease. An unexpected exit lets the rule expire. Disabling the preference removes the managed rule. Switching profiles or changing the window modifier reconciles the rule with the current configuration.

Quick and list commits with a concrete window verify the frontmost PID and AX focused window ID. A transient failure may retry the same window once if focus stayed at the origin or moved to the destination app’s known previous window. A new click or key-down suppresses the retry. A visible compositor window missing from one AX enumeration remains eligible.
