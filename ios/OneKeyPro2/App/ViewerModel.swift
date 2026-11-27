import RealityKit
import SwiftUI

/// UI state, bridged to the RealityKit stage.
@MainActor
final class ViewerModel: ObservableObject {
    @Published private(set) var color = ProductConfig.defaultColor
    @Published private(set) var feature: String?
    @Published private(set) var angle: String?
    @Published private(set) var progress: Float = 0
    @Published private(set) var status = "准备中"
    @Published private(set) var isReady = false
    @Published private(set) var hasInteracted = false
    @Published private(set) var errorMessage: String?
    @Published var autoRotate = false {
        didSet {
            stage?.autoRotate = autoRotate
            if autoRotate, feature != nil { selectFeature(nil, fly: false) }
        }
    }

    private(set) var stage: ProductStage?

    var activeFeature: Feature? { feature.flatMap { id in ProductConfig.features.first { $0.id == id } } }
    var swatch: Swatch { ProductConfig.swatches.first { $0.id == color } ?? ProductConfig.swatches[0] }

    func attach(_ arView: ARView, compact: Bool) {
        guard stage == nil else { return }
        // Launch arguments (also handy for testing): -color Black -feature g3-curve -angle left
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "color"), ProductConfig.swatches.contains(where: { $0.id == id }) {
            color = id
        }
        do {
            let stage = try ProductStage(arView: arView, color: color)
            stage.setLayout(compact: compact)
            stage.onAngleChange = { [weak self] label in self?.angle = label }
            stage.onGrab = { [weak self] in
                guard let self else { return }
                self.hasInteracted = true
                if self.feature != nil { self.selectFeature(nil, fly: false) }
            }
            self.stage = stage
            Task {
                do {
                    try await stage.load { [weak self] value, message in
                        self?.progress = value
                        self?.status = message
                    }
                    self.isReady = true
                    print("[Viewer] ready")
                    try? await Task.sleep(for: .milliseconds(400))
                    stage.startIntro()
                    await self.runLaunchActions(stage)
                } catch {
                    self.errorMessage = "加载失败：\(error.localizedDescription)"
                }
            }
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    private func runLaunchActions(_ stage: ProductStage) async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "envDebug") {
            await stage.showEnvironmentDebug()
            stage.fly(to: "back")
        }
        if let feature = defaults.string(forKey: "feature"), ProductConfig.features.contains(where: { $0.id == feature }) {
            try? await Task.sleep(for: .seconds(1.5))
            selectFeature(feature)
        }
        if defaults.float(forKey: "zoom") > 0 {
            stage.setZoom(defaults.float(forKey: "zoom"))
        }
        if let angle = defaults.string(forKey: "angle") {
            try? await Task.sleep(for: .seconds(1.5))
            stage.fly(to: angle)
        }
        try? await Task.sleep(for: .seconds(4))
        print("[Viewer] settled")
    }

    func selectColor(_ id: String) {
        color = id
        stage?.setColor(id)
    }

    /// Tapping the active feature again returns to the overview.
    func toggleFeature(_ id: String) {
        selectFeature(feature == id ? nil : id)
    }

    func selectFeature(_ id: String?, fly: Bool = true) {
        feature = id
        hasInteracted = true
        if id != nil, autoRotate { autoRotate = false }
        stage?.setFeature(id, fly: fly)
    }

    func setLayout(compact: Bool) {
        stage?.setLayout(compact: compact)
    }

    func setBand(top: CGFloat, bottom: CGFloat) {
        stage?.setBand(top: top, bottom: bottom)
    }

    func snapshot(_ completion: @escaping (UIImage?) -> Void) {
        guard let stage else { return completion(nil) }
        stage.snapshot(completion)
    }
}
