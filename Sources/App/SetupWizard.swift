import AppKit
import Combine
import SwiftUI
import WindowSwitchCore

struct SetupWizard: View {
    @Bindable var preferences: Preferences
    let guide: PermissionGuideController
    let finish: () -> Void
    var initialStep = 0
    @State private var step = 0
    @State private var appliedInitialStep = false
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var readiness: PermissionReadiness {
        PermissionReadiness(accessibility: accessibility, screenRecording: screenRecording, previewsEnabled: preferences.showPreviews)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(step == 0 ? "欢迎使用 WindowSwitch" : step == 1 ? "授权窗口切换与预览" : "设置完成").font(.title2.bold())
                    Text("\(step + 1) / 3").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            if step == 0 {
                Text("短按切换最近两个应用，长按查看窗口列表。")
                Text("先检查所需权限，再启用快捷键和 Dock 单屏聚焦。授权只在你点击按钮时申请，已授权的项目不会重复申请。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("显示窗口缩略图", isOn: $preferences.showPreviews)
            } else if step == 1 {
                permission("辅助功能", detail: "用于读取窗口信息、切换窗口和处理快捷键。", granted: accessibility) { guide.showAccessibility() }
                if preferences.showPreviews {
                    permission("屏幕录制", detail: "仅用于静态窗口缩略图，不录制音频。", granted: screenRecording) { guide.showScreenRecording() }
                    Toggle("显示窗口缩略图", isOn: $preferences.showPreviews)
                } else { Text("缩略图已关闭，无需屏幕录制权限。").foregroundStyle(.secondary) }
                Text("完成系统授权后会自动检测。若系统要求重新打开应用，请使用系统提供的重新打开按钮。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label(readiness.canStart ? "所需权限已就绪" : "请返回上一步完成权限", systemImage: readiness.canStart ? "checkmark.circle.fill" : "lock.circle").foregroundStyle(readiness.canStart ? .green : .secondary)
                Text("全窗口：\(preferences.windowModifier.label) + Tab\n当前应用：\(preferences.currentModifier.label) + `\n长按 \(Int(preferences.quickHoldDelay)) ms 显示列表")
                Text("可以随时在菜单栏设置中调整快捷键、外观、性能和更新选项。").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                if step > 0 { Button("上一步") { step -= 1 } }
                Spacer()
                Button(step == 2 ? "开始使用" : "继续") {
                    if step == 2 { finish() } else { step += 1 }
                }.keyboardShortcut(.defaultAction).disabled(step > 0 && !readiness.canStart)
            }
        }.padding(24).frame(width: 480, height: 340)
            .background(Color(nsColor: .windowBackgroundColor))
            .onReceive(poll) { _ in accessibility = AXIsProcessTrusted(); screenRecording = CGPreflightScreenCaptureAccess() }
            .onAppear { if !appliedInitialStep { appliedInitialStep = true; step = initialStep } }
    }
    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "lock.circle").foregroundStyle(granted ? .green : .secondary).font(.title2)
            VStack(alignment: .leading, spacing: 4) { Text(title).bold(); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(granted ? "已授权" : "授权", action: action).disabled(granted)
        }
    }
}
