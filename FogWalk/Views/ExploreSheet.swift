import SwiftUI
import MapKit

struct ExploreSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isManualSelectionMode = ProcessInfo.processInfo.arguments.contains("--manual-select")
    @State private var manualCoordinate: GeoCoordinate?
    @State private var manualMapItem: MKMapItem?
    @State private var manualRoute: ExploreRecommendation?
    @State private var manualTask: Task<Void, Never>?
    @State private var manualError: String?
    @State private var isResolving = false
    @State private var isPlanning = false
    @State private var detail: ExploreRecommendation?
    @State private var navigationError: String?
    @State private var isOpeningNavigation = false
    @AppStorage("navigation-app-v1") private var navigationApp: NavigationApp = .amap
    @State private var overviewRequestID = 0
    @State private var recenterRequestID = 0
    @ScaledMetric(relativeTo: .body) private var cardHeight = 214.0

    private var selectedRecommendation: ExploreRecommendation? {
        model.recommendations.first { $0.id == model.selectedRecommendationID } ?? model.recommendations.first
    }

    private var displayedRoute: ExploreRecommendation? {
        isManualSelectionMode ? manualRoute : selectedRecommendation
    }

    private var mapDestinations: [ExploreMapDestination] {
        guard !isManualSelectionMode else { return [] }
        return model.recommendations.enumerated().map {
            ExploreMapDestination(id: $0.element.id, coordinate: $0.element.coordinate, rank: $0.offset + 1)
        }
    }

    var body: some View {
        ZStack {
            FogMapView(
                presentation: model.explorationPresentation, isFogVisible: true, isTrackVisible: false,
                currentCoordinate: model.activeCoordinate, liveCurrentCoordinate: model.liveMapCoordinate,
                centersOnCurrentCoordinate: true, initialSpanMeters: 3_000, showsBasePOIs: false,
                recenterCoordinate: model.liveMapCoordinate, recenterRequestID: recenterRequestID,
                overviewRequestID: overviewRequestID,
                highlightedRoute: displayedRoute?.routeCoordinates ?? [],
                destinationCoordinate: isManualSelectionMode ? manualCoordinate : selectedRecommendation?.coordinate,
                destinationMarkers: mapDestinations, selectedDestinationID: model.selectedRecommendationID,
                onDestinationSelection: { id in
                    withAnimation(.snappy) { model.selectedRecommendationID = id }
                },
                isLongPressSelectionEnabled: isManualSelectionMode,
                onLongPressSelection: selectManualDestination
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                header
                if !isManualSelectionMode { conditionBar }
                if model.liveMapCoordinate == nil {
                    Text(model.hasData ? "以最近足迹为起点 · 获取定位后可重试" : "等待当前位置 · 没有历史足迹也能开始")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(8).background(.regularMaterial, in: Capsule())
                }
                Spacer(minLength: 8)
                mapTools
                if isManualSelectionMode {
                    manualPanel
                } else {
                    if model.isGeneratingRecommendations || model.exploreErrorMessage != nil || model.exploreBatchNotice != nil {
                        searchStatus
                    }
                    if model.recommendations.isEmpty {
                        if !model.isGeneratingRecommendations && model.exploreErrorMessage == nil { emptyPrompt }
                    } else {
                        carousel
                        Button { model.searchDestinations(changeBatch: true) } label: {
                            Label("换一批目的地", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                        }
                        .buttonStyle(.plain).disabled(model.isGeneratingRecommendations)
                        .frame(maxWidth: .infinity).background(.regularMaterial, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $detail) { destinationDetail($0) }
        .onAppear {
            model.locationManager.requestCurrentLocation()
            if model.selectedRecommendationID == nil { model.selectedRecommendationID = model.recommendations.first?.id }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--fixture-detail") { detail = selectedRecommendation }
            if ProcessInfo.processInfo.arguments.contains("--fixture-manual"), let sample = selectedRecommendation {
                isManualSelectionMode = true
                manualCoordinate = sample.coordinate
                manualMapItem = sample.mapItem
                manualRoute = sample
            }
            #endif
        }
        .onDisappear { manualTask?.cancel(); model.cancelSearch() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("返回地图")
            Text(isManualSelectionMode ? "地图选点" : "探索附近").font(.headline)
            Spacer()
            Button { toggleManualSelection() } label: {
                Label(isManualSelectionMode ? "退出选点" : "选点", systemImage: "hand.tap")
                    .font(.subheadline).frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain).padding(.trailing, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var conditionBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { value in
                        Button("\(value) 分钟以内") { model.exploreOptions.minutes = value }
                    }
                } label: { conditionLabel("\(model.exploreOptions.minutes) 分", icon: "clock") }
                Divider().frame(height: 18)
                Menu {
                    ForEach(ExploreTravelMode.allCases) { mode in
                        Button(mode.rawValue) { model.exploreOptions.travelMode = mode }
                    }
                } label: { conditionLabel(model.exploreOptions.travelMode.rawValue, icon: model.exploreOptions.travelMode.systemImage) }
                Divider().frame(height: 18)
                Menu {
                    ForEach(ExploreCategory.allCases) { category in
                        Button(category.rawValue) { model.exploreOptions.category = category }
                    }
                } label: { conditionLabel(model.exploreOptions.category.rawValue, icon: nil) }
                Button { model.searchDestinations() } label: {
                    Image(systemName: "magnifyingglass").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).foregroundStyle(.white)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(model.isGeneratingRecommendations)
                .accessibilityLabel("搜索未知目的地")
            }
            Text("单程时间预算 · 只推荐未探索终点")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 6).padding(.top, 4).padding(.bottom, 3)
        }
        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func conditionLabel(_ title: String, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(title).lineLimit(1).minimumScaleFactor(0.85)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.caption.weight(.medium)).foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var mapTools: some View {
        HStack {
            Spacer()
            if displayedRoute != nil || !mapDestinations.isEmpty {
                Button { overviewRequestID &+= 1 } label: {
                    Label("总览", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.medium)).padding(.horizontal, 12).frame(height: 44)
                }
                .buttonStyle(.plain).background(.regularMaterial, in: Capsule())
            }
            Button {
                model.locationManager.requestCurrentLocation()
                recenterRequestID &+= 1
            } label: {
                Image(systemName: "location.fill").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).background(.regularMaterial, in: Circle())
            .accessibilityLabel("回到当前位置")
        }
    }

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("下一站，去没走过的地方").font(.headline)
            Text("在上方选择时间和类型，点击搜索。地点会显示在地图上。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var searchStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isGeneratingRecommendations {
                HStack {
                    ProgressView().tint(.orange)
                    Text("正在寻找可到达的未知地点…").font(.subheadline)
                    Spacer()
                    Button("取消") { model.cancelSearch() }.frame(minHeight: 44)
                }
            } else if let error = model.exploreErrorMessage {
                Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                HStack {
                    Button("重试") { model.searchDestinations() }.frame(minHeight: 44)
                    if model.locationManager.authorizationStatus == .denied || model.locationManager.authorizationStatus == .restricted {
                        Button("位置设置") { openLocationSettings() }.frame(minHeight: 44)
                    } else {
                        Button("增加时间") {
                            model.exploreOptions.minutes = min(90, model.exploreOptions.minutes + 15)
                            model.searchDestinations()
                        }
                        .frame(minHeight: 44).disabled(model.exploreOptions.minutes >= 90)
                    }
                }
                .buttonStyle(.bordered).tint(.orange)
            } else if let notice = model.exploreBatchNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var carousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(model.recommendations) { recommendation in
                    recommendationCard(recommendation)
                        .containerRelativeFrame(.horizontal, count: 5, span: 4, spacing: 12)
                        .id(recommendation.id)
                        .onTapGesture { withAnimation(.snappy) { model.selectedRecommendationID = recommendation.id } }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $model.selectedRecommendationID, anchor: .leading)
        .frame(height: cardHeight)
    }

    private func recommendationCard(_ recommendation: ExploreRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recommendation.title).font(.headline).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(recommendation.addressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 12) {
                Label(recommendation.timeText, systemImage: "clock")
                Text(recommendation.distanceText)
            }
            .font(.caption).foregroundStyle(.secondary)
            Label(recommendation.noveltyText, systemImage: recommendation.isRouteVerified ? "sparkles" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(recommendation.isRouteVerified ? Color.cyan : .secondary)
            Spacer(minLength: 0)
            Button {
                model.selectedRecommendationID = recommendation.id
                detail = recommendation
            } label: {
                HStack { Text("去这里"); Spacer(); Image(systemName: "arrow.right") }
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.white).background(.orange, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
        }
        .padding(16).frame(height: cardHeight - 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(recommendation.id == model.selectedRecommendationID ? Color.orange.opacity(0.6) : .clear, lineWidth: 1)
        }
    }

    private var manualPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let coordinate = manualCoordinate {
                HStack {
                    Text(manualMapItem?.name ?? "自选位置").font(.headline).lineLimit(2)
                    Spacer()
                    Text(model.isWorking || model.libraryReadFailed ? "探索状态待确认"
                         : model.explorationGrid?.isExplored(coordinate) == true ? "已探索" : "未探索")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(isResolving ? "正在识别地址…" : (manualMapItem?.address?.shortAddress ?? "已标记地图位置"))
                    .font(.caption).foregroundStyle(.secondary)
                if let route = manualRoute {
                    Text("\(route.timeText) · \(route.distanceText)").font(.subheadline)
                    Text(route.noveltyText).font(.caption).foregroundStyle(.cyan)
                }
                if let manualError { Text(manualError).font(.caption).foregroundStyle(.secondary) }
                Button {
                    if let manualRoute { detail = manualRoute } else { planManualRoute() }
                } label: {
                    HStack {
                        if isPlanning { ProgressView().tint(.white) }
                        Text(isPlanning ? "正在规划路线…" : manualRoute == nil ? "在地图预览路线" : "查看目的地详情")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(.orange).disabled(isPlanning || isResolving)
            } else {
                Label("长按地图，选择一个目的地", systemImage: "hand.tap").font(.headline)
                Text("先在迷雾地图预览路线，再决定是否出发。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private func destinationDetail(_ recommendation: ExploreRecommendation) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(recommendation.title).font(.title2.bold())
                    Label(recommendation.addressText, systemImage: "mappin")
                        .foregroundStyle(.secondary)
                    HStack { Text(recommendation.timeText); Spacer(); Text(recommendation.distanceText) }
                        .font(.headline)
                    Label(recommendation.noveltyText, systemImage: "map")
                    Text(recommendation.isRouteVerified
                         ? "路线已经显示在本 App 的迷雾地图中。关闭详情后可继续查看。"
                         : "尚未取得可通行路线。时间和距离仅为直线估算，不保证在预算内可达。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button {
                        detail = nil
                        overviewRequestID &+= 1
                    } label: {
                        Label("回到地图查看", systemImage: "map").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    Text("将目的地交给所选地图，从当前位置重新规划路线；线路可能与本 App 的探索预览不同。出发前可在首页开启出行记录，后台也会保存足迹。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Picker("导航软件", selection: $navigationApp) {
                        ForEach(NavigationApp.allCases) { app in Text(app.title).tag(app) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isOpeningNavigation)
                    .onChange(of: navigationApp) { _, _ in navigationError = nil }
                    Button { openNavigation(recommendation) } label: {
                        Label(isOpeningNavigation ? "正在打开地图…" : "在\(navigationApp.title)导航", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange).disabled(isOpeningNavigation)
                    if let navigationError { Text(navigationError).font(.caption).foregroundStyle(.orange) }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(.regularMaterial)
            }
            .navigationTitle("目的地").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { detail = nil } }
        }
        .presentationDetents([.medium, .large])
        .onAppear { navigationError = nil }
    }

    private func toggleManualSelection() {
        manualTask?.cancel()
        model.cancelSearch()
        isManualSelectionMode.toggle()
        manualCoordinate = nil
        manualMapItem = nil
        manualRoute = nil
        manualError = nil
        isResolving = false
        isPlanning = false
    }

    private func selectManualDestination(_ coordinate: GeoCoordinate) {
        manualTask?.cancel()
        manualCoordinate = coordinate
        manualMapItem = nil
        manualRoute = nil
        manualError = nil
        isPlanning = false
        isResolving = true
        manualTask = Task {
            let request = MKReverseGeocodingRequest(location: coordinate.location)
            let resolved = try? await request?.mapItems.first
            guard !Task.isCancelled, isManualSelectionMode, manualCoordinate == coordinate else { return }
            manualMapItem = resolved
            isResolving = false
        }
    }

    private func planManualRoute() {
        guard !model.isWorking, !model.libraryReadFailed else {
            manualError = "请先完成足迹数据恢复，再计算路线与探索状态。"; return
        }
        guard let coordinate = manualCoordinate, let start = model.activeCoordinate else {
            manualError = "尚未获得起点位置，请先定位。"; return
        }
        manualTask?.cancel()
        isPlanning = true
        manualError = nil
        // Reverse geocoding supplies a label, never moves the user's selected endpoint.
        let destination = MKMapItem(location: coordinate.location, address: manualMapItem?.address)
        destination.name = manualMapItem?.name ?? "自选目的地"
        manualTask = Task {
            do {
                let route = try await ExplorePlanner().previewRoute(start: start, destination: destination,
                    travelMode: model.exploreOptions.travelMode,
                    explorationGrid: model.explorationGrid ?? ExplorationGrid(coordinates: []))
                guard !Task.isCancelled, isManualSelectionMode, manualCoordinate == coordinate else { return }
                manualRoute = route
                overviewRequestID &+= 1
            } catch {
                guard !Task.isCancelled, manualCoordinate == coordinate else { return }
                manualError = "暂时无法取得这条路线，请重试或重新选点。不会用直线代替道路。"
            }
            isPlanning = false
        }
    }

    private func openNavigation(_ recommendation: ExploreRecommendation) {
        guard !isOpeningNavigation else { return }
        isOpeningNavigation = true
        navigationError = nil
        let selectedApp = navigationApp
        let mode = model.exploreOptions.travelMode
        Task { @MainActor in
            defer { isOpeningNavigation = false }
            do { try await ExternalNavigation.open(recommendation, in: selectedApp, travelMode: mode) }
            catch { navigationError = error.localizedDescription }
        }
    }

    private func openLocationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
