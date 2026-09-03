import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var exportDocument: FogWalkArchiveDocument?

    var body: some View {
        ZStack {
            if model.isLoading {
                loadingView
            } else {
                mapExperience
            }
        }
        .preferredColorScheme(.dark)
        .task { model.loadStoredDataIfNeeded() }
        .fullScreenCover(isPresented: $model.isExploreSheetPresented) {
            ExploreSheet(model: model)
        }
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
                presentation: model.presentation,
                isFogVisible: model.isFogVisible && model.hasData,
                isTrackVisible: model.isTrackVisible,
                currentCoordinate: model.activeCoordinate,
                recenterCoordinate: model.liveMapCoordinate,
                recenterRequestID: model.mainMapRecenterRequestID,
                recenterSpanMeters: 3_000
            )
            .ignoresSafeArea()

            if !model.hasData {
                emptyLibraryCard
            }

            VStack(spacing: 10) {
                topBar
                Spacer()
                if model.hasData {
                    HStack {
                        Spacer()
                        mapControls
                    }
                    exploreButton
                    filterPicker
                }
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
            if model.hasData { statsCard }
            Spacer(minLength: 8)
            Button {
                model.locationManager.toggleRecording()
            } label: {
                Label(
                    model.locationManager.isRecording ? "记录中" : "开始记录",
                    systemImage: model.locationManager.isRecording ? "pause.fill" : "record.circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.locationManager.isRecording ? .green : .primary)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("导入数据", systemImage: "square.and.arrow.down")
                }
                Button {
                    prepareExport()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasData)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("导入与导出")
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
            controlButton(
                icon: model.isFogVisible ? "cloud.fog.fill" : "cloud.fog",
                label: model.isFogVisible ? "迷雾开" : "迷雾关",
                isActive: model.isFogVisible
            ) {
                model.isFogVisible.toggle()
            }
            .disabled(!model.hasData)
            controlButton(
                icon: model.isTrackVisible ? "point.bottomleft.forward.to.point.topright.scurvepath" : "eye.slash",
                label: model.isTrackVisible ? "轨迹开" : "轨迹关",
                isActive: model.isTrackVisible
            ) {
                model.isTrackVisible.toggle()
            }
            .disabled(!model.hasData)
            controlButton(icon: "location.fill", label: "定位", isActive: false) {
                model.recenterMainMap()
            }
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
                .frame(height: 36)
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
