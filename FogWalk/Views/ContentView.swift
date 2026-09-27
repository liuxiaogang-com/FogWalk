import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppRuntime.model
    @StateObject private var roadbooks = RoadbookStore()
    @StateObject private var roadbookNavigator = RoadbookNavigation(recorder: AppRuntime.model.locationManager)
    @State private var isRoadbooksPresented = ProcessInfo.processInfo.arguments.contains("--open-roadbooks")
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var exportDocument: FogWalkArchiveDocument?
    @State private var isLayersPresented = false
    @State private var isReviewPresented = false
    @State private var isRecordingPresented = ProcessInfo.processInfo.arguments.contains("--open-recording")
    @State private var isDestinationSearchPresented = false
    @State private var isHomeDestinationVisible = true

    var body: some View {
        mapExperience
        .preferredColorScheme(.dark)
        .task {
            model.loadStoredDataIfNeeded()
            #if DEBUG && targetEnvironment(simulator)
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--roadbook-fixture") {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("roadbook-test.gpx")
                if let data = try? Data(contentsOf: url), let id = try? roadbooks.importData(data, name: "GPX 测试路书") {
                    if arguments.contains("--roadbook-detail") { roadbooks.selectedID = id }
                    if arguments.contains("--roadbook-preview"), let book = roadbooks.books.first(where: { $0.id == id }) { roadbookNavigator.start(book, preview: true) }
                }
            }
            #endif
        }
        .onAppear { updateMapSensors() }
        .onDisappear { model.homeMapLocation.setActive(false) }
        .onChange(of: scenePhase) { _, phase in
            updateMapSensors()
            if phase != .active { roadbookNavigator.checkpoint() }
        }
        .onChange(of: model.isExploreSheetPresented) { _, _ in updateMapSensors() }
        .onChange(of: isRoadbooksPresented) { _, _ in updateMapSensors() }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "gpx" {
                isRoadbooksPresented = true
                roadbooks.importFile(url)
            } else if url.pathExtension.lowercased() == "fogwalk" { model.importFiles([url]) }
        }
        .fullScreenCover(isPresented: $isRoadbooksPresented) {
            RoadbookLibraryView(store: roadbooks, navigator: roadbookNavigator)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.refreshCalendarDayIfNeeded()
        }
        .fullScreenCover(isPresented: $model.isExploreSheetPresented) {
            ExploreSheet(model: model)
        }
        .sheet(isPresented: $isDestinationSearchPresented) {
            DestinationSearchSheet(model: model)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isLayersPresented) { layerPanel.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $isReviewPresented) { reviewPanel.presentationDetents([.medium, .large]) }
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
                liveCurrentCoordinate: model.homeMapLocation.coordinate,
                centersOnCurrentCoordinate: true,
                initialSpanMeters: 3_000,
                recenterCoordinate: model.homeMapLocation.recenterCoordinate,
                recenterRequestID: model.homeMapLocation.recenterRequestID,
                recenterSpanMeters: 3_000,
                trackPresentation: model.presentation,
                overviewRequestID: model.mainMapOverviewRequestID + model.homeDestinationOverviewRequestID,
                highlightedRoute: model.homeDestination?.routeCoordinates ?? [],
                destinationCoordinate: model.homeDestination?.coordinate,
                onDestinationVisibilityChange: { isVisible in
                    withAnimation(.easeOut(duration: 0.18)) { isHomeDestinationVisible = isVisible }
                },
                orientation: model.homeMapLocation.orientation,
                deviceHeading: model.homeMapLocation.heading,
                followsCurrentLocation: model.homeMapLocation.isFollowing,
                onUserMovedMap: { model.homeMapLocation.pauseFollowing() }
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                destinationSearchBar
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(model.loadingMessage).font(.caption2)
                    }
                    .padding(10).background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
                }
                Spacer()
                if model.homeDestination != nil { homeDestinationCard }
                VStack(alignment: .trailing, spacing: 8) {
                    if let message = mapStatusMessage {
                        Text(message)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(10).background(.regularMaterial, in: Capsule())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    mapControls
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
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

            if let destination = model.homeDestination,
               !isHomeDestinationVisible,
               let guidance = DestinationGuidance(origin: model.activeCoordinate, destination: destination.coordinate) {
                DestinationEdgeIndicator(
                    title: destination.title,
                    guidance: guidance,
                    mapHeading: model.homeMapLocation.orientation == .phoneHeading
                        ? (model.homeMapLocation.heading ?? 0) : 0,
                    action: model.showHomeDestinationOverview
                )
            }

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
            Button { isRoadbooksPresented = true } label: {
                Label("路书", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption).padding(.horizontal, 12).frame(height: 44)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
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

    private var destinationSearchBar: some View {
        Button {
            isDestinationSearchPresented = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("搜索明确地点")
                        .font(.subheadline.weight(.semibold))
                    Text(model.homeDestination == nil ? "公园、商场、地址或具体名称" : "当前目标：\(model.homeDestination?.title ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(MapControlButtonStyle())
        .accessibilityHint("搜索真实地点并设为地图目标")
    }

    private var homeDestinationCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.homeDestination?.title ?? "目标地点")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(homeDestinationStatusText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.homeDestinationRouteMessage == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if model.isPlanningHomeRoute {
                ProgressView().tint(.orange).frame(width: 36, height: 36)
            } else {
                Button(action: model.refreshHomeDestinationRoute) {
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                }
                .buttonStyle(MapControlButtonStyle())
                .accessibilityLabel("刷新目标路线")
            }
            Button(action: model.showHomeDestinationOverview) {
                Image(systemName: "map").frame(width: 36, height: 36)
            }
            .buttonStyle(MapControlButtonStyle())
            .accessibilityLabel("查看目标路线总览")
            Button(action: model.clearHomeDestination) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(MapControlButtonStyle())
            .accessibilityLabel("清除目标")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var homeDestinationStatusText: String {
        if model.isPlanningHomeRoute { return "正在规划道路路线…" }
        if let message = model.homeDestinationRouteMessage { return message }
        guard let destination = model.homeDestination else { return "" }
        if destination.isRouteVerified {
            return "\(destination.distanceText) · \(destination.timeText)"
        }
        if let guidance = DestinationGuidance(origin: model.activeCoordinate, destination: destination.coordinate) {
            return "直线 \(guidance.distanceText)"
        }
        return "等待当前位置"
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
            controlButton(icon: model.homeMapLocation.orientation.icon,
                          label: model.homeMapLocation.orientation.title,
                          isActive: model.homeMapLocation.orientation == .phoneHeading) {
                model.homeMapLocation.toggleOrientation()
            }
            .accessibilityLabel("地图朝向")
            .accessibilityValue(model.homeMapLocation.orientation.title)
            .accessibilityHint("点击切换北方朝上或手机朝向")
            controlButton(icon: "location.fill", label: "定位", isActive: model.homeMapLocation.isFollowing) {
                model.recenterMainMap()
            }
        }
        .sensoryFeedback(.selection, trigger: model.homeMapLocation.orientation)
        .sensoryFeedback(.selection, trigger: model.homeMapLocation.recenterRequestID)
    }

    private func updateMapSensors() {
        // Permission prompts make the scene inactive; keep foreground sensors
        // available until the app actually backgrounds or leaves the home map.
        model.homeMapLocation.setActive(scenePhase != .background && !model.isExploreSheetPresented && !isRoadbooksPresented)
    }

    private var mapStatusMessage: String? {
        let location = model.homeMapLocation
        if let message = location.message { return message }
        if location.coordinate == nil {
            return model.hasData ? "暂以最近足迹为参考位置，点击定位更新" : "点击定位即可探索，无需先导入"
        }
        if location.orientation == .phoneHeading && location.heading == nil { return "等待手机方向，请远离磁性物体" }
        if !location.isFollowing { return "自由浏览 · 点击定位恢复居中跟随" }
        return nil
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
                    model.homeMapLocation.pauseFollowing()
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
        .buttonStyle(MapControlButtonStyle())
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

private struct MapControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DestinationEdgeIndicator: View {
    let title: String
    let guidance: DestinationGuidance
    let mapHeading: Double
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let angle = guidance.screenBearing(mapHeading: mapHeading)
            let radians = CGFloat(angle) * .pi / 180
            let horizontal = sin(radians)
            let vertical = -cos(radians)
            let halfWidth = max(1, proxy.size.width / 2 - 62)
            let halfHeight = max(1, proxy.size.height / 2 - 190)
            let horizontalScale = abs(horizontal) < 0.001 ? Double.greatestFiniteMagnitude : halfWidth / abs(horizontal)
            let verticalScale = abs(vertical) < 0.001 ? Double.greatestFiniteMagnitude : halfHeight / abs(vertical)
            let scale = min(horizontalScale, verticalScale)

            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up")
                        .font(.body.bold())
                        .rotationEffect(.degrees(angle))
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).lineLimit(1)
                        Text("直线 \(guidance.distanceText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.orange.opacity(0.55), lineWidth: 1) }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(MapControlButtonStyle())
            .accessibilityLabel("目标在屏幕外，\(title)，直线 \(guidance.distanceText)")
            .accessibilityHint("点击查看路线总览")
            .position(
                x: proxy.size.width / 2 + horizontal * scale,
                y: proxy.size.height / 2 + vertical * scale
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
