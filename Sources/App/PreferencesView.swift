import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Native settings for shortcuts, appearance, and permissions.
struct PreferencesView: View {
    @Bindable var preferences: Preferences
    @Bindable var navigation: PreferencesNavigation
    var refresh: () -> Void
    var preview: () -> Void
    let permissionGuide: PermissionGuideController
    @State private var permissionsPresented = false
    @State private var loginError = ""
    private let labelWidth: CGFloat = 170

    var body: some View {
        VStack(spacing: 10) {
            Group {
                switch navigation.selected {
                case 1: appSwitcher
                case 2: appearance
                case 3: about
                default: general
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Permissions…") { permissionsPresented = true }
                if !preferences.runtimeStatus.isEmpty {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).help(preferences.runtimeStatus)
                }
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 578, height: 526)
        .background(.regularMaterial)
        .sheet(isPresented: $permissionsPresented) {
            PermissionsSheet(guide: permissionGuide, status: preferences.runtimeStatus)
        }
        .onChange(of: preferences.runInBackground) { _, enabled in
            do {
                if enabled, SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
                else if !enabled, SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
                loginError = ""
            } catch { loginError = error.localizedDescription }
        }
        .onChange(of: preferences.backgroundPreloadEnabled) { _, _ in refresh() }
        .onChange(of: preferences.backgroundPreloadThumbnails) { _, _ in refresh() }
        .onChange(of: preferences.backgroundPreloadInterval) { _, value in
            let bounded = value.isFinite ? min(max(value, 1), 3600) : 30
            if value != bounded { preferences.backgroundPreloadInterval = bounded }
            refresh()
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Run WindowSwitch in the background", isOn: $preferences.runInBackground)
            Text("If enabled, WindowSwitch keeps running in the background and is automatically started when you log in.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 18).fixedSize(horizontal: false, vertical: true)
            if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.orange) }
            Divider().padding(.vertical, 8)
            Text("Activate the window switcher for")
            HStack {
                Toggle("all windows:", isOn: $preferences.allWindowsEnabled).frame(width: 190, alignment: .leading)
                modifier($preferences.windowModifier)
                Text("+ ⇥ (Tab)")
                Spacer(minLength: 0)
            }
            HStack {
                Toggle("current app's windows:", isOn: $preferences.currentWindowEnabled).frame(width: 190, alignment: .leading)
                modifier($preferences.currentModifier)
                Text("+")
                Text("§ / `").frame(width: 60).padding(.vertical, 2)
                    .background(.background, in: RoundedRectangle(cornerRadius: 4))
            }
            Toggle("Quick tap switches the top two windows on the mouse screen", isOn: $preferences.quickSwitchOnMouseScreen)
                .padding(.top, 6)
            HStack(spacing: 8) {
                if preferences.quickSwitchOnMouseScreen {
                    Text("Hold to show list for"); milliseconds($preferences.quickHoldDelay)
                } else {
                    Text("Delay activation for"); milliseconds($preferences.showDelay)
                }
                Text("ms")
            }
            HStack {
                Text("Show on Screen:")
                Picker("", selection: $preferences.screenChoice) {
                    Text("Main Screen").tag("main")
                    Text("Active Screen").tag("active")
                    Text("Screen with Mouse").tag("mouse")
                }.labelsHidden().frame(width: 185)
            }
            Divider().padding(.vertical, 8)
            Toggle("Include windows from other spaces", isOn: $preferences.allSpaces)
            Toggle("Include windows from other screens", isOn: $preferences.allScreens)
            Toggle("Show only the most recent window per app", isOn: $preferences.oneWindowPerApp)
                .help("Applies to the window switcher and quick tap. The current app's window shortcut still shows all its windows.")
            Toggle("Show full size previews on hover", isOn: $preferences.hoverPreview)
            Toggle("Use shift to cycle backwards", isOn: $preferences.reverseWithShift)
            Toggle("Dock clicks focus windows on the current screen only", isOn: $preferences.dockFocusEnabled)
            Spacer(minLength: 0)
        }.padding(18).toggleStyle(.checkbox)
    }

