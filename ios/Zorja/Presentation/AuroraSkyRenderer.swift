import Metal
import MetalKit
import SwiftUI

/// Which shader draws the sky. `classic` is the port of the Figma shader fill
/// (`AuroraSky.metal`, also kept in the git tag `aurora-classic-v1`); `photo` is the look
/// modelled on long-exposure aurora photographs (`AuroraSkyPhoto.metal`).
enum AuroraSkyStyle: String, CaseIterable, Identifiable, Sendable {
    case classic
    case photo

    /// UserDefaults key the developer menu writes; `-skyStyle classic` at launch also works.
    static let defaultsKey = "skyStyle"
    static let appDefault = AuroraSkyStyle.photo

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic (Figma)"
        case .photo: "Photo"
        }
    }
}

/// The shader values of a Figma "Zorja Aurora Sky" layer. Defaults are the ones on
/// every sky layer in the Figma file.
struct AuroraSkyParameters: Equatable, Sendable {
    var intensity: Float = 0.85
    var cloudCover: Float = 0
    /// Horizon as a fraction of the height, from the top (Figma: 84 %).
    var horizon: Float = 0.84
    var seed: Float = 4
    var curtainHeight: Float = 1
    var starBrightness: Float = 0.3
    /// Shader seconds per real second. Figma's layers say 0.3, at which the curtains looked
    /// still on a phone; the app runs at 1 (docs/decisions.md).
    var speed: Double = 1
    /// App only: how fast rays slide along the curtain, in ray noise units per shader second
    /// (0.5 ≈ 15 pt a second on the main curtain). 0 in Figma.
    var rayDrift: Float = 0.5
    /// App only: depth of the brightness pulse that travels along the curtains. 0 in Figma.
    var shimmer: Float = 0.35
    var style = AuroraSkyStyle.appDefault

    /// The Figma layer values, without the app's motion terms.
    static let figma = AuroraSkyParameters(speed: 0.3, rayDrift: 0, shimmer: 0, style: .classic)
}

/// Draws the sky in two passes, column terms then pixels, with the shader of the style:
/// `AuroraSky.metal` or `AuroraSkyPhoto.metal`.
final class AuroraSkyRenderer {
    /// Matches `SkyUniforms` in `AuroraSky.metal`.
    struct Uniforms {
        var size: SIMD2<Float>
        var time: Float
        var pixelScale: Float
        var intensity: Float
        var cloudCover: Float
        var horizon: Float
        var seed: Float
        var curtainHeight: Float
        var starBrightness: Float
        var rayDrift: Float
        var shimmer: Float

        init(pixelSize: SIMD2<Int>, pixelScale: Float, time: Float, parameters: AuroraSkyParameters) {
            size = SIMD2<Float>(pixelSize) / pixelScale
            self.time = time
            self.pixelScale = pixelScale
            intensity = parameters.intensity
            cloudCover = parameters.cloudCover
            horizon = parameters.horizon
            seed = parameters.seed
            curtainHeight = parameters.curtainHeight
            starBrightness = parameters.starBrightness
            rayDrift = parameters.rayDrift
            shimmer = parameters.shimmer
        }
    }

    /// Written as is: the shader's values are sRGB-encoded, as in Figma.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// The pipelines of one style.
    private struct Pipelines {
        let columns: any MTLComputePipelineState
        let sky: any MTLRenderPipelineState
        let reference: any MTLRenderPipelineState
        /// Size of one column in the column buffer.
        let columnStride: Int
    }

