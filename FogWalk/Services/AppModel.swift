import Foundation
import Combine
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var isImporting = false
    @Published private(set) var isPreparingExport = false
    @Published private(set) var loadingMessage = "正在读取本地足迹…"
    @Published private(set) var dataset: TrackDataset?
    @Published private(set) var librarySummary: ImportSummary?
    @Published private(set) var libraryReadFailed = false
    @Published private(set) var presentation: TrackPresentation = .empty
    @Published private(set) var explorationPresentation: TrackPresentation = .empty
    @Published private(set) var explorationGrid: ExplorationGrid?
    @Published var noticeTitle = "数据"
    @Published var noticeMessage: String?
    @Published var selectedFilter: TrackTimeFilter = .today
    @Published var isFogVisible = !ProcessInfo.processInfo.arguments.contains("--fog-off")
    @Published var isTrackVisible = false
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

    let locationManager: LocationManager
    let homeMapLocation: HomeMapLocation
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
    private var cachedPresentations: [TrackTimeFilter: TrackPresentation] = [:]
    private var baseGrid: ExplorationGrid?
    private var recordedPoints: [TrackPoint] = []
    private var recordingRefreshTask: Task<Void, Never>?
    private var recordingRefreshInFlight = false
    private var presentationDay = Calendar.current.startOfDay(for: Date())

    init(store: TrackDataStore = TrackDataStore(), preferences: UserDefaults = .standard,
         recordingStore: RecordingStore = RecordingStore()) {
        self.store = store
        self.preferences = preferences
        locationManager = LocationManager(preferences: preferences, recordingStore: recordingStore)
        homeMapLocation = HomeMapLocation(preferences: preferences)
        let restored = preferences.data(forKey: "explore-options-v2")
            .flatMap { try? JSONDecoder().decode(ExploreOptions.self, from: $0) }
        exploreOptions = restored ?? ExploreOptions()
        locationManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        homeMapLocation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        locationManager.onSavedPoints = { [weak self] in
            guard let self else { return }
            self.scheduleRecordingRefresh(immediately: !self.hasData || !self.locationManager.wantsRecording)
        }
    }

    var hasData: Bool { locationManager.savedPointCount > 0 || !recordedPoints.isEmpty || (librarySummary?.uniqueCount ?? dataset?.summary.uniqueCount ?? 0) > 0 }
    var isWorking: Bool { isLoading || isImporting || isPreparingExport }

    var activeCoordinate: GeoCoordinate? {
        if let current = liveMapCoordinate { return current }
        return explorationPresentation.latestCoordinate ?? dataset?.points.last.map {
            ChinaCoordinateTransform.mapCoordinate(for: $0.coordinate)
        }
    }

    var liveMapCoordinate: GeoCoordinate? {
        if homeMapLocation.isActive, let coordinate = homeMapLocation.coordinate { return coordinate }
        guard let date = locationManager.currentCoordinateDate, Date().timeIntervalSince(date) <= 60 else { return nil }
        return locationManager.currentCoordinate.map {
            ChinaCoordinateTransform.mapCoordinate(for: $0)
        }
    }

    func recenterMainMap() {
        homeMapLocation.requestRecenter()
    }

    func loadStoredDataIfNeeded() {
        guard UIApplication.shared.applicationState != .background else { return }
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
            let started = ProcessInfo.processInfo.systemUptime
            do {
                if let cached = await store.loadStartup() {
                    applyStartup(cached)
                    NSLog("FOGWALK_STARTUP path=cache points=%ld seconds=%.3f", cached.summary.uniqueCount,
                          ProcessInfo.processInfo.systemUptime - started)
                } else if let loaded = try await store.load() {
                    loadingMessage = "正在首次优化足迹，下次打开会更快…"
                    try await install(loaded)
                    NSLog("FOGWALK_STARTUP path=rebuild points=%ld seconds=%.3f", loaded.summary.uniqueCount,
                          ProcessInfo.processInfo.systemUptime - started)
                }
                try await refreshRecordedPoints()
            } catch {
                libraryReadFailed = true
                noticeTitle = "本地数据读取失败"
                noticeMessage = "原有足迹档案无法读取，原文件未被覆盖。请保留你的备份，并检查设备存储后重试。\n\n\(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isWorking else { return }
        isImporting = true
        recordingRefreshTask?.cancel()
        loadingMessage = "正在导入并去重…"
        Task {
            do {
                // A cache-only launch has no raw points in memory. Always restore
                // the archive before merging; a read failure must never overwrite it.
                let existing = try await fullDataset()
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try TrackDataLoader.importFiles(urls: urls, existing: existing)
                }.value
                loadingMessage = "正在写入本地足迹档案…"
                try await store.save(loaded)
                loadingMessage = "正在更新地图与迷雾…"
                try await install(loaded)
                try await refreshRecordedPoints()
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
        guard hasData, !isWorking else { return nil }
        isPreparingExport = true
        loadingMessage = "正在生成足迹备份…"
        defer { isPreparingExport = false }

        do {
            guard let dataset = try await fullDataset() else { return nil }
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
        if !recordedPoints.isEmpty {
            rebuildTask?.cancel()
            rebuildTask = Task { await rebuildRecordedFilter(filter) }
            return
        }
        if let cached = cachedPresentations[filter] {
            presentation = cached
            return
        }
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
        generateRecommendations(minutes: exploreOptions.minutes,
                                travelMode: exploreOptions.travelMode, category: exploreOptions.category,
                                changeBatch: changeBatch)
    }

    func generateRecommendations(
        minutes: Int,
        travelMode: ExploreTravelMode,
        category: ExploreCategory,
        changeBatch: Bool = false
    ) {
        cancelSearch()
        guard !isLoading, !isImporting, !libraryReadFailed else {
            exploreErrorMessage = libraryReadFailed
                ? "足迹档案尚未恢复，暂不推荐目的地，以免误判已探索区域。请先恢复数据。"
                : "正在恢复已探索区域，请稍后再试。"
            return
        }
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

    private func install(_ loaded: TrackDataset) async throws {
        dataset = loaded
        libraryReadFailed = false
        let snapshot = await Task.detached(priority: .userInitiated) {
            StartupSnapshot.build(dataset: loaded)
        }.value
        let restored = try await Task.detached(priority: .userInitiated, operation: {
            RestoredStartup(summary: snapshot.summary, grid: snapshot.grid,
                            presentations: try snapshot.restoredPresentations())
        }).value
        applyStartup(restored)
        // Cache persistence is best effort. The original archive is authoritative.
        try? await store.saveStartup(snapshot)
    }

    private func applyStartup(_ snapshot: RestoredStartup) {
        presentationDay = Calendar.current.startOfDay(for: Date())
        librarySummary = snapshot.summary
        explorationGrid = snapshot.grid
        baseGrid = snapshot.grid
        recordedPoints = []
        // Revisions must change after an import even when cached filter IDs match.
        explorationRevision += 10
        cachedPresentations = snapshot.presentations.mapValues { value in
            TrackPresentation(revision: explorationRevision + value.revision, filter: value.filter,
                              segments: value.segments, isolatedPoints: value.isolatedPoints,
                              visiblePointCount: value.visiblePointCount, totalDistanceMeters: value.totalDistanceMeters,
                              referenceDate: value.referenceDate, latestCoordinate: value.latestCoordinate)
        }
        explorationPresentation = cachedPresentations[.lifetime] ?? .empty
        presentation = cachedPresentations[selectedFilter] ?? .empty
    }

    private func fullDataset() async throws -> TrackDataset? {
        try await locationManager.finishPendingWrites()
        if dataset == nil { dataset = try await store.load() }
        if (librarySummary?.uniqueCount ?? 0) > 0 && dataset == nil { throw TrackDataStoreError.emptyArchive }
        let batch = try await locationManager.recordingStore.read(after: dataset?.summary.recordingCheckpoint)
        let original = dataset
        guard !batch.points.isEmpty else { return original }
        return await Task.detached(priority: .userInitiated) { TrackDataLoader.merging(batch, into: original) }.value
    }

    func applicationBecameActive() {
        locationManager.setBackground(false)
        locationManager.restoreRecordingIfNeeded()
        locationManager.requestCurrentLocation()
        if !hasStartedLoading { loadStoredDataIfNeeded() }
        if hasStartedLoading && !isLoading {
            if presentationDay != Calendar.current.startOfDay(for: Date()) { refreshCalendarDayIfNeeded() }
            else { scheduleRecordingRefresh(immediately: true) }
        }
    }

    func refreshCalendarDayIfNeeded() {
        guard hasStartedLoading, !isWorking,
              presentationDay != Calendar.current.startOfDay(for: Date()) else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                if let cached = await store.loadStartup() { applyStartup(cached) }
                else {
                    if dataset == nil { dataset = try await store.load() }
                    if let dataset { try await install(dataset) }
                }
                // Force journal-only libraries to refresh even if no points were appended overnight.
                recordedPoints = []
                try await refreshRecordedPoints()
                presentationDay = Calendar.current.startOfDay(for: Date())
            } catch { noticeTitle = "日期更新失败"; noticeMessage = error.localizedDescription }
        }
    }

    private func scheduleRecordingRefresh(immediately: Bool = false) {
        if immediately { recordingRefreshTask?.cancel(); recordingRefreshTask = nil }
        guard UIApplication.shared.applicationState == .active, recordingRefreshTask == nil else { return }
        recordingRefreshTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .seconds(15)) }
            guard let self else { return }
            defer { recordingRefreshTask = nil }
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active, !isWorking else { return }
            do { try await refreshRecordedPoints() }
            catch { noticeTitle = "新足迹恢复失败"; noticeMessage = error.localizedDescription }
        }
    }

    private func refreshRecordedPoints() async throws {
        guard !recordingRefreshInFlight else { return }
        recordingRefreshInFlight = true
        defer { recordingRefreshInFlight = false }
        let batch = try await locationManager.recordingStore.read(after: librarySummary?.recordingCheckpoint)
        guard batch.points != recordedPoints else { return }
        let base = baseGrid ?? ExplorationGrid(coordinates: [])
        let originals = cachedPresentations
        explorationRevision += 10
        let revision = explorationRevision
        let selected = selectedFilter
        let result = await Task.detached(priority: .userInitiated) {
            let recent = TrackDataLoader.merging(batch, into: nil)
            let lifetime = TrackProcessor.makePresentation(dataset: recent, filter: .lifetime, revision: revision)
            let today = TrackProcessor.makePresentation(dataset: recent, filter: .today, revision: revision + 1)
            let combined = Self.combine(originals[.lifetime] ?? .empty, lifetime, revision: revision)
            let originalToday = originals[.today] ?? .empty
            let day = Self.combine(originalToday, today, revision: revision + 1)
            return (base.incorporating(batch.points), combined, selected == .lifetime ? combined : day)
        }.value
        guard !Task.isCancelled, explorationRevision == revision else { return }
        recordedPoints = batch.points
        explorationGrid = result.0
        explorationPresentation = result.1
        presentation = result.2
        if selectedFilter == .sevenDays || selectedFilter == .month { await rebuildRecordedFilter(selectedFilter) }
        // New accepted positions can make a previous recommendation familiar.
        recommendations.removeAll { result.0.isExplored($0.coordinate) }
        if !recommendations.contains(where: { $0.id == selectedRecommendationID }) {
            selectedRecommendationID = recommendations.first?.id
        }
    }

    nonisolated private static func combine(_ first: TrackPresentation, _ second: TrackPresentation, revision: Int) -> TrackPresentation {
        TrackPresentation(revision: revision, filter: second.visiblePointCount > 0 ? second.filter : first.filter,
            segments: (first.segments + second.segments).enumerated().map { TrackSegment(id: $0.offset, coordinates: $0.element.coordinates) },
            isolatedPoints: first.isolatedPoints + second.isolatedPoints,
            visiblePointCount: first.visiblePointCount + second.visiblePointCount,
            totalDistanceMeters: first.totalDistanceMeters + second.totalDistanceMeters,
            referenceDate: second.referenceDate ?? first.referenceDate,
            latestCoordinate: second.latestCoordinate ?? first.latestCoordinate)
    }

    private func rebuildRecordedFilter(_ filter: TrackTimeFilter) async {
        do {
            guard let combined = try await fullDataset() else { return }
            revision += 1
            let target = revision
            let value = await Task.detached(priority: .userInitiated) {
                TrackProcessor.makePresentation(dataset: combined, filter: filter, revision: target)
            }.value
            guard !Task.isCancelled, selectedFilter == filter else { return }
            presentation = value
        } catch { noticeTitle = "足迹读取失败"; noticeMessage = error.localizedDescription }
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
