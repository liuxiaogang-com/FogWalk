import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppRuntime.model
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var exportDocument: FogWalkArchiveDocument?
    @State private var isLayersPresented = false
    @State private var isReviewPresented = false
    @State private var isRecordingPresented = ProcessInfo.processInfo.arguments.contains("--open-recording")

    var body: some View {
        mapExperience
        .preferredColorScheme(.dark)
        .task { model.loadStoredDataIfNeeded() }
        .fullScreenCover(isPresented: $model.isExploreSheetPresented) {
            ExploreSheet(model: model)
        }
        .sheet(isPresented: $isLayersPresented) { layerPanel.presentationDetents([.height(280)]) }
        .sheet(isPresented: $isReviewPresented) { reviewPanel.presentationDetents([.height(320)]) }
        .sheet(isPresented: $isRecordingPresented) { RecordingPanel(recorder: model.locationManager) }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .gpx, .xml, .fogWalkArchive],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importFiles(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.noticeTitle = "无法选择文件"
                    model.noticeMessage = error.localizedDescription
                }
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .fogWalkArchive,
            defaultFilename: "迷雾足迹备份"
        ) { result in
            model.exportDidFinish(result)
            exportDocument = nil
        }
        .alert(
            model.noticeTitle,
            isPresented: Binding(
                get: { model.noticeMessage != nil },
                set: { if !$0 { model.noticeMessage = nil } }
            )
        ) {
            Button("好") { model.noticeMessage = nil }
        } message: {
            Text(model.noticeMessage ?? "")
        }
    }

    private var mapExperience: some View {
        ZStack {
            FogMapView(
                presentation: model.explorationPresentation,
                isFogVisible: model.isFogVisible && model.hasData,
                isTrackVisible: model.isTrackVisible,
                currentCoordinate: model.activeCoordinate,
                liveCurrentCoordinate: model.liveMapCoordinate,
                centersOnCurrentCoordinate: true,
                initialSpanMeters: 3_000,
                recenterCoordinate: model.liveMapCoordinate,
                recenterRequestID: model.mainMapRecenterRequestID,
                recenterSpanMeters: 3_000,
                trackPresentation: model.presentation,
                overviewRequestID: model.mainMapOverviewRequestID
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(model.loadingMessage).font(.caption2)
                    }
                    .padding(10).background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
                }
                Spacer()
                HStack {
                    if model.liveMapCoordinate == nil {
                        Text(model.hasData ? "暂以最近足迹为参考位置" : "定位后即可探索，无需先导入")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(10).background(.regularMaterial, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    mapControls
                }
                exploreButton
                Button {
                    if model.hasData { isReviewPresented = true } else { isImporterPresented = true }
                } label: {
                    Label(model.hasData ? "回看足迹 · \(model.selectedFilter.rawValue)" : "已有足迹？导入备份",
                          systemImage: model.hasData ? "calendar" : "square.and.arrow.down")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if model.isImporting || model.isPreparingExport {
                workingOverlay
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { isReviewPresented = true } label: {
                Label("足迹", systemImage: "map")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Button { isRecordingPresented = true } label: {
                Label(model.locationManager.isRecording ? "记录中" : "记录", systemImage: "record.circle")
                    .font(.caption).foregroundStyle(model.locationManager.isRecording ? .green : .primary)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("导入数据", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isWorking)
                Button {
                    prepareExport()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasData || model.isWorking)
                Button {
                    isLayersPresented = true
                } label: { Label("地图图层", systemImage: "square.3.layers.3d") }
                Button {
                    isRecordingPresented = true
                } label: {
                    Label("出行记录与省电设置", systemImage: "location")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("更多：数据与地图设置")
        }
    }

    private var emptyLibraryCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "map.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.orange)
            Text("导入你的足迹")
                .font(.title3.bold())
            Text("支持同时选择轨迹 CSV、照片位置 CSV、GPX，或以前导出的 .fogwalk 备份。导入后会保存在本机，今后无需重复解析。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isImporterPresented = true
            } label: {
                Label("选择文件", systemImage: "folder")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(22)
        .frame(maxWidth: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.bottom, 48)
    }

    private var mapControls: some View {
        HStack(spacing: 7) {
            controlButton(icon: "square.3.layers.3d", label: "图层", isActive: false) { isLayersPresented = true }
            controlButton(icon: "location.fill", label: "定位", isActive: false) {
                model.recenterMainMap()
            }
        }
    }

    private var layerPanel: some View {
        NavigationStack {
            Form {
                Toggle("显示探索迷雾", isOn: $model.isFogVisible)
                Toggle("显示历史轨迹", isOn: $model.isTrackVisible)
                Text("迷雾始终依据全部足迹；日期筛选只改变历史轨迹。已探索核心半径为 50 米。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("地图图层").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { isLayersPresented = false } }
        }
    }

    private var reviewPanel: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                filterPicker
                statsCard
                Text(model.hasData ? "查看指定时间的历史轨迹，不会重新遮住过去探索过的区域。" : "还没有历史足迹，可以先探索或从更多菜单导入。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("在地图查看轨迹") {
                    model.isTrackVisible = true
                    model.mainMapOverviewRequestID &+= 1
                    isReviewPresented = false
                }
                .buttonStyle(.borderedProminent).tint(.orange).disabled(!model.hasData || model.isLoading)
                Spacer()
            }
            .padding(20).navigationTitle("足迹回顾").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { isReviewPresented = false } }
        }
    }

    private var statsCard: some View {
        HStack(spacing: 9) {
            stat(value: model.presentation.visiblePointCount.formatted(), label: "点")
            stat(value: distanceText, label: "距离")
            stat(value: "50m", label: "半径")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var filterPicker: some View {
        Picker("时间范围", selection: Binding(
            get: { model.selectedFilter },
            set: { model.selectFilter($0) }
        )) {
            ForEach(TrackTimeFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(3)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(0.78)
    }

    private var exploreButton: some View {
        Button {
            model.locationManager.requestCurrentLocation()
            model.isExploreSheetPresented = true
        } label: {
            HStack {
                Image(systemName: "wand.and.stars")
                Text("去探索")
                    .fontWeight(.bold)
                Spacer()
                Text("发现附近未走过的地方")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
            .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.16))
                Image(systemName: "map.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
            }
            .frame(width: 86, height: 86)
            ProgressView()
                .tint(.orange)
            Text(model.loadingMessage)
                .font(.headline)
        }
        .padding(30)
    }

    private var workingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.orange)
            Text(model.loadingMessage)
                .font(.headline)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 18)
    }

    private func prepareExport() {
        Task {
            guard let data = await model.makeExportData() else { return }
            exportDocument = FogWalkArchiveDocument(data: data)
            isExporterPresented = true
        }
    }

    private func controlButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .orange : .primary)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func stat(value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.caption2.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var distanceText: String {
        let meters = model.presentation.totalDistanceMeters
        if meters >= 1_000 {
            return String(format: "%.1f km", meters / 1_000)
        }
        return "\(Int(meters.rounded())) m"
    }
}

#Preview {
    ContentView()
}
