import SwiftUI

@main
struct ClaudeUsageApp: App {
    @State private var viewModel = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(viewModel)
        } label: {
            Text(viewModel.statusDot + " " + viewModel.menuBarTitle)
                .font(.system(size: 13, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
