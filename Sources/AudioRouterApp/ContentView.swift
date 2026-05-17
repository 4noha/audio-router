import SwiftUI
import AppKit
import AudioRouterCore

// MARK: - サイドバー定義（Karabiner-Elements 風のセクション分け）

@available(macOS 14.4, *)
enum Pane: String, CaseIterable, Identifiable {
    case rules, activity, maintenance
    var id: String { rawValue }

    var sidebarLabel: String {
        switch self {
        case .rules:       return "Rules"
        case .activity:    return "Activity"
        case .maintenance: return "Maintenance"
        }
    }
    var icon: String {
        switch self {
        case .rules:       return "slider.horizontal.3"
        case .activity:    return "waveform"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - シェル（サイドバー + コンテンツ）

@available(macOS 14.4, *)
struct ContentView: View {
    @StateObject private var ctl = RouterController()
    @State private var pane: Pane? = .rules

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Routing") {
                    sidebarItem(.rules)
                }
                Section("Diagnostic") {
                    sidebarItem(.activity)
                }
                Section("Maintenance") {
                    sidebarItem(.maintenance)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch pane ?? .rules {
                case .rules:       RulesView(ctl: ctl)
                case .activity:    ActivityView(ctl: ctl)
                case .maintenance: MaintenanceView(ctl: ctl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 780, minHeight: 500)
    }

    private func sidebarItem(_ p: Pane) -> some View {
        Label(p.sidebarLabel, systemImage: p.icon).tag(p as Pane?)
    }
}

// MARK: - 共通ヘッダ（"Karabiner-Elements Settings" 相当）

struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).bold()
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            Divider().padding(.top, 10)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
}

// MARK: - Rules（Karabiner の Complex Modifications 相当）

@available(macOS 14.4, *)
struct RulesView: View {
    @ObservedObject var ctl: RouterController
    @State private var editing: RoutingRule?
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Audio Router — Routing Rules",
                       subtitle: "アプリごとの音声ルートをトグルで個別に有効化")

            HStack(spacing: 10) {
                Button {
                    editing = nil; ctl.refreshLists(); showEditor = true
                } label: {
                    Label("ルールを追加", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    ctl.refreshLists()
                } label: {
                    Label("一覧を更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            if ctl.rules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("ルールがありません")
                        .foregroundStyle(.secondary)
                    Text("「ルールを追加」から FROM アプリと送出先を設定します。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(ctl.rules) { rule in
                            ruleRow(rule)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            RuleEditorView(ctl: ctl, original: editing) { saved in
                if editing == nil { ctl.addRule(saved) }
                else { ctl.updateRule(saved) }
            }
        }
    }

    private func ruleRow(_ rule: RoutingRule) -> some View {
        card {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.sourceName).font(.body).bold()
                    Text(rule.displaySummary)
                        .font(.caption).foregroundStyle(.secondary)
                    if let st = ctl.statusByRule[rule.id], !st.isEmpty {
                        Text(st)
                            .font(.caption2)
                            .foregroundStyle(ctl.active(rule.id) ? .green : .orange)
                    }
                }
                Spacer()

                Toggle("", isOn: Binding(
                    get: { ctl.active(rule.id) },
                    set: { ctl.setEnabled(rule.id, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.blue)

                Button {
                    editing = rule; ctl.refreshLists(); showEditor = true
                } label: {
                    Label("編集", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(ctl.active(rule.id))

                Button(role: .destructive) {
                    ctl.deleteRule(rule.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }
}

// MARK: - ルール編集シート

@available(macOS 14.4, *)
struct RuleEditorView: View {
    @ObservedObject var ctl: RouterController
    let original: RoutingRule?
    let onSave: (RoutingRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var bundleID = ""
    @State private var sourceName = ""
    @State private var host = "127.0.0.1"
    @State private var port = "7878"
    @State private var monitorEnabled = false
    @State private var monitorUID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "ルールを追加" : "ルールを編集")
                .font(.title3).bold()

            GroupBox("FROM — 対象アプリ（音声出力中のプロセス）") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("アプリ", selection: $bundleID) {
                        Text("選択してください").tag("")
                        if !bundleID.isEmpty,
                           !ctl.processes.contains(where: { $0.bundleID == bundleID }) {
                            Text("\(sourceName)（未起動）").tag(bundleID)
                        }
                        ForEach(ctl.processes.filter { !$0.bundleID.isEmpty }) { p in
                            Text(p.name).tag(p.bundleID)
                        }
                    }
                    .onChange(of: bundleID) { _, new in
                        if let p = ctl.processes.first(where: { $0.bundleID == new }) {
                            sourceName = p.name
                        }
                    }
                    Button {
                        ctl.refreshLists()
                    } label: {
                        Label("一覧を更新", systemImage: "arrow.clockwise")
                    }
                }
                .padding(6)
            }

            GroupBox("TO — 送出先") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("4ksplitter (UDP)")
                        TextField("host", text: $host).frame(width: 130)
                        Text(":")
                        TextField("port", text: $port).frame(width: 70)
                    }
                    Toggle("モニタ出力（別デバイスへ流して聴く）", isOn: $monitorEnabled)
                    Picker("出力デバイス", selection: $monitorUID) {
                        Text("既定の出力").tag("")
                        ForEach(ctl.outputs) { d in
                            Text(d.name).tag(d.uid)
                        }
                    }
                    .disabled(!monitorEnabled)
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "追加" : "保存") {
                    var r = original ?? RoutingRule(sourceBundleID: "", sourceName: "")
                    r.sourceBundleID = bundleID
                    r.sourceName = sourceName.isEmpty ? bundleID : sourceName
                    r.sendHost = host
                    r.sendPort = port
                    r.monitorEnabled = monitorEnabled
                    r.monitorDeviceUID = monitorUID
                    onSave(r)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(bundleID.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear {
            ctl.refreshLists()
            if let o = original {
                bundleID = o.sourceBundleID
                sourceName = o.sourceName
                host = o.sendHost
                port = o.sendPort
                monitorEnabled = o.monitorEnabled
                monitorUID = o.monitorDeviceUID
            }
        }
    }
}

// MARK: - Activity（稼働状況）

@available(macOS 14.4, *)
struct ActivityView: View {
    @ObservedObject var ctl: RouterController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Activity",
                       subtitle: "各ルートの稼働状態")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ctl.rules) { rule in
                        card {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(ctl.active(rule.id) ? Color.green : Color.gray)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.sourceName).bold()
                                    Text(ctl.statusByRule[rule.id]
                                         ?? (ctl.active(rule.id) ? "稼働中" : "停止中"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    if ctl.rules.isEmpty {
                        Text("ルールがありません")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(24)
            }
        }
    }
}

// MARK: - Maintenance

@available(macOS 14.4, *)
struct MaintenanceView: View {
    @ObservedObject var ctl: RouterController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Maintenance",
                       subtitle: "一覧更新・終了")
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    ctl.refreshLists()
                } label: {
                    Label("プロセス／デバイス一覧を更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    ctl.stopAll()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("全ルート停止して終了", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(24)
            Spacer()
        }
    }
}
