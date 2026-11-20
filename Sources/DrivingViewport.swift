import AppKit
import MetalKit
import SceneKit

/// SceneKit renders on its own display link in the high refresh mode. The
/// 60 FPS mode submits the same scene explicitly through a Metal drawable.
final class DrivingViewport: NSView {
    private let native: SCNView
    private var capped: CappedSceneRenderer?
    private var pendingFrame = true
    private var nextFrame = 0.0
    private var cappedActive: Bool { capped?.view.superview === self }

    override init(frame: CGRect) {
        native = SCNView(frame: CGRect(origin:.zero,size:frame.size),
                         options:[SCNView.Option.preferredRenderingAPI.rawValue:SCNRenderingAPI.metal.rawValue])
        super.init(frame:frame)
        native.autoresizingMask = [.width,.height]
        native.backgroundColor = NSColor(rgb:0xB8CED8)
        addSubview(native)
    }

    required init?(coder: NSCoder) { nil }

    var scene: SCNScene? {
        get { native.scene }
        set {
            native.scene = newValue
            capped?.renderer.scene = newValue
            requestFrame()
        }
    }

    var pointOfView: SCNNode? {
        get { native.pointOfView }
        set {
            native.pointOfView = newValue
            capped?.renderer.pointOfView = newValue
            requestFrame()
        }
    }

    var device: MTLDevice? { native.device }
    weak var delegate: SCNSceneRendererDelegate? { didSet { updateDelegate() } }
    var showsStatistics: Bool {
        get { native.showsStatistics }
        set { native.showsStatistics = newValue; capped?.renderer.showsStatistics = newValue; requestFrame() }
    }
    var onDrawablePresented: ((Double) -> Void)? {
        didSet { capped?.onPresented = onDrawablePresented }
    }

    var preferredFramesPerSecond = 120 {
        didSet {
            native.preferredFramesPerSecond = preferredFramesPerSecond
            if preferredFramesPerSecond == 60, capped == nil, let device = native.device ?? MTLCreateSystemDefaultDevice(),
               let new = CappedSceneRenderer(frame:bounds,device:device) {
                new.renderer.scene = native.scene
                new.renderer.pointOfView = native.pointOfView
                new.renderer.showsStatistics = native.showsStatistics
                new.onPresented = onDrawablePresented
                new.antialiasingMode = antialiasingMode
                capped = new
            }
            if preferredFramesPerSecond == 60, let capped, capped.view.superview == nil {
                native.removeFromSuperview()
                capped.view.frame = bounds
                addSubview(capped.view)
            } else if preferredFramesPerSecond != 60, native.superview == nil {
                capped?.view.removeFromSuperview()
                native.frame = bounds
                addSubview(native)
            }
            updateDelegate()
            updatePlayback()
            nextFrame = 0
            requestFrame()
        }
    }

    var antialiasingMode = SCNAntialiasingMode.multisampling4X {
        didSet {
            native.antialiasingMode = antialiasingMode
            capped?.antialiasingMode = antialiasingMode
            requestFrame()
        }
    }
    var isPlaying = false { didSet { updatePlayback() } }
    var rendersContinuously = false { didSet { updatePlayback() } }

    private func updatePlayback() {
        native.isPlaying = isPlaying && !cappedActive
        native.rendersContinuously = rendersContinuously && !cappedActive
        capped?.isPlaying = isPlaying && cappedActive
    }

    private func updateDelegate() {
        native.delegate = cappedActive ? nil : delegate
        capped?.renderer.delegate = cappedActive ? delegate : nil
    }

    func requestFrame() {
        if cappedActive { pendingFrame = true }
        else { native.needsDisplay = true }
    }

    func presentPendingFrame(at time: Double) {
        guard cappedActive, pendingFrame, let capped, window != nil,
              bounds.width > 0, bounds.height > 0, time+0.0004 >= nextFrame else { return }
        pendingFrame = false
        if time-nextFrame > 1/60 { nextFrame = time+1/60 }
        else { nextFrame += 1/60 }
        capped.requestedTime = time
        capped.view.draw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFrame()
    }

    override func layout() {
        super.layout()
        requestFrame()
    }

    func sceneHitTest(_ point: CGPoint, options: [SCNHitTestOption: Any]) -> [SCNHitTestResult] {
        if cappedActive { native.frame = bounds }
        return native.hitTest(point,options:options)
    }

