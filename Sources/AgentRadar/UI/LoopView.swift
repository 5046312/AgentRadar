import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LoopView: View {
    @ObservedObject var store: LoopStore
    @State private var successMinimumText = ""
    @State private var successMaximumText = ""
    @State private var failureMinimumText = ""
    @State private var failureMaximumText = ""
    @State private var selectedChannelID: UUID?
    @State private var editorRequest: LoopChannelEditorRequest?
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            intervalSection

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if let operationError {
                Text(operationError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            channelSection
            Divider()
            selectedResultSection
        }
        .padding(14)
        .frame(width: 420, height: 500, alignment: .topLeading)
        .onAppear {
            successMinimumText = String(store.successMinimumSeconds)
            successMaximumText = String(store.successMaximumSeconds)
            failureMinimumText = String(store.failureMinimumSeconds)
            failureMaximumText = String(store.failureMaximumSeconds)
            selectAvailableChannel()
        }
        .onChange(of: store.channels.map(\.id)) { _, _ in
            selectAvailableChannel()
        }
        .popover(item: $editorRequest, arrowEdge: .leading) { request in
            LoopChannelEditorView(
                store: store,
                request: request,
                onSaved: { channelID in selectedChannelID = channelID },
                onDeleted: { selectedChannelID = nil }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Loop 可用性测试")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: store.resetStatistics) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重置全部渠道统计")
            Button {
                editorRequest = LoopChannelEditorRequest(channel: nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("添加渠道")
        }
    }

    private var intervalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            intervalRow(
                title: "成功后间隔",
                minimum: successMinimumTextBinding,
                maximum: successMaximumTextBinding
            )
            intervalRow(
                title: "失败后间隔",
                minimum: failureMinimumTextBinding,
                maximum: failureMaximumTextBinding
            )
        }
    }

    private func intervalRow(title: String, minimum: Binding<String>, maximum: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 76, alignment: .leading)
            Spacer()
            TextField("60", text: minimum)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
            Text("至")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("300", text: maximum)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
            Text("秒")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var channelSection: some View {
        if store.channels.isEmpty {
            Text("暂无渠道")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 78)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.channels) { channel in
                        channelRow(channel)
                    }
                }
            }
            .frame(minHeight: 78, maxHeight: 128)
        }
    }

    private func channelRow(_ channel: LoopChannel) -> some View {
        HStack(spacing: 6) {
            Button {
                selectedChannelID = channel.id
                operationError = nil
                if channel.isActive || validationMessage == nil {
                    store.toggleChannel(id: channel.id)
                } else {
                    operationError = "请先修正间隔配置。"
                }
            } label: {
                HStack(spacing: 9) {
                    LoopChannelStatusRing(channel: channel)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        channelStatusText(channel)
                    }
                    Spacer()
                    Text("✓\(channel.successCount)  ×\(channel.failureCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                selectedChannelID = channel.id
                editorRequest = LoopChannelEditorRequest(channel: channel)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(channel.isActive)
            .help(channel.isActive ? "请先停止渠道" : "编辑渠道")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            selectedChannelID == channel.id ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    @ViewBuilder
    private func channelStatusText(_ channel: LoopChannel) -> some View {
        if let errorMessage = channel.errorMessage {
            Text(errorMessage)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .lineLimit(1)
        } else {
            Group {
                switch channel.phase {
                case .idle:
                    Text("未启动")
                case .resolvingCodex:
                    Text("查找 codex…")
                case let .waiting(count, nextRunAt):
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("#\(count)  \(remainingSeconds(until: nextRunAt, now: context.date)) 秒后执行")
                            .monospacedDigit()
                    }
                case let .running(count, startedAt):
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("#\(count)  执行中 \(elapsedSeconds(since: startedAt, now: context.date)) 秒")
                            .monospacedDigit()
                    }
                case .stopping:
                    Text("正在停止…")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedResultSection: some View {
        if let channel = selectedChannel {
            if let result = channel.lastResult {
                resultSection(result, channelName: channel.name)
            } else {
                Text(channel.errorMessage ?? "该渠道尚无调用结果")
                    .font(.system(size: 11))
                    .foregroundStyle(channel.errorMessage == nil ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text("选择渠道查看结果")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultSection(_ result: LoopRunResult, channelName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(channelName)
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

    private var selectedChannel: LoopChannel? {
        guard let selectedChannelID else { return nil }
        return store.channels.first(where: { $0.id == selectedChannelID })
    }

    private func selectAvailableChannel() {
        guard selectedChannel == nil else { return }
        selectedChannelID = store.channels.first(where: { $0.isActive })?.id ?? store.channels.first?.id
    }

    private var successSecondRange: LoopSecondRange? {
        secondRange(minimumText: successMinimumText, maximumText: successMaximumText)
    }

    private var failureSecondRange: LoopSecondRange? {
        secondRange(minimumText: failureMinimumText, maximumText: failureMaximumText)
    }

    private func secondRange(minimumText: String, maximumText: String) -> LoopSecondRange? {
        guard let minimum = Int(minimumText), let maximum = Int(maximumText) else { return nil }
        return LoopSecondRange(minimum: minimum, maximum: maximum)
    }

    private var validationMessage: String? {
        if let message = rangeValidationMessage(
            label: "成功后间隔",
            minimumText: successMinimumText,
            maximumText: successMaximumText
        ) {
            return message
        }
        return rangeValidationMessage(
            label: "失败后间隔",
            minimumText: failureMinimumText,
            maximumText: failureMaximumText
        )
    }

    private func rangeValidationMessage(label: String, minimumText: String, maximumText: String) -> String? {
        guard let minimum = Int(minimumText), let maximum = Int(maximumText) else {
            return "\(label)请输入 1 到 86400 的整数秒。"
        }
        guard LoopSecondRange.allowedSeconds.contains(minimum), LoopSecondRange.allowedSeconds.contains(maximum) else {
            return "\(label)范围必须在 1 到 86400 秒之间。"
        }
        guard minimum <= maximum else {
            return "\(label)最小值不能大于最大值。"
        }
        return nil
    }

    private var successMinimumTextBinding: Binding<String> {
        numericBinding(
            text: $successMinimumText,
            otherText: successMaximumText,
            persist: { minimum, maximum in store.setSuccessSecondRange(LoopSecondRange(minimum: minimum, maximum: maximum)!) }
        )
    }

    private var successMaximumTextBinding: Binding<String> {
        numericBinding(
            text: $successMaximumText,
            otherText: successMinimumText,
            valueIsMinimum: false,
            persist: { minimum, maximum in store.setSuccessSecondRange(LoopSecondRange(minimum: minimum, maximum: maximum)!) }
        )
    }

    private var failureMinimumTextBinding: Binding<String> {
        numericBinding(
            text: $failureMinimumText,
            otherText: failureMaximumText,
            persist: { minimum, maximum in store.setFailureSecondRange(LoopSecondRange(minimum: minimum, maximum: maximum)!) }
        )
    }

    private var failureMaximumTextBinding: Binding<String> {
        numericBinding(
            text: $failureMaximumText,
            otherText: failureMinimumText,
            valueIsMinimum: false,
            persist: { minimum, maximum in store.setFailureSecondRange(LoopSecondRange(minimum: minimum, maximum: maximum)!) }
        )
    }

    private func numericBinding(
        text: Binding<String>,
        otherText: String,
        valueIsMinimum: Bool = true,
        persist: @escaping (Int, Int) -> Void
    ) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { newValue in
                let filtered = numericText(from: newValue)
                text.wrappedValue = filtered
                guard let value = Int(filtered), let other = Int(otherText) else { return }
                let minimum = valueIsMinimum ? value : other
                let maximum = valueIsMinimum ? other : value
                guard LoopSecondRange(minimum: minimum, maximum: maximum) != nil else { return }
                persist(minimum, maximum)
            }
        )
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

private struct LoopChannelStatusRing: View {
    let channel: LoopChannel

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !channel.isActive)) { context in
            Circle()
                .trim(from: 0, to: 0.79)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(channel.isActive ? context.date.timeIntervalSinceReferenceDate * 150 : 0))
                .shadow(color: ringColor.opacity(0.75), radius: 2)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    private var ringColor: Color {
        guard channel.isActive else { return .secondary }
        if channel.recoveredFromFailure { return .yellow }
        switch channel.streakSucceeded {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }
}

private struct LoopChannelEditorRequest: Identifiable {
    let id = UUID()
    let channelID: UUID?
    let name: String
    let baseURL: String

    init(channel: LoopChannel?) {
        channelID = channel?.id
        name = channel?.name ?? ""
        baseURL = channel?.baseURL ?? ""
    }
}

private struct LoopChannelEditorView: View {
    @ObservedObject var store: LoopStore
    let request: LoopChannelEditorRequest
    let onSaved: (UUID) -> Void
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false
    @FocusState private var focusedField: EditorField?

    private enum EditorField {
        case name
        case baseURL
        case apiKey
    }

    init(
        store: LoopStore,
        request: LoopChannelEditorRequest,
        onSaved: @escaping (UUID) -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.store = store
        self.request = request
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: request.name)
        _baseURL = State(initialValue: request.baseURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(request.channelID == nil ? "添加渠道" : "编辑渠道")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("下载模板") { downloadTemplate() }
                    .buttonStyle(.bordered)
                Button("导入 TXT") { importTXT() }
                    .buttonStyle(.bordered)
            }

            labeledField("名称") {
                TextField("主渠道", text: $name)
                    .focused($focusedField, equals: .name)
            }
            labeledField("Base URL") {
                TextField("https://example.com/v1", text: $baseURL)
                    .focused($focusedField, equals: .baseURL)
            }
            labeledField("API Key") {
                TextField(request.channelID == nil ? "必填" : "已配置，留空保留", text: $apiKey)
                    .focused($focusedField, equals: .apiKey)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                if request.channelID != nil {
                    Button("删除渠道", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .name
            }
        }
        .confirmationDialog("确认删除该渠道？", isPresented: $showingDeleteConfirmation) {
            Button("删除渠道", role: .destructive) { deleteChannel() }
            Button("取消", role: .cancel) {}
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            content()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func downloadTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "AgentRadar-Loop-Channel-Template.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try LoopChannelImportValues.templateText.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "模板保存失败：\(error.localizedDescription)"
        }
    }

    private func importTXT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let values = try LoopChannelImportValues(text: text)
            name = values.name
            baseURL = values.baseURL
            apiKey = values.apiKey
            errorMessage = nil
        } catch {
            errorMessage = "TXT 导入失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let channelID: UUID
            if let existingID = request.channelID {
                try store.updateChannel(
                    id: existingID,
                    name: name,
                    baseURL: baseURL,
                    apiKey: apiKey.isEmpty ? nil : apiKey
                )
                channelID = existingID
            } else {
                channelID = try store.addChannel(name: name, baseURL: baseURL, apiKey: apiKey)
            }
            onSaved(channelID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteChannel() {
        guard let channelID = request.channelID else { return }
        do {
            try store.deleteChannel(id: channelID)
            onDeleted()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
