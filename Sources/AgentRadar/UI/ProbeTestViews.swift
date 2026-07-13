import SwiftUI
import AppKit

struct ProbeTestSheet: View {
    @ObservedObject var store: ProbeTestStore
    @Binding var isPresented: Bool
    @State private var showingAddSheet = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("接口测试")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("新增") {
                    showingAddSheet = true
                }
                .buttonStyle(.borderedProminent)

                Button("关闭") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }

            Table(store.rows) {
                TableColumn("协议") { row in
                    Text(row.protocolName)
                        .font(.system(size: 11))
                }
                .width(min: 90, ideal: 100)

                TableColumn("Base URL") { row in
                    Text(row.config.baseURL)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 160, ideal: 200)

                TableColumn("模型") { row in
                    Text(row.config.model)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 140, ideal: 180)

                TableColumn("间隔") { row in
                    Text(String(format: "%.1fs", row.config.intervalSeconds))
                        .font(.system(size: 11, design: .monospaced))
                }
                .width(min: 70, ideal: 80)

                TableColumn("状态") { row in
                    ProbeStatusHistoryButton(store: store, row: row)
                }
                .width(min: 190, ideal: 220)

                TableColumn("操作") { row in
                    HStack(spacing: 8) {
                        Button(row.isRunning ? "停止" : "开始") {
                            if row.isRunning {
                                store.stopConfig(id: row.id)
                            } else {
                                store.startConfig(id: row.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("删除") {
                            store.deleteConfig(id: row.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .width(min: 130, ideal: 140)
            }
        }
        .padding(16)
        .frame(width: 920, height: 420, alignment: .topLeading)
        .sheet(isPresented: $showingAddSheet) {
            ProbeTestAddSheet(store: store)
        }
    }
}

private struct ProbeStatusHistoryButton: View {
    @ObservedObject var store: ProbeTestStore
    let row: ProbeTestRow
    @State private var showingHistory = false

    var body: some View {
        Button {
            showingHistory = true
        } label: {
            HStack(spacing: 6) {
                Text(row.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(row.statusText == "成功" ? .green : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
            ProbeStatusHistoryPopover(entries: store.history(for: row.id))
        }
    }
}

private struct ProbeStatusHistoryPopover: View {
    let entries: [ProbeTestHistoryEntry]

    private static let timestampFormatter: DateFormatter = {
        // 历史列表会频繁重绘，复用 formatter 避免每行重复创建。
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近 10 条")
                .font(.system(size: 13, weight: .semibold))

            if entries.isEmpty {
                Text("暂无记录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(historyTimestamp(entry.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280, height: 220, alignment: .topLeading)
    }

    private func historyTimestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }
}

private struct ProbeTestAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ProbeTestStore
    @State private var protocolType: ProbeTestProtocol = .openAI
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var intervalText = "1"
    @State private var models: [String] = []
    @State private var selectedModel = ""
    @State private var isLoadingModels = false
    @State private var errorMessage: String?
    @State private var isShowingAPIKey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("新增测试")
                    .font(.system(size: 14, weight: .semibold))

                formRow("协议") {
                    Picker("", selection: $protocolType) {
                        ForEach(ProbeTestProtocol.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200, alignment: .leading)
                }

                formRow("Base URL") {
                    HStack(spacing: 8) {
                        AppKitTextInput(text: $baseURL, placeholder: "https://api.openai.com/v1")
                            .frame(height: 24)

                        Button("粘贴") {
                            baseURL = NSPasteboard.general.string(forType: .string) ?? baseURL
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                formRow("API Key") {
                    HStack(spacing: 8) {
                        if isShowingAPIKey {
                            AppKitTextInput(text: $apiKey, placeholder: "sk-...")
                                .frame(height: 24)
                        } else {
                            AppKitSecureInput(text: $apiKey, placeholder: "sk-...")
                                .frame(height: 24)
                        }

                        Button(isShowingAPIKey ? "隐藏" : "显示") {
                            isShowingAPIKey.toggle()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("粘贴") {
                            apiKey = NSPasteboard.general.string(forType: .string) ?? apiKey
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                formRow("模型") {
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedModel) {
                            Text(models.isEmpty ? "先加载模型" : "请选择模型").tag("")
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button(isLoadingModels ? "加载中..." : "加载模型") {
                            Task { await loadModels() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoadingModels || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                formRow("测试间隔秒") {
                    AppKitTextInput(text: $intervalText, placeholder: "1")
                        .frame(width: 120, alignment: .leading)
                        .frame(height: 24)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("保存") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(width: 520, height: 420, alignment: .topLeading)
    }

    private var canSave: Bool {
        guard let interval = Double(intervalText), interval >= 1 else { return false }
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedModel.isEmpty
    }

    private func loadModels() async {
        isLoadingModels = true
        errorMessage = nil
        do {
            let loadedModels = try await store.fetchModels(baseURL: baseURL, apiKey: apiKey)
            models = loadedModels
            if !loadedModels.contains(selectedModel) {
                selectedModel = loadedModels.first ?? ""
            }
            if loadedModels.isEmpty {
                errorMessage = "没有获取到模型列表。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingModels = false
    }

    private func save() {
        guard let interval = Double(intervalText), interval >= 1 else {
            errorMessage = "测试间隔最小 1 秒。"
            return
        }

        do {
            try store.addConfig(
                protocolType: protocolType,
                baseURL: baseURL,
                apiKey: apiKey,
                model: selectedModel,
                intervalSeconds: interval
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            content()
        }
    }
}

private struct AppKitTextInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.font = .systemFont(ofSize: 12)
        textField.focusRingType = .none
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }
    }
}

private struct AppKitSecureInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let textField = NSSecureTextField()
        textField.placeholderString = placeholder
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.font = .systemFont(ofSize: 12)
        textField.focusRingType = .none
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSSecureTextField else { return }
            text = textField.stringValue
        }
    }
}
