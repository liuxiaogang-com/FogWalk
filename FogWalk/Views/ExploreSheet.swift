import SwiftUI
import MapKit

/// Kept under the original filename to avoid unnecessary project-file churn;
/// this is now a full-screen map experience, not a bottom sheet.
struct ExploreSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30
    @State private var travelMode: ExploreTravelMode = .walking
    @State private var category: ExploreCategory = .any
    @State private var selectedRecommendationID: UUID?
    @State private var isManualSelectionMode = ProcessInfo.processInfo.arguments.contains("--manual-select")
    @State private var manualCoordinate: GeoCoordinate?
    @State private var manualMapItem: MKMapItem?
    @State private var isResolvingManualAddress = false

    private let minuteOptions = [15, 30, 45, 60, 90]

    private var selectedRecommendation: ExploreRecommendation? {
        model.recommendations.first { $0.id == selectedRecommendationID }
            ?? model.recommendations.first
    }

    private var displayedDestination: GeoCoordinate? {
        isManualSelectionMode ? manualCoordinate : selectedRecommendation?.coordinate
    }

    private var mapDestinations: [ExploreMapDestination] {
        guard !isManualSelectionMode else { return [] }
        return model.recommendations.enumerated().map { index, recommendation in
            ExploreMapDestination(
                id: recommendation.id,
                coordinate: recommendation.coordinate,
                rank: index + 1
            )
        }
    }

    var body: some View {
        ZStack {
            FogMapView(
                presentation: model.explorationPresentation,
                isFogVisible: true,
                isTrackVisible: false,
                currentCoordinate: model.activeCoordinate,
                liveCurrentCoordinate: model.locationManager.currentCoordinate.map {
                    ChinaCoordinateTransform.mapCoordinate(for: $0)
                },
                centersOnCurrentCoordinate: true,
                initialSpanMeters: 3_000,
                highlightedRoute: isManualSelectionMode ? [] : selectedRecommendation?.routeCoordinates ?? [],
                destinationCoordinate: displayedDestination,
                destinationMarkers: mapDestinations,
                selectedDestinationID: selectedRecommendationID,
                onDestinationSelection: { selectedRecommendationID = $0 },
                isLongPressSelectionEnabled: isManualSelectionMode,
                onLongPressSelection: { selectManualDestination($0) }
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                exploreHeader
                if !isManualSelectionMode {
                    conditionBar
                }
                Spacer()
                if isManualSelectionMode {
                    manualSelectionPanel
                } else if model.recommendations.isEmpty {
                    searchPrompt
                } else {
                    recommendationCarousel
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.locationManager.requestCurrentLocation()
            selectedRecommendationID = model.recommendations.first?.id
        }
        .onChange(of: model.recommendations.map(\.id)) { _, ids in
            selectedRecommendationID = ids.first
        }
    }

    private var exploreHeader: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.bold())
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("探索未知")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()

            Button { toggleManualSelection() } label: {
                Label(isManualSelectionMode ? "取消" : "选点", systemImage: "hand.tap")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .foregroundStyle(isManualSelectionMode ? .orange : .primary)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var headerSubtitle: String {
        if isManualSelectionMode {
            return manualCoordinate == nil ? "长按地图选择一个目的地" : "已标记自选目的地"
        }
        return selectedRecommendation == nil ? "终点只会选在未探索区域" : "路线与终点已显示在迷雾地图"
    }

    private var manualSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("地图选点", systemImage: "hand.tap.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Spacer()
                if let manualCoordinate {
                    explorationStatus(for: manualCoordinate)
                }
            }

            if let manualCoordinate {
                Text(manualMapItem?.name ?? "自选目的地")
                    .font(.title3.bold())
                HStack(alignment: .top, spacing: 7) {
                    if isResolvingManualAddress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "mappin")
                    }
                    Text(manualAddressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 14) {
                    if let start = model.activeCoordinate {
                        Label(distanceText(from: start, to: manualCoordinate), systemImage: "ruler")
                    }
                    Label("长按其他位置可重新选择", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Button { openManualDestinationInMaps() } label: {
                    Label("开始导航", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.draw.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text("在地图任意区域长按约半秒")
                        .font(.headline)
                    Text("选中后会显示地址和探索状态，再由你决定是否导航。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var conditionBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(minuteOptions, id: \.self) { value in
                    Button("\(value) 分钟") { changeOptions { minutes = value } }
                }
            } label: {
                compactOption("\(minutes) 分", icon: "clock")
            }

            Menu {
                ForEach(ExploreTravelMode.allCases) { item in
                    Button(item.rawValue) { changeOptions { travelMode = item } }
                }
            } label: {
                compactOption(travelMode.rawValue, icon: travelMode.systemImage)
            }

            Menu {
                ForEach(ExploreCategory.allCases) { item in
                    Button(item.rawValue) { changeOptions { category = item } }
                }
            } label: {
                compactOption(category.rawValue, icon: category.symbol)
            }

            Button { generate() } label: {
                Group {
                    if model.isGeneratingRecommendations {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.caption.bold())
                    }
                }
                .frame(width: 38, height: 38)
                .foregroundStyle(.white)
                .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.isGeneratingRecommendations)
            .accessibilityLabel("搜索未知目的地")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现未走过的目的地")
                        .font(.headline)
                    Text("结果会同时标在地图上，也可以左右滑动切换")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.orange)
            }

            Button { generate() } label: {
                HStack {
                    if model.isGeneratingRecommendations {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text("搜索未知目的地")
                        .fontWeight(.bold)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .foregroundStyle(.white)
                .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.isGeneratingRecommendations)

            if let message = model.exploreErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var recommendationCarousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(model.recommendations) { recommendation in
                    recommendationCard(recommendation)
                        .containerRelativeFrame(.horizontal, count: 5, span: 4, spacing: 10)
                        .id(recommendation.id)
                        .onTapGesture {
                            withAnimation(.snappy) {
                                selectedRecommendationID = recommendation.id
                            }
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $selectedRecommendationID)
        .frame(height: 196)
    }

    private func recommendationCard(_ recommendation: ExploreRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("未探索目的地", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Spacer()
                if recommendation.id == selectedRecommendationID {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Text(recommendation.title)
                .font(.title3.bold())
                .lineLimit(1)
            Text(recommendation.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 7) {
                recommendationMetric("\(recommendation.estimatedMinutes) 分", icon: "clock")
                recommendationMetric(distanceText(for: recommendation), icon: travelMode.systemImage)
                recommendationMetric(
                    "未知 \(Int((recommendation.routeNoveltyRatio * 100).rounded()))%",
                    icon: "cloud.fog.fill"
                )
            }

            Button { openRecommendationInMaps(recommendation) } label: {
                Label("开始导航", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func compactOption(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func recommendationMetric(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.white.opacity(0.055), in: Capsule())
    }

    private func changeOptions(_ change: () -> Void) {
        change()
        model.clearRecommendations()
        selectedRecommendationID = nil
    }

    private func generate() {
        model.generateRecommendations(
            mode: .destination,
            minutes: minutes,
            travelMode: travelMode,
            category: category
        )
    }

    private func distanceText(for recommendation: ExploreRecommendation) -> String {
        recommendation.distanceMeters >= 1_000
            ? String(format: "%.1f 公里", recommendation.distanceMeters / 1_000)
            : "\(Int(recommendation.distanceMeters.rounded())) 米"
    }

    private func openRecommendationInMaps(_ recommendation: ExploreRecommendation) {
        let item = recommendation.mapItem ?? MKMapItem(
            location: recommendation.coordinate.location,
            address: nil
        )
        let mode: String
        switch travelMode {
        case .walking: mode = MKLaunchOptionsDirectionsModeWalking
        case .cycling: mode = MKLaunchOptionsDirectionsModeCycling
        case .automobile: mode = MKLaunchOptionsDirectionsModeDriving
        }
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }

    private func toggleManualSelection() {
        isManualSelectionMode.toggle()
        if !isManualSelectionMode {
            manualCoordinate = nil
            manualMapItem = nil
            isResolvingManualAddress = false
        }
    }

    private func selectManualDestination(_ coordinate: GeoCoordinate) {
        manualCoordinate = coordinate
        manualMapItem = nil
        isResolvingManualAddress = true
        Task {
            let request = MKReverseGeocodingRequest(location: coordinate.location)
            do {
                let resolvedItem = try await request?.mapItems.first
                guard manualCoordinate == coordinate else { return }
                manualMapItem = resolvedItem
            } catch {
                guard manualCoordinate == coordinate else { return }
                manualMapItem = nil
            }
            isResolvingManualAddress = false
        }
    }

    private var manualAddressText: String {
        if isResolvingManualAddress { return "正在识别地址…" }
        if let address = manualMapItem?.address {
            return address.shortAddress ?? address.fullAddress
        }
        guard let coordinate = manualCoordinate else { return "" }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private func explorationStatus(for coordinate: GeoCoordinate) -> some View {
        let isExplored = model.explorationGrid?.isExplored(coordinate) == true
        return Label(
            isExplored ? "已探索区域" : "未探索区域",
            systemImage: isExplored ? "checkmark.circle.fill" : "cloud.fog.fill"
        )
        .font(.caption.bold())
        .foregroundStyle(isExplored ? Color.secondary : Color.orange)
    }

    private func distanceText(from start: GeoCoordinate, to destination: GeoCoordinate) -> String {
        let meters = start.location.distance(from: destination.location)
        if meters >= 1_000 { return String(format: "直线 %.1f 公里", meters / 1_000) }
        return "直线 \(Int(meters.rounded())) 米"
    }

    private func openManualDestinationInMaps() {
        guard let coordinate = manualCoordinate else { return }
        let item = manualMapItem ?? MKMapItem(location: coordinate.location, address: nil)
        let mode: String
        switch travelMode {
        case .walking: mode = MKLaunchOptionsDirectionsModeWalking
        case .cycling: mode = MKLaunchOptionsDirectionsModeCycling
        case .automobile: mode = MKLaunchOptionsDirectionsModeDriving
        }
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }
}
