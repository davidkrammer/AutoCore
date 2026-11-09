import AppKit
import AVFoundation
import SwiftUI

final class MirrorRenderSurface {
    private let displayViews = NSHashTable<MirrorSampleBufferView>.weakObjects()

    var aspectMode: ReceiverAspectMode = .fit {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let videoGravity: AVLayerVideoGravity = self.aspectMode == .fill ? .resizeAspectFill : .resizeAspect
                self.displayViews.allObjects.forEach { $0.videoGravity = videoGravity }
            }
        }
    }

    func attach(_ displayView: MirrorSampleBufferView) {
        displayViews.add(displayView)
        displayView.videoGravity = aspectMode == .fill ? .resizeAspectFill : .resizeAspect
    }

    func detach(_ displayView: MirrorSampleBufferView) {
        displayViews.remove(displayView)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async { [weak self] in
            self?.displayViews.allObjects.forEach { $0.enqueue(sampleBuffer) }
        }
    }

    func flush() {
        DispatchQueue.main.async { [weak self] in
            self?.displayViews.allObjects.forEach { $0.flush() }
        }
    }
}

final class MirrorSampleBufferView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    var videoGravity: AVLayerVideoGravity {
        get { displayLayer.videoGravity }
        set { displayLayer.videoGravity = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}

struct MirrorRenderView: NSViewRepresentable {
    let surface: MirrorRenderSurface
    let aspectMode: ReceiverAspectMode

    final class Coordinator {
        let surface: MirrorRenderSurface

        init(surface: MirrorRenderSurface) {
            self.surface = surface
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: surface)
    }

    func makeNSView(context: Context) -> MirrorSampleBufferView {
        let view = MirrorSampleBufferView(frame: .zero)
        surface.aspectMode = aspectMode
        surface.attach(view)
        return view
    }

    func updateNSView(_ nsView: MirrorSampleBufferView, context: Context) {
        surface.aspectMode = aspectMode
    }

    static func dismantleNSView(_ nsView: MirrorSampleBufferView, coordinator: Coordinator) {
        coordinator.surface.detach(nsView)
        nsView.flush()
    }
}
