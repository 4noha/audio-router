import SwiftUI
import AppKit
import AudioRouterCore

@available(macOS 14.4, *)
enum Pane: String, CaseIterable, Identifiable {
    case routing, activity, maintenance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .routing:     return "Routing"
        case .activity:    return "Activity"
        case .maintenance: return "Maintenance"
        }
    }
    var icon: String {
        switch self {
        case .routing:     return "arrow.triangle.branch"
        case .activity:    return "waveform"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

@available(macOS 14.4, *)
struct ContentView: View {
    @StateObject private var ctl = RouterController()
    @State private var pane: Pane? = .routing

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Patchbay") { sidebarItem(.routing) }
                Section("Diagnostic") { sidebarItem(.activity) }
                Section("Maintenance") { sidebarItem(.maintenance) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch pane ?? .routing {
                case .routing:     RoutingView(ctl: ctl)
                case .activity:    ActivityView(ctl: ctl)
                case .maintenance: MaintenanceView(ctl: ctl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 520)
    }
    private func sidebarItem(_ p: Pane) -> some View {
        Label(p.label, systemImage: p.icon).tag(p as Pane?)
    }
}

struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).bold()
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            Divider().padding(.top, 10)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    c().padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
}

// MARK: - Routing（エッジ一覧）

@available(macOS 14.4, *)
struct RoutingView: View {
    @ObservedObject var ctl: RouterController
    @State private var editing = RouteEdge(role: .input, endpoint: .appTap)
    @State private var isNew = false
    @State private var showEditor = false

    private func add(_ role: EdgeRole, _ ep: EdgeEndpoint) {
        var e = RouteEdge(role: role, endpoint: ep)
        e.busName = ctl.busNames.first ?? "bus1"
        editing = e; isNew = true; ctl.refreshLists(); showEditor = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Audio Router — Patchbay",
                       subtitle: "IN→[bus] / [bus]→OUT を個別トグルで結線")

            HStack(spacing: 10) {
                Menu {
                    Button("アプリ → bus") { add(.input, .appTap) }
                    Button("マイク → bus") { add(.input, .mic) }
                    Button("babigoe(出力) → bus") { add(.input, .babigoeOut) }
                } label: { Label("IN を追加", systemImage: "plus.circle.fill") }
                    .menuStyle(.borderlessButton).fixedSize()

                Menu {
                    Button("bus → 4ksplitter") { add(.output, .splitter) }
                    Button("bus → babigoe(入力)") { add(.output, .babigoeIn) }
                } label: { Label("OUT を追加", systemImage: "plus.circle") }
                    .menuStyle(.borderlessButton).fixedSize()

                Button { ctl.refreshLists() } label: {
                    Label("一覧更新", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 18)

            if ctl.edges.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("エッジがありません").foregroundStyle(.secondary)
                    Text("IN（アプリ/マイク/babigoe）と OUT（4ksplitter/babigoe）を追加し、同じ bus 名で繋ぎます。")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(ctl.edges) { e in row(e) }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            EdgeEditorView(ctl: ctl, original: editing, isNew: isNew) { saved in
                if isNew { ctl.addEdge(saved) } else { ctl.updateEdge(saved) }
            }
        }
    }

    private func row(_ e: RouteEdge) -> some View {
        card {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Label(e.displayLeft, systemImage: e.icon)
                            .font(.body).bold().labelStyle(.titleAndIcon)
                        Image(systemName: "arrow.right")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(e.displayRight).font(.body).foregroundStyle(.secondary)
                        Text(e.role == .input ? "IN" : "OUT")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                    if let s = ctl.statusByEdge[e.id], !s.isEmpty {
                        Text(s).font(.caption2)
                            .foregroundStyle(ctl.active(e.id) ? .green : .orange)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { ctl.active(e.id) },
                    set: { ctl.setEnabled(e.id, $0) }))
                    .toggleStyle(.switch).labelsHidden().tint(.blue)
                Button {
                    editing = e; isNew = false; ctl.refreshLists(); showEditor = true
                } label: { Label("編集", systemImage: "pencil") }
                    .buttonStyle(.bordered).disabled(ctl.active(e.id))
                Button(role: .destructive) { ctl.deleteEdge(e.id) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.bordered).tint(.red)
            }
        }
    }
}

// MARK: - エッジ編集

@available(macOS 14.4, *)
struct EdgeEditorView: View {
    @ObservedObject var ctl: RouterController
    let original: RouteEdge
    let isNew: Bool
    let onSave: (RouteEdge) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var busName = "bus1"
    @State private var appBundleID = ""
    @State private var appName = ""
    @State private var muteSource = false
    @State private var micUID = ""
    @State private var micName = ""

