import Foundation
import SwiftUI

/// Photo processing preferences: apply the creative look the photo was shot with.
struct PhotoLookSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("对 RAW 自动加载创意外观",isOn: Bindable(model).applyCreativeLook)
        } header: {
            Text("创意外观")
        }
    }
}
