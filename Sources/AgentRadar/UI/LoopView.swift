import Foundation
import SwiftUI

struct LoopView: View {
    @ObservedObject var store: LoopStore
    @State private var minimumText = ""
    @State private var maximumText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Loop 可用性测试")
                .font(.system(size: 13, weight: .semibold))

            Text("首次立即调用，后续随机等待；仅在 AgentRadar 运行期间循环。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            intervalSection

            Toggle("调用成功时提示", isOn: notifyOnSuccessBinding)
                .font(.system(size: 11))
                .controlSize(.small)

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("启动") {
                    guard let minuteRange else { return }
                    store.start(range: minuteRange)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isActive || minuteRange == nil)

                Button("停止") {
                    store.stop()
                }
                .buttonStyle(.bordered)
                .disabled(!store.isActive || store.phase == .stopping)

                Spacer()
                statusText
            }

            Divider()

            if let result = store.lastResult {
                resultSection(result)
            } else {
                Text("尚无调用结果")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(width: 380, height: 420, alignment: .topLeading)
        .focusEffectDisabled()
        .onAppear {
            minimumText = String(store.minimumMinutes)
            maximumText = String(store.maximumMinutes)
        }
    }

    private var intervalSection: some View {
        HStack(spacing: 8) {
            Text("随机间隔")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            TextField("1", text: minimumTextBinding)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
                .disabled(store.isActive)
            Text("至")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("5", text: maximumTextBinding)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
                .disabled(store.isActive)
            Text("分钟")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func resultSection(_ result: LoopRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("上次结果")
                    .font(.system(size: 11, weight: .semibold))
                Text(result.succeeded ? "成功" : "失败")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(result.succeeded ? Color.green : Color.red)
                Spacer()
                Text("#\(result.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("退出码 \(terminationStatusText(result.terminationStatus))")
                Text(String(format: "耗时 %.1f 秒", result.duration))
                Text(result.completedAt, style: .time)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            // 发送内容固定占上方四分之一，剩余区域用于展示主要返回结果。
            GeometryReader { geometry in
                let spacing: CGFloat = 8
                let availableHeight = max(0, geometry.size.height - spacing)

                VStack(spacing: spacing) {
                    resultContentPanel(title: "发送内容", text: String(result.count))
                        .frame(height: availableHeight * 0.25)

                    resultContentPanel(title: "返回内容", text: result.displayText)
                        .frame(height: availableHeight * 0.75)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resultContentPanel(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusText: some View {
        // 等待和执行阶段不会持续发布状态，按秒刷新才能保持右侧计时准确。
        switch store.phase {
        case .idle:
            Text("未启动")
        case .resolvingCodex:
            Text("查找 codex…")
        case let .waiting(count, nextRunAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("#\(count) \(remainingSeconds(until: nextRunAt, now: context.date)) 秒后执行")
                    .monospacedDigit()
            }
        case let .running(count, startedAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("#\(count) 执行中 \(elapsedSeconds(since: startedAt, now: context.date)) 秒")
                    .monospacedDigit()
            }
        case .stopping:
            Text("正在停止…")
        }
    }

    private var minuteRange: LoopMinuteRange? {
        guard let minimum = Int(minimumText), let maximum = Int(maximumText) else {
            return nil
        }
        return LoopMinuteRange(minimum: minimum, maximum: maximum)
    }

    private var validationMessage: String? {
        guard let minimum = Int(minimumText), let maximum = Int(maximumText) else {
            return "请输入 1 到 1440 的整数分钟。"
        }
        guard LoopMinuteRange.allowedMinutes.contains(minimum), LoopMinuteRange.allowedMinutes.contains(maximum) else {
            return "分钟范围必须在 1 到 1440 之间。"
        }
        guard minimum <= maximum else {
            return "最小分钟不能大于最大分钟。"
        }
        return nil
    }

    private var minimumTextBinding: Binding<String> {
        Binding(
            get: { minimumText },
            set: { newValue in
                let filtered = numericText(from: newValue)
                minimumText = filtered
                persistValidRange(minimumText: filtered, maximumText: maximumText)
            }
        )
    }

    private var maximumTextBinding: Binding<String> {
        Binding(
            get: { maximumText },
            set: { newValue in
                let filtered = numericText(from: newValue)
                maximumText = filtered
                persistValidRange(minimumText: minimumText, maximumText: filtered)
            }
        )
    }

    private var notifyOnSuccessBinding: Binding<Bool> {
        Binding(
            get: { store.notifyOnSuccess },
            set: { store.setNotifyOnSuccess($0) }
        )
    }

    private func persistValidRange(minimumText: String, maximumText: String) {
        guard
            let minimum = Int(minimumText),
            let maximum = Int(maximumText),
            let range = LoopMinuteRange(minimum: minimum, maximum: maximum)
        else {
            return
        }

        // 输入过程中允许暂时为空；只把完整合法区间写入 UserDefaults。
        store.setMinuteRange(range)
    }

    private func numericText(from value: String) -> String {
        value.filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
    }

    private func terminationStatusText(_ status: Int32?) -> String {
        status.map(String.init) ?? "-"
    }

    private func remainingSeconds(until date: Date, now: Date) -> Int {
        max(0, Int(ceil(date.timeIntervalSince(now))))
    }

    private func elapsedSeconds(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date)))
    }
}
