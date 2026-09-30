import SwiftUI

/// 服务未启动时的统一引导界面
struct ServiceDownView: View {
    @EnvironmentObject var store: AppStore
    var title: String = "容器服务未启动"

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "power")
        } description: {
            Text("Apple container 的后台服务当前没有运行。\n启动后才能查看和管理容器，服务会在后台保持运行。")
        } actions: {
            Button {
                store.startSystem()
            } label: {
                Label("启动服务", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isBusy)

            if store.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在启动服务…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
    }
}
