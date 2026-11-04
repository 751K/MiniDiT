import AppKit
import SonyRemoteKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var manualHost = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.on.rectangle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("从相机导入照片").font(.title.bold())
            Text("相机和这台 Mac 连到同一个 Wi-Fi，并在相机上打开「遥控拍摄」。")
                .foregroundStyle(.secondary)

            if model.phase == .searching || model.phase == .connecting || model.phase == .loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.status.isEmpty ? "请稍候…" : model.status).foregroundStyle(.secondary)
                    if model.phase != .loading { Button("取消") { model.cancelConnect() } }
                }
                .frame(height: 120)
            } else {
                Button { model.search() } label: {
                    Label("搜索相机", systemImage: "magnifyingglass").frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                if !model.found.isEmpty {
                    GroupBox("找到的相机") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.found) { cam in
                                HStack {
                                    Image(systemName: "camera")
                                    VStack(alignment: .leading) {
                                        Text(cam.knownName ?? "相机").bold()
                                        Text(cam.host + (cam.kind == .direct ? "（无访问身份验证）" : "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("连接") { model.connect(cam) }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxWidth: 420)
                } else if model.searched {
                    Text("没有找到相机。请确认相机已开机、连上了这个 Wi-Fi，并打开了「遥控拍摄」；也可以在下面直接输入相机的 IP。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }

                HStack {
                    TextField("相机 IP，例如 192.168.1.23", text: $manualHost)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit { model.connect(host: manualHost) }
                    Button("连接") { model.connect(host: manualHost) }.disabled(manualHost.isEmpty)
                }

                if !model.knownCameras.isEmpty {
                    Text("连过的相机：" + model.knownCameras.map { "\($0.name)（\($0.host)）" }.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
