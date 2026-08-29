import SwiftUI

struct LauncherSettingsView: View {
    @EnvironmentObject private var settings: LauncherSettings
    @State private var pagingWheelBehaviorSelection: PagingWheelBehavior = .shiftModified

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("启动器")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("自定义启动器面板的尺寸，以及应用内容的浏览与翻页方式。")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("面板尺寸")
                            .font(.headline)

                        panelSizeSlider(
                            title: "宽度",
                            value: $settings.panelWidth,
                            range: LauncherSettings.panelWidthRange
                        )

                        panelSizeSlider(
                            title: "高度",
                            value: $settings.panelHeight,
                            range: LauncherSettings.panelHeightRange
                        )

                        HStack(alignment: .top) {
                            Text(panelSizeFootnote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer()

                            Button("恢复默认") {
                                settings.resetPanelSize()
                            }
                            .disabled(settings.isUsingDefaultPanelSize)
                            .help(
                                "恢复为 \(Int(LauncherSettings.defaultPanelWidth)) × \(Int(LauncherSettings.defaultPanelHeight))"
                            )
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(LauncherBrowsingMode.allCases.enumerated()), id: \.element.id) {
                            index, mode in
                            browsingModeRow(mode)

                            if index < LauncherBrowsingMode.allCases.count - 1 {
                                Divider()
                                    .padding(.leading, 52)
                            }
                        }
                    }
                    .padding(6)
                }

                if settings.browsingMode == .horizontalPaging {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("滚轮翻页方式")
                                .font(.headline)

                            Picker("滚轮翻页方式", selection: $pagingWheelBehaviorSelection) {
                                ForEach(PagingWheelBehavior.allCases) { behavior in
                                    Text(behavior.title)
                                        .tag(behavior)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            Text(pagingWheelBehaviorSelection.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("左右翻页说明", systemImage: "hand.draw")
                            .font(.headline)
                        Text("每页最多显示 \(pagedItemsPerPage) 个项目。还可以使用触控板横向滑动、底部翻页按钮，或通过方向键跨页浏览。页面采用懒加载和原生滚动对齐，以保持动画流畅。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.18), value: settings.browsingMode)
        .onAppear {
            pagingWheelBehaviorSelection = settings.pagingWheelBehavior
        }
        .onChange(of: pagingWheelBehaviorSelection) { _, newValue in
            guard newValue != settings.pagingWheelBehavior else { return }

            Task { @MainActor in
                // Let the Picker finish its own view update before publishing
                // the shared setting used by the launcher window.
                await Task.yield()
                guard pagingWheelBehaviorSelection == newValue else { return }
                settings.pagingWheelBehavior = newValue
            }
        }
        .onChange(of: settings.pagingWheelBehavior) { _, newValue in
            guard pagingWheelBehaviorSelection != newValue else { return }
            pagingWheelBehaviorSelection = newValue
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var panelColumnCount: Int {
        LauncherView.columnCount(forPanelWidth: settings.panelWidth)
    }

    private var panelRowCountPerPage: Int {
        LauncherView.rowCountPerPage(forPanelHeight: settings.panelHeight)
    }

    private var pagedItemsPerPage: Int {
        panelColumnCount * panelRowCountPerPage
    }

    private var panelSizeFootnote: String {
        var footnote = "当前 \(Int(settings.panelWidth)) × \(Int(settings.panelHeight))，每行显示 \(panelColumnCount) 个应用"
        if settings.browsingMode == .horizontalPaging {
            footnote += "，每页 \(panelRowCountPerPage) 行"
        }
        footnote += "。调整立即生效。"
        return footnote
    }

    private func panelSizeSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 34, alignment: .leading)

            Slider(value: value, in: range, step: 20)

            Text("\(Int(value.wrappedValue)) pt")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func browsingModeRow(_ mode: LauncherBrowsingMode) -> some View {
        Button {
            settings.browsingMode = mode
        } label: {
            HStack(spacing: 14) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(
                        settings.browsingMode == mode
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: settings.browsingMode == mode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        settings.browsingMode == mode
                            ? Color.accentColor
                            : Color.secondary.opacity(0.45)
                    )
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

}
