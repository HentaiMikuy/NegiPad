import SwiftUI

struct ToolboxSettingsView: View {
    @EnvironmentObject private var toolboxSettings: ToolboxSettings

    private static let calculatorDescription = """
        在启动器搜索框中输入算式，例如 (12+8)*3 或 sqrt(2)，结果会实时显示在搜索框下方，\
        点击或按回车即可拷贝。支持 + - * / % ^、括号、常量 pi 和 e，\
        以及 sqrt、abs、sin、cos、tan、log、ln 函数。
        """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("小工具")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("在启动器搜索框中直接使用的轻量工具，可按需启用。")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    Toggle(isOn: $toolboxSettings.isCalculatorEnabled) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "equal.square.fill")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.tint)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("计算器")
                                    .font(.headline)
                                Text(Self.calculatorDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(8)
                }

                Label("更多小工具（取色器等）正在规划中。", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
