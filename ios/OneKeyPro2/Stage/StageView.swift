import RealityKit
import SwiftUI

/// Hosts the RealityKit view (non-AR) and turns touches into orbit / zoom.
struct StageView: UIViewRepresentable {
    @ObservedObject var model: ViewerModel
    var compact: Bool
    var background: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableCameraGrain,
            .disableGroundingShadows, .disableFaceMesh, .disablePersonOcclusion, .disableAREnvironmentLighting,
        ]
        arView.environment.background = .color(background)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        pan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        [pan, pinch, doubleTap].forEach(arView.addGestureRecognizer)

        model.attach(arView, compact: compact)
        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        model.stage?.setBackground(background)
        model.setLayout(compact: compact)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let model: ViewerModel
        private var pinchStartZoom: Float = 1

        init(model: ViewerModel) {
            self.model = model
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let stage = model.stage, model.isReady else { return }
            switch g.state {
            case .began:
                stage.beginDrag()
                g.setTranslation(.zero, in: g.view)
            case .changed:
                let t = g.translation(in: g.view)
                stage.drag(dx: Float(t.x), dy: Float(t.y))
                g.setTranslation(.zero, in: g.view)
            case .ended, .cancelled, .failed:
                stage.endDrag(velocity: g.state == .ended ? g.velocity(in: g.view) : .zero)
            default:
                break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let stage = model.stage, model.isReady else { return }
            if g.state == .began { pinchStartZoom = stage.zoomTarget }
            if g.state == .changed { stage.pinch(scale: Float(g.scale), startZoom: pinchStartZoom) }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            model.stage?.resetZoom()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
