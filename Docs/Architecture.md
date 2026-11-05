# Architecture and validation

- `WindowService` owns window metadata, Accessibility handles, window lifecycle notifications, and bounded screenshot caches. UI code receives value snapshots.
- `SwitchController` owns a switching session, uses shared per-window recency, filters before optional app grouping, and fills static previews after the panel becomes visible.
- High preview quality scales the visible thumbnail box by the display backing scale. Low previews cap the longest edge at 200 pixels. Idle-time prefetching uses at most one 150-pixel image per cycle and never replaces a sufficient high-quality preview.
- Background metadata maintenance is event-driven, with a slow fallback sweep. Preloading is opt-in and backs off under load, heat, low-power mode, or user activity.
- `DockFocusController` uses a dedicated event-tap thread. A single click owns the restore, exact-window activation, and readback sequence. Other displays' visible windows are protected when hidden/minimized siblings are restored. Drag and long-press gestures are passed through.
- `NativeCaptureBridge` and `NativeSpaceBridge` check optional system symbols. The capture bridge falls back to ScreenCaptureKit. The Space bridge retains the applicable third-party MIT notice.
- The close affordance uses a system symbol. App artwork is in `Design/`.

## Validation

Run `Scripts/test.sh` for pure selection, recency, grouping, filtering, resource-policy, preview-quality, and layout tests.

An already-authorized build can run disposable real-window fixtures:

```sh
./Scripts/verify-functional.sh --app /absolute/path/WindowSwitch.app --quick-switch
./Scripts/verify-functional.sh --app /absolute/path/WindowSwitch.app --extended --focus-stress
```

The verifier restricts mutations to the exact bundle path, PID, and random session of its temporary fixtures. It does not operate on user documents or change Dock/TCC settings. `--dock-input` additionally permits one strictly hit-tested click on that session's real Dock icon, using a temporary event tap. Reports and screenshots are written to temporary storage and are not part of the repository.

GitHub Actions runs unit tests and builds both architectures. It cannot replace real multi-display, Accessibility, Screen Recording, or future-OS validation. The x86_64 slice is compiled but not executed on the arm64 runner.
