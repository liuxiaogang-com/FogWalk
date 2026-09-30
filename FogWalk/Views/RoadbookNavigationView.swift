import SwiftUI

private func navigationDistance(_ meters: Double) -> String {
    meters >= 1000 ? String(format: "%.1f 公里", meters / 1000) : "\(Int(max(0, meters))) 米"
}

private struct NavigationGlass: ViewModifier {
    var clear = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26))
        } else if clear {
            content.glassEffect(.clear, in: .rect(cornerRadius: 26))
        } else {
            content
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 26))
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false) }
        }
    }
}

struct RoadbookEntryView: View {
    let book: Roadbook
    let select: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var meters: Double?
    private var course: RoadbookCourse { RoadbookCourse(points: book.points) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                RoadbookMapView(points: book.points, waypoints: book.waypoints,
                    entryPoint: meters.map { course.point(at: $0) }, onSelectEntry: { meters = $0 })
                    .overlay(alignment: .top) {
                        Label("轻点蓝色线路选择入口", systemImage: "hand.tap")
                            .font(.subheadline.weight(.medium)).padding(14).modifier(NavigationGlass()).padding(12)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 12) {
                    Text(meters == nil ? "选择你方便到达的位置" : "入口已选 · 将从这里绕行一圈").font(.headline)
                    Text("可缩放地图精确选点，也可拖动下方滑块沿线路选择。到达入口后会再次确认开始。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { meters ?? 0 }, set: { meters = $0 }), in: 0...course.length)
                        .accessibilityLabel("沿环线选择入口")
                    if let meters {
                        Text("原路线 \(navigationDistance(meters)) 处 · 圈长约 \(navigationDistance(course.startingLoop(at: meters).length))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        guard let meters else { return }; select(meters); dismiss()
                    } label: { Label("导航到这个入口", systemImage: "flag.checkered").frame(maxWidth: .infinity).padding(10) }
                        .buttonStyle(.glassProminent).disabled(meters == nil)
                }.padding(18).modifier(NavigationGlass())
            }.padding(16)
            .navigationTitle("选择环线入口").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

struct RoadbookNavigationView: View {
    @ObservedObject var navigator: RoadbookNavigation
    @State private var overview = false
    @State private var browsing = false
    @State private var recenter = 0
    @State private var zoom = 0
    @State private var showPoints = false
    @State private var ending = false
    @State private var voiceSettings = false
    @State private var showInformation = false
    private var next: RoadbookTurn? { navigator.upcoming.first }
    private var remaining: Double { max(0, navigator.guidanceCourse.length-navigator.guidanceProgress) }
    private var turnDistance: String {
        if navigator.finished { return "已完成全程" }
        if navigator.readyToStartLoop { return "已到达入口" }
        if navigator.isApproaching && navigator.approachPoints.isEmpty { return "前往环线入口" }
        if !navigator.onRoute { return "等待进入路线" }
        return navigationDistance(max(0, (next?.meters ?? navigator.guidanceCourse.length)-navigator.guidanceProgress))
    }
    var body: some View {
        ZStack(alignment: .top) {
                RoadbookMapView(points: navigator.course.points, waypoints: navigator.session?.book.waypoints ?? [],
                    position: navigator.position, heading: navigator.heading, overview: overview, showPoints: showPoints,
                    nextTurn: next.map { navigator.guidanceCourse.point(at: $0.meters) }, entryPoint: navigator.entryPoint,
                    approachPoints: navigator.approachPoints,
                    coveredSegments: navigator.journey.coveredSegments(on: navigator.course),
                    actualSegments: navigator.journey.traceSegments, recenterRequest: recenter, zoomRequest: zoom,
                    positionFraction: 0.66, bottomOverlayInset: navigator.readyToStartLoop ? 155 : 100, onInteraction: { browsing = true })
                    .ignoresSafeArea()
                VStack(spacing: 14) {
                    instructionCard
                    HStack(alignment: .top) {
                        if navigator.isPreview {
                            Label("路线预览", systemImage: "play.circle").font(.caption.weight(.semibold))
                                .padding(12).modifier(NavigationGlass())
                        }
                        Spacer()
                        mapControls
                    }
                    Spacer(minLength: 0)
                    footer
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        }
        .confirmationDialog("结束本次导航？", isPresented: $ending, titleVisibility: .visible) {
            Button("结束导航", role: .destructive) { navigator.end() }
        }
        .sheet(isPresented: $voiceSettings) { RoadbookVoiceView(navigator: navigator) }
        .sheet(isPresented: $showInformation) { informationSheet }
    }
    private var instructionCard: some View {
        HStack(spacing: 18) {
            Image(systemName: navigator.finished ? "checkmark.circle.fill" : navigator.isApproaching && !navigator.onRoute ? "flag.checkered" : (next?.symbol ?? "arrow.up"))
                .font(.system(size: 34, weight: .medium)).foregroundStyle(.mint).frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(turnDistance).font(.system(size: 30, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text(navigator.readyToStartLoop ? "点下方按钮，开始这一圈" : navigator.onRoute ? (next?.instruction ?? (navigator.isApproaching ? "前往所选入口" : "沿路线到达终点")) : navigator.status)
                    .font(.subheadline.weight(.medium)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).modifier(NavigationGlass(clear: true))
    }
    private var mapControls: some View {
        VStack(spacing: 10) {
            Button {
                if browsing || overview { overview = false; navigator.refreshLocation() } else { overview = true }
                browsing = false; recenter += 1
            } label: { Label(browsing || overview ? "跟随" : "全程", systemImage: browsing || overview ? "location.north.fill" : "map").frame(minHeight: 28) }
                .buttonStyle(.glass)
            Button { showPoints.toggle() } label: { Label("点位", systemImage: showPoints ? "circle.grid.3x3.fill" : "circle.grid.3x3").frame(minHeight: 28) }
                .buttonStyle(.glass)
            VStack(spacing: 0) {
                Button { zoom += 1 } label: { Image(systemName: "plus").frame(width: 48, height: 48) }.accessibilityLabel("放大地图")
                Divider().frame(width: 26)
                Button { zoom -= 1 } label: { Image(systemName: "minus").frame(width: 48, height: 48) }.accessibilityLabel("缩小地图")
            }.buttonStyle(.plain).modifier(NavigationGlass())
        }
    }
    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(spacing: 4) {
                    floatingButton("导航说明", symbol: "exclamationmark") { showInformation = true }
                    floatingButton("导航语音", symbol: navigator.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { voiceSettings = true }
                    if navigator.isApproaching && !navigator.readyToStartLoop {
                        floatingButton(navigator.isPlanningApproach ? "规划中" : "重新规划", symbol: "arrow.clockwise") { navigator.planApproach() }
                            .disabled(navigator.isPlanningApproach || navigator.position == nil)
                    }
                }
                Spacer(minLength: 0)
            }
            if navigator.readyToStartLoop {
                Button { navigator.confirmLoopStart(); overview = false; browsing = false; recenter += 1 } label: {
                    Label("确认开始环线", systemImage: "play.fill").frame(maxWidth: .infinity).frame(minHeight: 44)
                }.buttonStyle(.glassProminent)
            } else if navigator.isApproaching, let distance = navigator.entryDistance, distance <= 35 {
                Button { navigator.refreshLocation() } label: {
                    Label("刷新定位，确认到达", systemImage: "location.circle").frame(minHeight: 44)
                }.buttonStyle(.glass)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(navigator.isApproaching ? (navigator.entryDistance == nil ? "入口距离待定位" : "入口\(navigator.approachPoints.isEmpty ? "直线" : "剩余") \(navigationDistance(navigator.approachPoints.isEmpty ? navigator.entryDistance ?? 0 : remaining))") : "剩余 \(navigationDistance(remaining))")
                        .font(.subheadline.bold())
                    Text(navigator.remainingTimeText)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    if navigator.finished { navigator.end() } else { ending = true }
                } label: {
                    Image(systemName: navigator.finished ? "checkmark" : "stop.fill")
                        .font(.system(size: 17, weight: .semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.glassProminent).tint(.red).buttonBorderShape(.circle)
                .accessibilityLabel(navigator.finished ? "完成导航" : "结束导航")
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .modifier(NavigationGlass(clear: true))
        }
    }
    private func floatingButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 32, height: 32)
        }
        .buttonStyle(.glass).controlSize(.small).buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44).accessibilityLabel(title)
    }
    private var informationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(navigator.status).font(.headline)
                    if navigator.isApproaching {
                        Text(navigator.approachMessage)
                        Label("绿色路线前往入口，蓝色为完整环线", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    if !navigator.isPreview {
                        Label("未走路书", systemImage: "line.diagonal").foregroundStyle(.blue)
                        Label("已走路段", systemImage: "line.diagonal").foregroundStyle(.gray)
                        Label("本次轨迹", systemImage: "line.diagonal").foregroundStyle(.orange)
                        Text(navigator.recordingText).foregroundStyle(.secondary)
                    }
                    if navigator.onRoute && !navigator.finished && !navigator.readyToStartLoop {
                        ForEach(Array(navigator.upcoming.dropFirst())) { turn in
                            Label("\(navigationDistance(max(0, turn.meters-navigator.guidanceProgress))) · \(turn.instruction)", systemImage: turn.symbol)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .navigationTitle("导航说明").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showInformation = false } } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
