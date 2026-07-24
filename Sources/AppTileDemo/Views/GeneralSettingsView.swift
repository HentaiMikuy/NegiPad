import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: LauncherSettings
    @EnvironmentObject private var library: AppLibrary
    @State private var isConfirmingUsageReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("通用")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("应用的基础行为设置。")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $settings.launchAtLogin) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("开机自启")
                                    .font(.headline)
                                Text("登录 macOS 后自动启动 AppTileDemo。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        if let error = settings.launchAtLoginError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("搜索使用记录")
                                .font(.headline)
                            Text("启动器会记住每个应用的打开次数与最近使用时间，用于优化搜索结果排序。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button("清除记录", role: .destructive) {
                            isConfirmingUsageReset = true
                        }
                    }
                    .padding(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
        .confirmationDialog(
            "清除搜索使用记录？",
            isPresented: $isConfirmingUsageReset,
            titleVisibility: .visible
        ) {
            Button("清除记录", role: .destructive) {
                library.clearUsageHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有应用的打开次数和最近使用时间将被重置，搜索排序会回到默认状态。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
