import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading) {
            Text("MediaKeyHub")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
    }
}