    private var role: EdgeRole { original.role }
    private var ep: EdgeEndpoint { original.endpoint }
    private var canSave: Bool {
        if ep == .appTap { return !appBundleID.isEmpty }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((isNew ? "エッジを追加" : "エッジを編集")
                 + "（\(role == .input ? "IN" : "OUT"): "
                 + "\(role == .input ? ep.label + "→bus" : "bus→" + ep.label)）")
                .font(.title3).bold()

            if ep == .appTap {
                GroupBox("ソース — アプリ（音声出力中）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("アプリ", selection: $appBundleID) {
                            Text("選択してください").tag("")
                            if !appBundleID.isEmpty,
                               !ctl.processes.contains(where: { $0.bundleID == appBundleID }) {
                                Text("\(appName)（未起動）").tag(appBundleID)
                            }
                            ForEach(ctl.processes.filter { !$0.bundleID.isEmpty }) { p in
                                Text(p.name).tag(p.bundleID)
                            }
                        }
                        .onChange(of: appBundleID) { _, v in
                            if let p = ctl.processes.first(where: { $0.bundleID == v }) {
                                appName = p.name
                            }
                        }
                        Toggle("元アプリをミュート（タップ中スピーカーに出さない）",
                               isOn: $muteSource)
                        Button { ctl.refreshLists() } label: {
                            Label("一覧更新", systemImage: "arrow.clockwise")
                        }
                    }.padding(6)
                }
            } else if ep == .mic {
                GroupBox("ソース — マイク") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("マイク", selection: $micUID) {
                            Text("既定の入力").tag("")
                            if !micUID.isEmpty,
                               !ctl.inputs.contains(where: { $0.uid == micUID }) {
                                Text("\(micName)（未接続）").tag(micUID)
                            }
                            ForEach(ctl.inputs) { d in Text(d.name).tag(d.uid) }
                        }
                        .onChange(of: micUID) { _, v in
                            if let d = ctl.inputs.first(where: { $0.uid == v }) {
                                micName = d.name
                            }
                        }
                        Button { ctl.refreshLists() } label: {
                            Label("一覧更新", systemImage: "arrow.clockwise")
                        }
                    }.padding(6)
                }
            } else {
                GroupBox(role == .input
                         ? "ソース — babigoe 処理済(/babigoe.out)"
                         : "シンク — \(ep == .splitter ? "4ksplitter(/4ksp.voice)" : "babigoe 入力(/babigoe.in)")") {
                    Text(role == .input
                         ? "babigoe が書く処理済み音声を読み取り bus へ流します。"
                         : "bus の音声を共有メモリへ送出します。")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }

            GroupBox("バス（同じ名前の IN と OUT が繋がります）") {
                HStack {
                    Text("bus 名")
                    TextField("bus1", text: $busName).frame(width: 160)
                    if !ctl.busNames.isEmpty {
                        Menu("既存") {
                            ForEach(ctl.busNames, id: \.self) { n in
                                Button(n) { busName = n }
                            }
                        }.fixedSize()
                    }
                }.padding(6)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "追加" : "保存") {
                    var e = original
                    e.busName = busName.isEmpty ? "bus1" : busName
                    e.appBundleID = appBundleID
                    e.appName = appName.isEmpty ? appBundleID : appName
                    e.muteSource = muteSource
                    e.micUID = micUID
                    e.micName = micName
                    onSave(e); dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22).frame(width: 480)
        .onAppear {
            ctl.refreshLists()
            busName = original.busName
            appBundleID = original.appBundleID
            appName = original.appName
            muteSource = original.muteSource
            micUID = original.micUID
            micName = original.micName
        }
    }
}

// MARK: - Activity

@available(macOS 14.4, *)
struct ActivityView: View {
    @ObservedObject var ctl: RouterController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Activity", subtitle: "各エッジの稼働と流量（毎秒更新）")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ctl.edges) { e in
                        card {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(ctl.active(e.id) ? Color.green : Color.gray)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(e.displayLeft) → \(e.displayRight)").bold()
                                    Text(ctl.statusByEdge[e.id]
                                         ?? (ctl.active(e.id) ? "稼働中" : "停止中"))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                    if ctl.edges.isEmpty {
                        Text("エッジがありません").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }.padding(24)
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
            PaneHeader(title: "Maintenance", subtitle: "一覧更新・終了")
            VStack(alignment: .leading, spacing: 14) {
                Button { ctl.refreshLists() } label: {
                    Label("プロセス／デバイス一覧を更新", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered)
                Button(role: .destructive) {
                    ctl.stopAll(); NSApplication.shared.terminate(nil)
                } label: {
                    Label("全エッジ停止して終了", systemImage: "power")
                }.buttonStyle(.bordered).tint(.red)
            }.padding(24)
            Spacer()
        }
    }
}
