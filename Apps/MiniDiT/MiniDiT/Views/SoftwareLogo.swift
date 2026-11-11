import SwiftUI

enum SoftwareLogoKind {
    case captureOne, lightroomClassic

    var assetName: String {
        switch self {
        case .captureOne: "CaptureOneMonochrome"
        case .lightroomClassic: "LightroomClassicMonochrome"
        }
    }
}

/// 从本机原软件图标提取的黑白模板，保留原始轮廓、字形和比例。
struct SoftwareLogo: View {
    let kind: SoftwareLogoKind
    var size: CGFloat = 32

    var body: some View {
        Image(kind.assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