    private var appSwitcher: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show window previews on the app switcher (⌘ + Tab)", isOn: $preferences.applicationSwitcher)
            Text("Use the § / ` key or your arrow keys to switch windows.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 18)
            Divider().padding(.vertical, 8)
            HStack {
                Text("Delay activation for").frame(width: 135, alignment: .trailing)
                milliseconds($preferences.applicationInitialDelay)
                Text("ms on first activation")
            }
            HStack {
                Color.clear.frame(width: 135, height: 1)
                milliseconds($preferences.applicationSubsequentDelay)
                Text("ms on subsequent activations")
            }
            Divider().padding(.vertical, 8)
            Toggle("When activating an app without windows, try to open the default window", isOn: $preferences.openDefaultWindow)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Automatically activate the current app after", isOn: $preferences.applicationAutoActivate)
                milliseconds($preferences.applicationAutoActivateDelay).disabled(!preferences.applicationAutoActivate)
                Text("ms").foregroundStyle(preferences.applicationAutoActivate ? .primary : .secondary)
            }
            Spacer(minLength: 0)
        }.padding(18).toggleStyle(.checkbox)
    }

    private var appearance: some View {
        ScrollView {
        VStack(spacing: 12) {
            HStack {
                Text("Appearance:").frame(width: labelWidth, alignment: .trailing)
                Picker("", selection: $preferences.theme) {
                    Text("System Default").tag("system"); Text("Classic").tag("classic"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.labelsHidden().frame(width: 180)
                Spacer()
            }
            HStack {
                Text("Background color:").frame(width: labelWidth, alignment: .trailing)
                ColorPicker("", selection: $preferences.backgroundColor, supportsOpacity: true).labelsHidden().disabled(preferences.theme != "classic")
                Spacer()
            }
            HStack {
                Color.clear.frame(width: labelWidth, height: 1)
                Toggle("Blur window background", isOn: $preferences.backgroundBlur).disabled(preferences.theme != "classic")
                Spacer()
            }
            HStack(alignment: .top) {
                Text("Thumbnail size:").frame(width: labelWidth, alignment: .trailing).padding(.top, 3)
                VStack(spacing: 1) {
                    Slider(value: $preferences.thumbnailSize, in: 120...320, step: 5)
                    HStack { Text("Small"); Spacer(); Text("Large") }.font(.system(size: 11))
                }.frame(width: 190)
                Spacer()
            }
            HStack {
                Text("Quality:").frame(width: labelWidth, alignment: .trailing)
                Picker("", selection: $preferences.previewQuality) {
                    Text("Low (faster)").tag(2); Text("High").tag(4)
                }.labelsHidden().frame(width: 130)
                Spacer()
            }
            HStack {
                Color.clear.frame(width: labelWidth - 60, height: 1)
                Toggle("Show", isOn: $preferences.showAppIcons)
                Picker("", selection: $preferences.iconScale) {
                    Text("small").tag(0.0); Text("large").tag(1.0)
                }.labelsHidden().frame(width: 90)
                Text("app icons"); Spacer()
            }
            HStack {
                Text("Hide animation:").frame(width: labelWidth, alignment: .trailing)
                Picker("", selection: $preferences.hideAnimation) {
                    Text("None").tag("none"); Text("Fade out").tag("fade")
                }.labelsHidden().frame(width: 130)
                Spacer()
            }
            HStack {
                Text("Fade in:").frame(width: labelWidth, alignment: .trailing)
                milliseconds($preferences.fadeInDuration); Text("ms"); Spacer()
            }
            HStack {
                Text("Fade out:").frame(width: labelWidth, alignment: .trailing)
                milliseconds($preferences.fadeOutDuration); Text("ms"); Spacer()
            }.disabled(preferences.hideAnimation != "fade")
            Divider().padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Preload windows in the background", isOn: $preferences.backgroundPreloadEnabled)
                HStack(spacing: 6) {
                    Text("Refresh every")
                    TextField("", value: $preferences.backgroundPreloadInterval,
                              format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).frame(width: 58)
                    Stepper("", value: $preferences.backgroundPreloadInterval, in: 1...3600, step: 1).labelsHidden()
                    Text("seconds"); Spacer()
                }.padding(.leading, 18).disabled(!preferences.backgroundPreloadEnabled)
                Toggle("Also refresh low-resolution thumbnails", isOn: $preferences.backgroundPreloadThumbnails)
                    .padding(.leading, 18).disabled(!preferences.backgroundPreloadEnabled)
                Text("Uses idle time at the lowest background priority, one preview per cycle. Slows or pauses automatically when the system is busy.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
                if preferences.backgroundPreloadEnabled, !preferences.preloadStatus.isEmpty {
                    Text(preferences.preloadStatus).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 18)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider().padding(.top, 4)
            HStack {
                Text("Show WindowSwitch in")
                Toggle("the Dock", isOn: $preferences.showDockIcon)
                Toggle("the menu bar", isOn: $preferences.showMenuBarIcon)
            }
            Spacer(minLength: 0)
        }.padding(18).toggleStyle(.checkbox)
        }.scrollIndicators(.automatic)
    }

    private var about: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text("WindowSwitch").font(.title.bold())
            Text("Version 0.1.0").foregroundStyle(.secondary)
            Text("A fast, native macOS window switcher.").multilineTextAlignment(.center)
            Spacer()
            Button("Permissions…") { permissionsPresented = true }
            Button("Restore Defaults") { preferences.restoreDefaults() }
            Text("PermissionFlow · MIT License").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modifier(_ binding: Binding<ShortcutModifier>) -> some View {
        Picker("", selection: binding) {
            ForEach(ShortcutModifier.allCases) { Text($0.label).tag($0) }
        }.labelsHidden().frame(width: 120)
    }

    private func milliseconds(_ binding: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            TextField("", value: binding, format: .number.precision(.fractionLength(0)))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 48)
            Stepper("", value: binding, in: 0...5000, step: 10).labelsHidden()
        }.fixedSize()
    }
}

private struct PermissionsSheet: View {
    let guide: PermissionGuideController
    let status: String
    @Environment(\.dismiss) private var dismiss
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("系统权限").font(.headline)
            Text("WindowSwitch 需要以下权限来切换窗口和显示预览。")
                .font(.callout).foregroundStyle(.secondary)
            row("辅助功能", granted: accessibility) { guide.showAccessibility() }
            row("屏幕与系统音频录制", granted: screenRecording) { guide.showScreenRecording() }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 420)
            .onReceive(poll) { _ in accessibility = AXIsProcessTrusted(); screenRecording = CGPreflightScreenCaptureAccess() }
    }
    private func row(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            Text(title); Spacer(); Button(granted ? "已授权" : "授权", action: action).disabled(granted)
        }
    }
}

extension Preferences {
    var backgroundColor: Color {
        get {
            let values = backgroundRGB.split(separator: ",").compactMap { Double($0) }
            return Color(.sRGB, red: values.first ?? 0.08, green: values.count > 1 ? values[1] : 0.08,
                         blue: values.count > 2 ? values[2] : 0.08, opacity: backgroundOpacity)
        }
        set {
            guard let color = NSColor(newValue).usingColorSpace(.deviceRGB) else { return }
            backgroundRGB = "\(color.redComponent),\(color.greenComponent),\(color.blueComponent)"
            backgroundOpacity = color.alphaComponent
        }
    }
}