    func snapshot() -> NSImage {
        let size = bounds.size
        guard size.width > 0, size.height > 0, let device = device ?? MTLCreateSystemDefaultDevice(),
              let scene, let pointOfView else { return native.snapshot() }
        let sceneTime = cappedActive ? (capped?.sceneTime ?? native.sceneTime) : native.sceneTime
        let backing = convertToBacking(bounds).size
        let width = Int(backing.width.rounded()), height = Int(backing.height.rounded())
        let image: NSImage? = autoreleasepool {
            // Own the capture targets and render at the window's actual pixel size.
            // The displayed renderer can then release its old scene independently.
            let sizes = (width:width,height:height)
            let samples = sampleCount(for:antialiasingMode,on:device)
            guard width > 0, height > 0,
                  let pass = makeCapturePass(device:device,size:sizes,samples:samples),
                  let command = device.makeCommandQueue()?.makeCommandBuffer() else { return nil }
            let capture = SCNRenderer(device:device,options:nil)
            capture.scene = scene
            capture.pointOfView = pointOfView
            capture.render(atTime:sceneTime,viewport:CGRect(x:0,y:0,width:width,height:height),
                           commandBuffer:command,passDescriptor:pass)
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed,
                  let texture = pass.colorAttachments[0].resolveTexture ?? pass.colorAttachments[0].texture,
                  let frame = sceneTextureImage(texture) else { return nil }
            return NSImage(cgImage:frame,size:size)
        }
        return image ?? native.snapshot()
    }
}

private func sampleCount(for mode: SCNAntialiasingMode,on device: MTLDevice?) -> Int {
    let samples = mode == .multisampling4X ? 4 : (mode == .multisampling2X ? 2 : 1)
    return device?.supportsTextureSampleCount(samples) == true ? samples : 1
}

private func makeCapturePass(device: MTLDevice,size: (width: Int,height: Int),
                             samples: Int) -> MTLRenderPassDescriptor? {
    let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:size.width,height:size.height,mipmapped:false)
    color.usage = .renderTarget
    color.storageMode = .shared
    guard let output = device.makeTexture(descriptor:color) else { return nil }

    let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:size.width,height:size.height,mipmapped:false)
    depth.usage = .renderTarget
    depth.storageMode = .private
    if samples > 1 {
        depth.textureType = .type2DMultisample
        depth.sampleCount = samples
    }
    guard let depthTarget = device.makeTexture(descriptor:depth) else { return nil }
    let pass = MTLRenderPassDescriptor()
    let attachment = pass.colorAttachments[0]!
    attachment.loadAction = .clear
    if samples > 1 {
        color.textureType = .type2DMultisample
        color.sampleCount = samples
        color.storageMode = .private
        guard let multisample = device.makeTexture(descriptor:color) else { return nil }
        attachment.texture = multisample
        attachment.resolveTexture = output
        attachment.storeAction = .multisampleResolve
    } else {
        attachment.texture = output
        attachment.storeAction = .store
    }
    pass.depthAttachment.texture = depthTarget
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    return pass
}

func sceneTextureImage(_ texture: MTLTexture) -> CGImage? {
    let width = texture.width, height = texture.height
    let stride = width * 4
    var pixels = Data(count:stride * height)
    pixels.withUnsafeMutableBytes { bytes in
        texture.getBytes(bytes.baseAddress!,bytesPerRow:stride,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
    }
    guard let provider = CGDataProvider(data:pixels as CFData),
          let space = CGColorSpace(name:CGColorSpace.sRGB) else { return nil }
    return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,
                   space:space,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue)],
                   provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
}

private final class CappedSceneRenderer: NSObject, MTKViewDelegate {
    let view: MTKView
    let renderer: SCNRenderer
    private let queue: MTLCommandQueue
    var onPresented: ((Double) -> Void)?
    var requestedTime: Double = 0
    private var lastFrame: Double?
    private(set) var sceneTime = 0.0
    var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            renderer.isPlaying = isPlaying
            lastFrame = nil
        }
    }
    var antialiasingMode: SCNAntialiasingMode = .none {
        didSet {
            view.sampleCount = sampleCount(for:antialiasingMode,on:view.device)
        }
    }

    init?(frame: CGRect,device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        renderer = SCNRenderer(device:device,options:nil)
        view = MTKView(frame:frame,device:device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red:0.72,green:0.81,blue:0.85,alpha:1)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoresizingMask = [.width,.height]
        view.delegate = self
    }

    func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
        if isPlaying, let lastFrame { sceneTime += clamp(requestedTime-lastFrame,0,0.1) }
        lastFrame = requestedTime
        renderer.render(atTime:sceneTime,viewport:CGRect(origin:.zero,size:view.drawableSize),
                        commandBuffer:command,passDescriptor:pass)
        if let onPresented {
            drawable.addPresentedHandler { onPresented($0.presentedTime) }
        }
        command.present(drawable)
        command.commit()
    }
}
