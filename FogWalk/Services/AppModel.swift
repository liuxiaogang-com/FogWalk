import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var isImporting = false
    @Published private(set) var isPreparingExport = false
    @Published private(set) var loadingMessage = "正在读取本地足迹…"
    @Published private(set) var dataset: TrackDataset?
    @Published private(set) var presentation: TrackPresentation = .empty
    @Published private(set) var explorationPresentation: TrackPresentation = .empty
    @Published private(set) var explorationGrid: ExplorationGrid?
    @Published var noticeTitle = "数据"
    @Published var noticeMessage: String?
    @Published var selectedFilter: TrackTimeFilter = .today
    @Published var isFogVisible = !ProcessInfo.processInfo.arguments.contains("--fog-off")
    @Published var isTrackVisible = false
    @Published private(set) var mainMapRecenterRequestID = 0
    @Published var mainMapOverviewRequestID = 0
    @Published var isExploreSheetPresented = ProcessInfo.processInfo.arguments.contains("--open-explore")
    @Published var recommendations: [ExploreRecommendation] = []
    @Published var isGeneratingRecommendations = false
    @Published var exploreErrorMessage: String?
    @Published var selectedRecommendationID: UUID?
    @Published var exploreBatchNotice: String?
    @Published var exploreOptions: ExploreOptions {
        didSet {
            guard oldValue != exploreOptions else { return }
            if let data = try? JSONEncoder().encode(exploreOptions) {
                preferences.set(data, forKey: "explore-options-v2")
            }
            clearRecommendations()
            seenDestinationKeys = []
        }
    }

    let locationManager = LocationManager()
    private let store: TrackDataStore
    private var hasStartedLoading = false
    private var revision = 0
    private var explorationRevision = 10_000
    private var rebuildTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let preferences: UserDefaults
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = SearchGeneration()
    private var seenDestinationKeys = Set<String>()

    init(store: TrackDataStore = TrackDataStore(), preferences: UserDefaults = .standard) {
        self.store = store
        self.preferences = preferences
        let restored = preferences.data(forKey: "explore-options-v2")
            .flatMap { try? JSONDecoder().decode(ExploreOptions.self, from: $0) }
        exploreOptions = restored ?? ExploreOptions()
        locationManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var hasData: Bool { dataset?.points.isEmpty == false }
    var isWorking: Bool { isLoading || isImporting || isPreparingExport }

    var activeCoordinate: GeoCoordinate? {
        if let current = locationManager.currentCoordinate {
            return ChinaCoordinateTransform.mapCoordinate(for: current)
        }
        return presentation.latestCoordinate ?? dataset?.points.last.map {
            ChinaCoordinateTransform.mapCoordinate(for: $0.coordinate)
        }
    }

    var liveMapCoordinate: GeoCoordinate? {
        locationManager.currentCoordinate.map {
            ChinaCoordinateTransform.mapCoordinate(for: $0)
        }
    }

    func recenterMainMap() {
        locationManager.requestCurrentLocation()
        mainMapRecenterRequestID &+= 1
    }

    func loadStoredDataIfNeeded() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            recommendations = UIFixture.recommendations
            selectedRecommendationID = recommendations.first?.id
            if ProcessInfo.processInfo.arguments.contains("--fixture-error") {
                recommendations = []
                exploreErrorMessage = "附近暂未找到未探索的这类地点。可以更换类型，或主动增加时间。"
            }
            isLoading = false
            return
        }
        #endif
        isLoading = true
        loadingMessage = "正在读取本地足迹…"

        Task {
            do {
                if let loaded = try await store.load() {
                    loadingMessage = "正在恢复地图与迷雾…"
                    await install(loaded)
                }
            } catch {
                noticeTitle = "本地数据读取失败"
                noticeMessage = "原有足迹档案无法读取，你仍可重新导入备份。\n\n\(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        loadingMessage = "正在导入并去重…"
        let existing = dataset

        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try TrackDataLoader.importFiles(urls: urls, existing: existing)
                }.value
                loadingMessage = "正在写入本地足迹档案…"
                try await store.save(loaded)
                loadingMessage = "正在更新地图与迷雾…"
                await install(loaded)
                noticeTitle = "导入完成"
                noticeMessage = "已保存 \(loaded.summary.uniqueCount.formatted()) 个唯一位置。以后启动会直接读取本地档案，重复导入的数据不会重复计数。"
            } catch {
                noticeTitle = "导入失败"
                noticeMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    func makeExportData() async -> Data? {
        guard let dataset, !isPreparingExport else { return nil }
        isPreparingExport = true
        loadingMessage = "正在生成足迹备份…"
        defer { isPreparingExport = false }

        do {
            return try await Task.detached(priority: .userInitiated) {
                try TrackArchiveCodec.encode(dataset)
            }.value
        } catch {
            noticeTitle = "导出失败"
            noticeMessage = error.localizedDescription
            return nil
        }
    }

    func exportDidFinish(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            noticeTitle = "导出完成"
            noticeMessage = "足迹备份已经保存。这个 .fogwalk 文件可以在本 App 中重新导入。"
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                noticeTitle = "导出失败"
                noticeMessage = error.localizedDescription
            }
        }
    }

    func selectFilter(_ filter: TrackTimeFilter) {
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuildPresentation(filter: filter) }
    }

    func clearRecommendations() {
        cancelSearch()
        recommendations = []
        selectedRecommendationID = nil
        exploreErrorMessage = nil
        exploreBatchNotice = nil
    }

    func cancelSearch() {
        _ = searchGeneration.advance()
        searchTask?.cancel()
        searchTask = nil
        isGeneratingRecommendations = false
    }

    func searchDestinations(changeBatch: Bool = false) {
        generateRecommendations(mode: .destination, minutes: exploreOptions.minutes,
                                travelMode: exploreOptions.travelMode, category: exploreOptions.category,
                                changeBatch: changeBatch)
    }

    func generateRecommendations(
        mode: ExploreMode,
        minutes: Int,
        travelMode: ExploreTravelMode,
        category: ExploreCategory,
        changeBatch: Bool = false
    ) {
        cancelSearch()
        guard let start = activeCoordinate else {
            locationManager.requestCurrentLocation()
            exploreErrorMessage = "尚未获得定位。请允许位置访问，定位后点击重试。"
            return
        }
        let grid = explorationGrid ?? ExplorationGrid(coordinates: [])
        let generation = searchGeneration.value
        if changeBatch { seenDestinationKeys.formUnion(recommendations.map(\.stableKey)) }
        exploreErrorMessage = nil
        exploreBatchNotice = nil
        isGeneratingRecommendations = true
        searchTask = Task {
            do {
                let result = try await ExplorePlanner().recommendations(
                    start: start,
                    mode: mode,
                    minutes: minutes,
                    travelMode: travelMode,
                    category: category,
                    explorationGrid: grid,
                    excluding: changeBatch ? seenDestinationKeys : []
                )
                guard !Task.isCancelled, searchGeneration.accepts(generation) else { return }
                recommendations = result
                selectedRecommendationID = result.first?.id
                if changeBatch, !result.isEmpty, result.allSatisfy({ seenDestinationKeys.contains($0.stableKey) }) {
                    exploreBatchNotice = "这个范围内暂无更多新地点，已保留可用候选。"
                }
                if result.isEmpty {
                    exploreErrorMessage = "附近暂时没有符合条件的地点，请增加时间或更换类型。"
                }
            } catch {
                guard !Task.isCancelled, searchGeneration.accepts(generation) else { return }
                exploreErrorMessage = error.localizedDescription
            }
            guard searchGeneration.accepts(generation) else { return }
            isGeneratingRecommendations = false
            searchTask = nil
        }
    }

    private func install(_ loaded: TrackDataset) async {
        dataset = loaded
        explorationRevision += 1
        let targetExplorationRevision = explorationRevision
        let artifacts = await Task.detached(priority: .userInitiated) {
            (
                ExplorationGrid(points: loaded.points),
                TrackProcessor.makePresentation(
                    dataset: loaded,
                    filter: .lifetime,
                    revision: targetExplorationRevision
                )
            )
        }.value
        explorationGrid = artifacts.0
        explorationPresentation = artifacts.1
        await rebuildPresentation(filter: selectedFilter)
    }

    private func rebuildPresentation(filter: TrackTimeFilter) async {
        guard let dataset else {
            presentation = .empty
            return
        }
        revision += 1
        let targetRevision = revision
        let result = await Task.detached(priority: .userInitiated) {
            TrackProcessor.makePresentation(
                dataset: dataset,
                filter: filter,
                revision: targetRevision
            )
        }.value
        guard !Task.isCancelled, selectedFilter == filter else { return }
        presentation = result
    }
}
