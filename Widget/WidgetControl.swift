import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action button: one tap starts SOS.
struct WidgetControl: ControlWidget {
    static let kind = "com.swastik.nobars.sos"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "nobars://sos")!)) {
                Label("Mesh SOS", systemImage: "location.fill")
            }
        }
        .displayName("Mesh SOS")
        .description("Opens NoBars and shares your live location with your group.")
    }
}
