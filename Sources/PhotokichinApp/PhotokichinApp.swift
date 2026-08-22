import SwiftUI
import PhotokichinInfrastructure
import PhotokichinPresentation

@main
struct PhotokichinApp: App {
    @State private var model: AppModel
    @State private var viewerWindowManager: ViewerWindowManager

    init() {
        let dependencies = InfrastructureFactory.makeAppDependencies()
        _model = State(initialValue: AppModel(dependencies: dependencies))
        _viewerWindowManager = State(initialValue: ViewerWindowManager())
    }

    var body: some Scene {
        WindowGroup("Photokichin") {
            ContentView(model: model, viewerWindowManager: viewerWindowManager)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("サムネイルを拡大") { model.adjustThumbnailSize(by: 24) }
                    .keyboardShortcut("+", modifiers: [.command])
                    .disabled(model.blocksPhotoListCommandShortcuts)
                Button("サムネイルを縮小") { model.adjustThumbnailSize(by: -24) }
                    .keyboardShortcut("-", modifiers: [.command])
                    .disabled(model.blocksPhotoListCommandShortcuts)
            }
            CommandGroup(after: .textEditing) {
                Button("選択を解除") { model.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.blocksPhotoListCommandShortcuts || model.selectedPhotoCount == 0)
            }
        }
    }
}
