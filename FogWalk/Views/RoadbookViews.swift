import SwiftUI
import UniformTypeIdentifiers

private func roadbookDistance(_ meters: Double) -> String {
    meters >= 1000 ? String(format: "%.1f 公里", meters / 1000) : "\(Int(max(0, meters))) 米"
}

struct RoadbookLibraryView: View {
    @ObservedObject var store: RoadbookStore
    @ObservedObject var navigator: RoadbookNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var renameID: UUID?
    @State private var newName = ""
    @State private var deleting: Roadbook?
    @State private var path = [UUID]()
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if navigator.recoverable != nil {
                    Section {
                        Button { navigator.resume() } label: {
                            Label("恢复上次未完成的导航", systemImage: "arrow.clockwise")
                        }
                    }
                }
                if store.books.isEmpty {
                    ContentUnavailableView("还没有路书", systemImage: "map", description: Text("导入 GPX 路书，查看全程后开始导航。\n也可以从“文件”或微信选择用迷雾足迹打开。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(store.books) { book in
                    NavigationLink(value: book.id) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(book.name).font(.headline)
                            Text("\(roadbookDistance(book.distance)) · \(book.isLoop ? "环线" : "固定起终点") · \(book.points.count) 个轨迹点")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 7)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { deleting = book }
                        Button("重命名") { newName = book.name; renameID = book.id }.tint(.blue)
                    }
                    .contextMenu {
                        Button("重命名") { newName = book.name; renameID = book.id }
                        Button("删除", role: .destructive) { deleting = book }
                    }
                }
                Section { Text("路书独立保存，不会计入已探索的迷雾足迹。导航提示根据 GPX 形状推算，不含道路名称或道路通行校验。")
                        .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("我的路书")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("返回首页") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { importing = true } label: { Label("导入", systemImage: "plus") }.disabled(store.importing) }
            }
            .navigationDestination(for: UUID.self) { id in
                RoadbookDetailView(store: store, navigator: navigator, id: id)
            }
            .overlay { if store.importing { ProgressView("正在导入路书…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
            // File providers may label GPX as generic data or use another app's UTI.
            // Validate the extension and actual GPX content after selection.
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                switch result { case .success(let url): store.importFile(url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { store.message = error.localizedDescription } }
            }
            .alert("重命名路书", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
                TextField("路书名称", text: $newName)
                Button("取消", role: .cancel) { renameID = nil }
                Button("保存") { if let id = renameID { attempt { try store.rename(id, to: newName) } }; renameID = nil }
            }
            .confirmationDialog("删除这份路书？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) { if let book = deleting { attempt { try store.delete(book.id) } }; deleting = nil }
            }
            .alert("路书", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("好") { store.message = nil }
            } message: { Text(store.message ?? "") }
            .onChange(of: store.selectedID) { _, id in if let id { path = [id]; store.selectedID = nil } }
            .onAppear {
                if let id = store.selectedID { path = [id]; store.selectedID = nil }
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--roadbook-approach"), var book = store.books.first {
                    book.isLoop = true
                    navigator.start(book, entryMeters: book.distance * 0.4)
                }
                #endif
            }
        }
        .fullScreenCover(isPresented: Binding(get: { navigator.session != nil }, set: { _ in })) {
            RoadbookNavigationView(navigator: navigator).interactiveDismissDisabled()
        }
    }
    private func attempt(_ operation: () throws -> Void) { do { try operation() } catch { store.message = error.localizedDescription } }
}

struct RoadbookDetailView: View {
    @ObservedObject var store: RoadbookStore
    @ObservedObject var navigator: RoadbookNavigation
    let id: UUID
    @State private var points = false
    @State private var confirmLoop = false
    @State private var voiceSettings = false
    @State private var choosingEntry = false
    @State private var selectedEntry: Double?
    private var book: Roadbook? { store.books.first { $0.id == id } }
    var body: some View {
        if let book {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RoadbookMapView(points: book.points, waypoints: book.waypoints, showPoints: points)
                        .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(roadbookDistance(book.distance)).font(.largeTitle.bold())
                    Text("\(book.points.count) 个轨迹点 · \(book.waypoints.count) 个命名途经点")
                        .foregroundStyle(.secondary)
                    if let warning = book.importWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Toggle("显示所有轨迹点", isOn: $points)
                    Toggle("环线：可从线路任意位置进入", isOn: Binding(get: { book.isLoop }, set: { enabled in
                        if enabled && book.gap > 20 { confirmLoop = true }
                        else { setLoop(enabled) }
                    })).disabled(book.gap > 120)
                    Text(book.isLoop ? "先在地图选择入口，导航到达后确认开始，沿原顺序绕一圈回到入口。" : "非环线保留原顺序，请先到达原起点。绿色为起点，红色为终点。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if book.gap > 20 && book.gap <= 120 {
                        Text("首尾相距 \(roadbookDistance(book.gap))。设为环线会用直线连接首尾，请确认该段可以通行。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button { if book.isLoop { choosingEntry = true } else { navigator.start(book) } } label: { Label(book.isLoop ? "选择环线入口" : "开始导航", systemImage: "location.north.fill").frame(maxWidth: .infinity).padding(10) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    HStack {
                        Button { navigator.start(book, preview: true) } label: { Label("路线预览", systemImage: "play.circle") }
                        Spacer()
                        Button { voiceSettings = true } label: { Label("导航语音", systemImage: "speaker.wave.2") }
                    }.buttonStyle(.bordered)
                    if !book.waypoints.isEmpty {
                        Text("途经点").font(.headline)
                        ForEach(book.waypoints) { Text($0.name).font(.subheadline) }
                    }
                    Text("路线预览使用模拟位置。真实导航使用手机 GPS，100 米、50 米转弯提醒按路书折线估算；经过转弯后自动更新后续提示。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle(book.name).navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("确认首尾之间可以通行？", isPresented: $confirmLoop, titleVisibility: .visible) {
                Button("连接首尾并设为环线") { setLoop(true) }
            } message: { Text("将添加约 \(Int(book.gap)) 米的直线连接，未经道路规划验证。") }
            .sheet(isPresented: $voiceSettings) { RoadbookVoiceView(navigator: navigator) }
            .sheet(isPresented: $choosingEntry, onDismiss: {
                if let meters = selectedEntry { selectedEntry = nil; navigator.start(book, entryMeters: meters) }
            }) {
                RoadbookEntryView(book: book) { selectedEntry = $0 }
            }
            .onAppear {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--roadbook-entry") { setLoop(true); choosingEntry = true }
                #endif
            }
        } else { ContentUnavailableView("路书不存在", systemImage: "map") }
    }
    private func setLoop(_ enabled: Bool) { do { try store.setLoop(id, enabled: enabled) } catch { store.message = error.localizedDescription } }
}

struct RoadbookVoiceView: View {
    @ObservedObject var navigator: RoadbookNavigation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Toggle("关闭导航语音", isOn: $navigator.muted)
                Picker("中文音色", selection: $navigator.voiceID) {
                    Text("自动选择较高质量音色").tag("")
                    ForEach(navigator.voices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.quality.rawValue > 1 ? "高质量" : "标准")").tag(voice.identifier)
                    }
                }
                Button("试听转弯提醒") { navigator.speak("前方一百米，沿路线右转", preview: true) }
                Text("音色来自手机已安装的 Apple 中文语音。可在系统设置的辅助功能语音选项中下载增强音色，再返回选择；仅有标准音色时仍可能较机械。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("导航语音").toolbar { Button("完成") { dismiss() } }
        }
    }
}
