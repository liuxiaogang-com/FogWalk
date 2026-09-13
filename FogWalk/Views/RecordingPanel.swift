import SwiftUI
import CoreLocation
import CoreMotion

struct RecordingPanel: View {
    @ObservedObject var recorder: LocationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("记录模式") {
                    Picker("模式", selection: Binding(get: { recorder.mode }, set: { recorder.setMode($0) })) {
                        ForEach(RecordingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented)
                    Text(recorder.mode == .normal
                         ? "优先保留路线细节：运动时约 15 米距离过滤，有效记录最短间隔 5 秒。"
                         : "降低定位精度与频率：运动时约 60 米距离过滤，有效记录最短间隔 20 秒。静止后进一步省电，短路段可能遗漏。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("时间为采样下限，不是固定计时；iOS 会根据环境决定实际更新频率。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("运动辅助省电", isOn: Binding(
                        get: { recorder.motionAssistanceEnabled }, set: { recorder.setMotionAssistance($0) }))
                    Text("可选：利用系统活动识别辅助判断静止，不读取原始加速度。开启并开始记录时申请运动权限；关闭或拒绝不影响定位记录。实际省电效果取决于行程。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("当前状态") {
                    LabeledContent("记录", value: recorder.status)
                    LabeledContent("活动", value: recorder.motionState.rawValue)
                    LabeledContent("本次记录已保存", value: "\(recorder.savedPointCount) 点")
                    if let date = recorder.latestFixDate {
                        LabeledContent("最近定位", value: date.formatted(date: .omitted, time: .standard))
                    }
                    if let accuracy = recorder.latestAccuracy {
                        LabeledContent("定位精度", value: "约 \(Int(accuracy.rounded())) 米")
                    }
                    if let error = recorder.errorMessage {
                        Text(error).foregroundStyle(.orange)
                    }
                    if let error = recorder.storageErrorMessage {
                        Text(error).foregroundStyle(.orange)
                        Button("重试保存") { recorder.flushPendingPoints() }
                    }
                    Button("更新当前位置") { recorder.requestCurrentLocation() }
                    Button(recorder.wantsRecording ? "结束记录" : "开始记录") {
                        if recorder.wantsRecording { recorder.stopRecording() } else { recorder.startRecording() }
                    }.tint(recorder.isRecording ? .red : .orange)
                }
                Section("权限与后台") {
                    LabeledContent("位置访问", value: authorizationText)
                    LabeledContent("精确位置", value: recorder.reducedAccuracy ? "未开启" : "已开启")
                    LabeledContent("后台 App 刷新", value: recorder.backgroundRefreshText)
                    LabeledContent("后台续跑", value: recorder.backgroundContinuationText)
                    if recorder.motionAssistanceEnabled { LabeledContent("运动识别", value: motionText) }
                    if recorder.authorizationStatus != .authorizedAlways {
                        Button("申请始终允许定位") { recorder.requestAlwaysAccess() }
                    }
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("首次点“开始记录”后会记住长期记录意图；以后系统因定位事件重新启动 App 时会自动恢复。建议开启“始终”、精确位置和后台 App 刷新。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("程序不依赖后台定时器：移动时记录，静止时由系统自动暂停或使用低功耗事件等待唤醒。静止唤醒可能有延迟；手动划掉 App、关闭权限或重启后未解锁时不能保证继续记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("出行记录").navigationBarTitleDisplayMode(.inline)
            .onAppear { recorder.refreshSystemStatus() }
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private var authorizationText: String {
        switch recorder.authorizationStatus {
        case .authorizedAlways: "始终允许"
        case .authorizedWhenInUse: "使用期间（建议升级为始终）"
        case .denied: "未允许"
        case .restricted: "系统限制"
        case .notDetermined: "尚未授权"
        @unknown default: "未知"
        }
    }

    private var motionText: String {
        guard CMMotionActivityManager.isActivityAvailable() else { return "不可用，使用位置判断" }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return "已允许"
        case .denied, .restricted: return "未允许，使用位置判断"
        case .notDetermined: return "开始记录时申请"
        @unknown default: return "待确认"
        }
    }
}
