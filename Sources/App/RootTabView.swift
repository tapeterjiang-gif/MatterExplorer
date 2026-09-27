import SwiftUI

/// App 根视图：三大模块 Tab 容器（配网以设备页右上角按钮的 sheet 形式进入）。
struct RootTabView: View {
    enum AppTab: Hashable {
        case devices
        case logs
        case settings
    }

    @State private var selection: AppTab = .devices

    var body: some View {
        TabView(selection: $selection) {
            Tab("设备", systemImage: "rectangle.grid.2x2", value: .devices) {
                DevicesView()
            }
            Tab("日志", systemImage: "terminal", value: .logs) {
                LogsView()
            }
            Tab("设置", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
    }
}

/// Tab 根页统一标题样式：小标题左对齐，与右侧工具栏按钮同一行。
extension View {
    /// `navigationTitle` 仍保留（供子页返回按钮使用），系统居中标题由空 principal 项抑制。
    func rootPageTitle(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(title)
                        .font(.headline)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
    }
}

/// 二级页面统一标题样式：inline 标题，并隐藏底部 Tab 栏。
/// 二级页面（设备详情、集群工具、设置下各子页等）不应再露出三个主 Tab。
extension View {
    func secondaryPageTitle(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .tabBar)
    }
}

#Preview {
    RootTabView()
}
