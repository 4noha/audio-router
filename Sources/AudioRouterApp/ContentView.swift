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
        case .rules:       return "Routing"
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
    @State private var editing: RoutingRule = RoutingRule()
    @State private var isNew = false
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Audio Router — Routing",
                       subtitle: "IN → OUT をトグルで個別に有効化（チャンネル管理）")

            HStack(spacing: 10) {
                Button {
                    var r = RoutingRule(); r.kind = .appRoute
                    editing = r; isNew = true
                    ctl.refreshLists(); showEditor = true
                } label: {
                    Label("アプリ → 4ksplitter", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    var r = RoutingRule(); r.kind = .babigoeHub
                    editing = r; isNew = true
                    ctl.refreshLists(); showEditor = true
                } label: {
                    Label("マイク → babigoe", systemImage: "mic.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

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
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("ルートがありません")
                        .foregroundStyle(.secondary)
                    Text("上のボタンで IN→OUT のルートを追加します。")
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
            RuleEditorView(ctl: ctl, original: editing, isNew: isNew) { saved in
                if isNew { ctl.addRule(saved) } else { ctl.updateRule(saved) }
            }
        }
    }

    // IN  →  OUT   [status]  [toggle][編集][🗑]
    private func ruleRow(_ rule: RoutingRule) -> some View {
        card {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label(rule.displayIn, systemImage: rule.inIcon)
                            .font(.body).bold()
                            .labelStyle(.titleAndIcon)
                        Image(systemName: "arrow.right")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(rule.displayOut)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
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
                    editing = rule; isNew = false
                    ctl.refreshLists(); showEditor = true
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

// MARK: - ルール編集シート（kind で IN を分岐）

@available(macOS 14.4, *)
struct RuleEditorView: View {
    @ObservedObject var ctl: RouterController
    let original: RoutingRule
    let isNew: Bool
    let onSave: (RoutingRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var bundleID = ""
    @State private var sourceName = ""
    @State private var micUID = ""
    @State private var micName = ""
    @State private var host = "127.0.0.1"
    @State private var port = "7878"
    @State private var udpEnabled = false
    @State private var monitorEnabled = false
    @State private var monitorUID = ""

    private var kind: RuleKind { original.kind }

    private var canSave: Bool {
        kind == .appRoute ? !bundleID.isEmpty : true   // hub は既定マイク可
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((isNew ? "ルートを追加" : "ルートを編集")
                 + (kind == .babigoeHub ? "（マイク → babigoe）" : "（アプリ → 4ksplitter）"))
                .font(.title3).bold()

            if kind == .appRoute {
                GroupBox("IN — 対象アプリ（音声出力中のプロセス）") {
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
                        Button { ctl.refreshLists() } label: {
                            Label("一覧を更新", systemImage: "arrow.clockwise")
                        }
                    }
                    .padding(6)
                }
            } else {
                GroupBox("IN — マイク（audio-router が babigoe へ供給）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("マイク", selection: $micUID) {
                            Text("既定の入力").tag("")
                            if !micUID.isEmpty,
                               !ctl.inputs.contains(where: { $0.uid == micUID }) {
                                Text("\(micName)（未接続）").tag(micUID)
                            }
                            ForEach(ctl.inputs) { d in
                                Text(d.name).tag(d.uid)
                            }
                        }
                        .onChange(of: micUID) { _, new in
                            if let d = ctl.inputs.first(where: { $0.uid == new }) {
                                micName = d.name
                            }
                        }
                        Button { ctl.refreshLists() } label: {
                            Label("一覧を更新", systemImage: "arrow.clockwise")
                        }
                    }
                    .padding(6)
                }
            }

            GroupBox("OUT — " + (kind == .babigoeHub
                                 ? "babigoe(声質変換) → 4ksplitter"
                                 : "4ksplitter（共有メモリ）")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("モニタ出力（別デバイスで聴く）", isOn: $monitorEnabled)
                    Picker("出力デバイス", selection: $monitorUID) {
                        Text("既定の出力").tag("")
                        ForEach(ctl.outputs) { d in
                            Text(d.name).tag(d.uid)
                        }
                    }
                    .disabled(!monitorEnabled)
                    Divider()
                    Toggle("追加 UDP 送出（4ksplitter 以外の経路）", isOn: $udpEnabled)
                    HStack {
                        Text("UDP")
                        TextField("host", text: $host).frame(width: 130)
                        Text(":")
                        TextField("port", text: $port).frame(width: 70)
                    }
                    .disabled(!udpEnabled)
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "追加" : "保存") {
                    var r = original
                    r.sourceBundleID = bundleID
                    r.sourceName = sourceName.isEmpty ? bundleID : sourceName
                    r.micUID = micUID
                    r.micName = micName
                    r.sendHost = host
                    r.sendPort = port
                    r.udpEnabled = udpEnabled
                    r.monitorEnabled = monitorEnabled
                    r.monitorDeviceUID = monitorUID
                    onSave(r)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            ctl.refreshLists()
            bundleID = original.sourceBundleID
            sourceName = original.sourceName
            micUID = original.micUID
            micName = original.micName
            host = original.sendHost
            port = original.sendPort
            udpEnabled = original.udpEnabled
            monitorEnabled = original.monitorEnabled
            monitorUID = original.monitorDeviceUID
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
                                    Text("\(rule.displayIn) → \(rule.displayOut)").bold()
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