    /// Size of one classic `SkyColumn`: two curtains × five floats.
    static let columnStride = 10 * MemoryLayout<Float>.stride
    /// Size of one photo `SkyColumn`: three curtains × four floats.
    static let photoColumnStride = 12 * MemoryLayout<Float>.stride

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let classic: Pipelines
    private let photo: Pipelines
    private var columns: (any MTLBuffer)?

    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: AuroraSkyRenderer.self)),
              let classic = Self.pipelines(device, library, prefix: "sky", columnStride: Self.columnStride),
              let photo = Self.pipelines(device, library, prefix: "skyPhoto", columnStride: Self.photoColumnStride)
        else { return nil }
        self.device = device
        self.queue = queue
        self.classic = classic
        self.photo = photo
    }

    private static func pipelines(_ device: any MTLDevice, _ library: any MTLLibrary, prefix: String, columnStride: Int) -> Pipelines? {
        guard let function = library.makeFunction(name: prefix + "Columns"),
              let columns = try? device.makeComputePipelineState(function: function),
              let sky = renderPipeline(device, library, fragment: prefix + "Fragment"),
              let reference = renderPipeline(device, library, fragment: prefix + "ReferenceFragment")
        else { return nil }
        return Pipelines(columns: columns, sky: sky, reference: reference, columnStride: columnStride)
    }

    private static func renderPipeline(_ device: any MTLDevice, _ library: any MTLLibrary, fragment: String) -> (any MTLRenderPipelineState)? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "skyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Encodes one frame into `pass`, whose target is `pixelSize` pixels.
    /// `reference` draws every term per pixel (for classic, as the Figma shader does).
    func encode(
        into commandBuffer: any MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        pixelSize: SIMD2<Int>,
        pixelScale: Float,
        time: Float,
        parameters: AuroraSkyParameters,
        reference: Bool = false
    ) {
        guard pixelSize.x > 0, pixelSize.y > 0, pixelScale > 0 else { return }
        var uniforms = Uniforms(pixelSize: pixelSize, pixelScale: pixelScale, time: time, parameters: parameters)
        let pipelines = parameters.style == .photo ? photo : classic
        let columnsPipeline = pipelines.columns

        if !reference {
            let length = pixelSize.x * pipelines.columnStride
            if (columns?.length ?? 0) < length {
                columns = device.makeBuffer(length: length, options: .storageModePrivate)
            }
            guard let columns, let compute = commandBuffer.makeComputeCommandEncoder() else { return }
            var count = UInt32(pixelSize.x)
            compute.setComputePipelineState(columnsPipeline)
            compute.setBuffer(columns, offset: 0, index: 0)
            compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            compute.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
            let width = min(columnsPipeline.maxTotalThreadsPerThreadgroup, 64)
            compute.dispatchThreads(
                MTLSize(width: pixelSize.x, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }

        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let render = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        render.setRenderPipelineState(reference ? pipelines.reference : pipelines.sky)
        render.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if !reference { render.setFragmentBuffer(columns, offset: 0, index: 1) }
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        render.endEncoding()
    }
}

/// The sky layer: an `MTKView` that draws at `SkyMotion.framesPerSecond` and holds a
/// still frame while paused.
struct AuroraSkyMetalView: UIViewRepresentable {
    var parameters: AuroraSkyParameters
    var isPaused: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.renderer?.device)
        view.colorPixelFormat = AuroraSkyRenderer.pixelFormat
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = Int(SkyMotion.framesPerSecond)
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.delegate = context.coordinator
        context.coordinator.parameters = parameters
        context.coordinator.setPaused(isPaused, view: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.parameters != parameters {
            coordinator.parameters = parameters
            view.setNeedsDisplay()
        }
        coordinator.setPaused(isPaused, view: view)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer = AuroraSkyRenderer()
        var parameters = AuroraSkyParameters()
        private var clock = SkyClock()
        private var paused: Bool?

        func setPaused(_ paused: Bool, view: MTKView) {
            guard paused != self.paused else { return }
            self.paused = paused
            clock.setRunning(!paused, at: .now)
            // While paused the view only draws when asked, so it keeps a still frame.
            view.isPaused = paused
            view.enableSetNeedsDisplay = paused
            if paused { view.setNeedsDisplay() }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let renderer,
                  view.bounds.width > 0,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = renderer.queue.makeCommandBuffer()
            else { return }
            let pixelSize = SIMD2(Int(view.drawableSize.width), Int(view.drawableSize.height))
            let time = Float(clock.elapsed(at: .now) * parameters.speed)
            renderer.encode(
                into: commandBuffer,
                pass: pass,
                pixelSize: pixelSize,
                pixelScale: Float(view.drawableSize.width / view.bounds.width),
                time: time,
                parameters: parameters)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
