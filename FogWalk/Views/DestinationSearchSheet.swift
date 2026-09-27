import SwiftUI

struct DestinationSearchSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var submittedQuery = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider().opacity(0.45)
                results
            }
            .navigationTitle("搜索明确地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            query = model.homeDestination?.title ?? ""
            isSearchFocused = true
        }
        .onDisappear { model.cancelPlaceSearch() }
        .onChange(of: query) { _, newValue in
            if newValue != submittedQuery { model.cancelPlaceSearch(clearResults: true) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(isSearchFocused ? .orange : .secondary)
                TextField("例如：世纪公园、人民广场", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFocused)
                    .onSubmit(performSearch)
                if !query.isEmpty {
                    Button {
                        query = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSearchFocused ? Color.orange : Color.secondary.opacity(0.25), lineWidth: isSearchFocused ? 2 : 1)
            }
            Button(action: performSearch) {
                if model.isSearchingPlaces {
                    ProgressView().tint(.white).frame(width: 44, height: 44)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.body.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(MapSearchButtonStyle())
            .background(.orange, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSearchingPlaces)
            .accessibilityLabel("搜索地点")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var results: some View {
        if model.isSearchingPlaces {
            VStack(spacing: 14) {
                ProgressView().tint(.orange)
                Text("正在搜索真实地点…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.placeSearchMessage {
            ContentUnavailableView(
                "没有可用结果",
                systemImage: "magnifyingglass",
                description: Text(message)
            )
        } else if model.placeSearchResults.isEmpty {
            ContentUnavailableView(
                "输入你的目的地",
                systemImage: "mappin.and.ellipse",
                description: Text("这是明确地点搜索，不会生成随机探索推荐。可输入地点名，也可补充城市或区县。")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.placeSearchResults) { result in
                        Button {
                            model.selectHomeDestination(result)
                            dismiss()
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(PlaceResultButtonStyle())
                        Divider().padding(.leading, 54)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private func resultRow(_ result: PlaceSearchResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(result.addressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let distance = result.distanceText(from: model.activeCoordinate) {
                    Text(distance)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.cyan)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func performSearch() {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        submittedQuery = normalized
        isSearchFocused = false
        model.searchPlaces(normalized)
    }
}

private struct MapSearchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PlaceResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.08) : .clear)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
