import AppKit
import SonyRemoteKit
import SwiftUI

struct CredentialSheet: View {
    @Environment(AppModel.self) private var model
    let request: AppModel.CredentialRequest
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("访问身份验证").font(.title2.bold())
            Text("相机 \(request.host) 已开启“访问身份验证”。请在相机上依次打开 MENU → 网络 → 网络选项 → 访问身份验证信息，并输入其中显示的用户名和密码。账户信息仅保存在本机钥匙串中。")
                .fixedSize(horizontal: false, vertical: true)
            if let m = request.message {
                Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Form {
                TextField("用户名", text: $username).font(.body.monospaced())
                SecureField("密码", text: $password).font(.body.monospaced())
            }
            HStack {
                Spacer()
                Button("取消") { model.submitCredentials(nil) }.keyboardShortcut(.cancelAction)
                Button("连接") {
                    model.submitCredentials(SSHCredentials(username: username.trimmingCharacters(in: .whitespaces),
                                                           password: password.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { username = request.prefillUser ?? "" }
    }
}

struct FingerprintSheet: View {
    @Environment(AppModel.self) private var model
    let request: AppModel.FingerprintRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("核对相机指纹").font(.title2.bold())
            Text("首次连接此相机。请确认下方指纹与相机“访问身份验证信息”中显示的指纹一致，以免连接至冒充的设备。")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.key.sha256Base64).font(.body.monospaced()).textSelection(.enabled)
                    Text("\(request.key.keyType) · \(request.host)").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("其他格式") {
                        Text(request.key.sha256Hex).font(.caption.monospaced()).textSelection(.enabled)
                        Text(request.key.md5Hex).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            HStack {
                Spacer()
                Button("不一致，取消") { model.answerFingerprint(false) }.keyboardShortcut(.cancelAction)
                Button("一致，信任") { model.answerFingerprint(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
