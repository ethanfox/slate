import AppKit
import MetalKit
import QuartzCore
import SwiftUI

enum LiquidOrbSupport {
    static var isAvailable: Bool { sharedLibrary != nil }

    static let sharedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    static let sharedLibrary: MTLLibrary? = {
        guard let device = sharedDevice else { return nil }
        do {
            return try device.makeLibrary(source: orbMetalHead + orbMetalTail, options: nil)
        } catch {
            print("LiquidOrb Metal compile failed: \(error)")
            return nil
        }
    }()
}

public struct LiquidOrbAudio: Sendable {
    public var low: Float
    public var mid: Float
    public var high: Float
    public var all: Float
    public init(low: Float = 0, mid: Float = 0, high: Float = 0, all: Float = 0) {
        self.low = low; self.mid = mid; self.high = high; self.all = all
    }
}

private func applyOrbAudio(_ values: inout [Float], _ bands: LiquidOrbAudio) {
    let strengths: [Int: Float] = [9: 0.8, 10: 0.65, 11: 0.65, 14: 0.75, 19: 1, 21: 0.7]
    guard let strength = strengths[Int(values[15].rounded())] else { return }
    func level(_ value: Float) -> Float { value.isFinite ? max(0, min(1, value)) * strength : 0 }
    if level(bands.all) > 0 { values[3] = min(max(5, values[3]), values[3] * (1 + 0.7 * level(bands.all)) + 0 * level(bands.all)) }
    if level(bands.mid) > 0 { values[6] = min(max(7, values[6]), values[6] * (1 + 0 * level(bands.mid)) + 0.85 * level(bands.mid)) }
    if level(bands.low) > 0 { values[21] = min(max(1, values[21]), values[21] * (1 + 0 * level(bands.low)) + 0.075 * level(bands.low)) }
    if level(bands.high) > 0 { values[10] = min(max(2, values[10]), values[10] * (1 + 0 * level(bands.high)) + 0.16 * level(bands.high)) }
    if level(bands.all) > 0 { values[14] = min(max(4, values[14]), values[14] * (1 + 0.12 * level(bands.all)) + 0 * level(bands.all)) }
}

public enum LiquidOrbState: Sendable {
    case idle
    case thinking
}

private func orbUniformSeed(for state: LiquidOrbState) -> [Float] {
    switch state {
    case .idle: orbIdleUniformSeed
    case .thinking: orbThinkingUniformSeed
    }
}

private func orbSrgbToLinear(_ value: Float) -> Float {
    value <= 0.04045
        ? value / 12.92
        : Float(pow(Double((value + 0.055) / 1.055), 2.4))
}

private func orbLinearToSrgb(_ value: Float) -> Float {
    value <= 0.0031308
        ? value * 12.92
        : 1.055 * Float(pow(Double(value), 1.0 / 2.4)) - 0.055
}

private func orbMixSrgb(_ from: Float, _ to: Float, _ progress: Float) -> Float {
    orbLinearToSrgb(
        orbSrgbToLinear(from) + (orbSrgbToLinear(to) - orbSrgbToLinear(from)) * progress
    )
}

private enum LiquidOrbError: Error {
    case metalUnavailable
    case shaderFunctionMissing(String)
    case commandQueueUnavailable
}

private let orbActivationDuration: CFTimeInterval = 0.25
private let orbSettleDuration: CFTimeInterval = 0.65
private let orbRibbonStyleIndex: Float = 24
private let orbRibbonInstanceCount = 221184

private final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let ribbonPipeline: MTLRenderPipelineState
    private let ribbonCompositePipeline: MTLRenderPipelineState
    private var ribbonTexture: MTLTexture?
    private var lastFrameAt = CACurrentMediaTime()
    private var motionPhase: CFTimeInterval = 0
    private var audio = LiquidOrbAudio()
    private var colorTint: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)?

    func setAudio(_ audio: LiquidOrbAudio) {
        stateLock.lock()
        self.audio = audio
        stateLock.unlock()
    }

    func setColorTint(_ tint: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)?) {
        stateLock.lock()
        colorTint = tint
        stateLock.unlock()
    }

    private let stateLock = NSLock()
    private var currentState: LiquidOrbState
    private var transitionTargetState: LiquidOrbState
    private var fromUniforms: [Float]
    private var targetUniforms: [Float]
    private var displayedUniforms: [Float]
    private var transitionStartedAt = CACurrentMediaTime()
    private var activeTransitionDuration: CFTimeInterval = 0

    init(view: MTKView, state: LiquidOrbState) throws {
        let initialUniforms = orbUniformSeed(for: state)
        currentState = state
        transitionTargetState = state
        fromUniforms = initialUniforms
        targetUniforms = initialUniforms
        displayedUniforms = initialUniforms

        guard let device = LiquidOrbSupport.sharedDevice else {
            throw LiquidOrbError.metalUnavailable
        }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        view.clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )

        guard let library = LiquidOrbSupport.sharedLibrary else {
            throw LiquidOrbError.metalUnavailable
        }
        guard let vertex = library.makeFunction(name: "vs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("vs_main")
        }
        guard let fragment = library.makeFunction(name: "fs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("fs_main")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let ribbonVertex = library.makeFunction(name: "ribbon_vs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("ribbon_vs_main")
        }
        guard let ribbonFragment = library.makeFunction(name: "ribbon_fs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("ribbon_fs_main")
        }
        let ribbonDescriptor = MTLRenderPipelineDescriptor()
        ribbonDescriptor.vertexFunction = ribbonVertex
        ribbonDescriptor.fragmentFunction = ribbonFragment
        ribbonDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        ribbonDescriptor.colorAttachments[0].isBlendingEnabled = true
        ribbonDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        ribbonDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        ribbonDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        ribbonDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        ribbonPipeline = try device.makeRenderPipelineState(descriptor: ribbonDescriptor)
        guard let ribbonCompositeFragment = library.makeFunction(
            name: "ribbon_composite_fs_main"
        ) else {
            throw LiquidOrbError.shaderFunctionMissing("ribbon_composite_fs_main")
        }
        let ribbonCompositeDescriptor = MTLRenderPipelineDescriptor()
        ribbonCompositeDescriptor.vertexFunction = vertex
        ribbonCompositeDescriptor.fragmentFunction = ribbonCompositeFragment
        ribbonCompositeDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        ribbonCompositeDescriptor.colorAttachments[0].isBlendingEnabled = true
        ribbonCompositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        ribbonCompositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        ribbonCompositeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        ribbonCompositeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        ribbonCompositePipeline = try device.makeRenderPipelineState(
            descriptor: ribbonCompositeDescriptor
        )
        guard let queue = device.makeCommandQueue() else {
            throw LiquidOrbError.commandQueueUnavailable
        }
        commandQueue = queue
        super.init()
    }

    func setState(_ state: LiquidOrbState) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state != currentState else { return }

        let nextUniforms = orbUniformSeed(for: state)
        fromUniforms = sampleTransition(at: now)
        targetUniforms = nextUniforms
        transitionTargetState = state
        transitionStartedAt = now
        activeTransitionDuration = state == .thinking
            ? orbActivationDuration
            : orbSettleDuration
        currentState = state
    }

    private func sampleTransition(at now: CFTimeInterval) -> [Float] {
        let rawProgress = activeTransitionDuration == 0
            ? 1
            : min(1, max(0, (now - transitionStartedAt) / activeTransitionDuration))
        let easedProgress = transitionTargetState == .thinking
            ? 1 - pow(1 - rawProgress, 3)
            : rawProgress * rawProgress * (3 - 2 * rawProgress)
        let progress = Float(easedProgress)

        for index in 3..<displayedUniforms.count {
            let isColorComponent = index >= 40
                && (index - 40) % 4 < 3
            displayedUniforms[index] = isColorComponent
                ? orbMixSrgb(fromUniforms[index], targetUniforms[index], progress)
                : fromUniforms[index] + (targetUniforms[index] - fromUniforms[index]) * progress
        }
        return displayedUniforms
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        ribbonTexture = nil
    }

    private func ensureRibbonTexture(for view: MTKView) -> MTLTexture? {
        let width = max(1, Int(view.drawableSize.width))
        let height = max(1, Int(view.drawableSize.height))
        if let ribbonTexture,
           ribbonTexture.width == width,
           ribbonTexture.height == height {
            return ribbonTexture
        }
        guard let device = view.device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: view.colorPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        ribbonTexture = device.makeTexture(descriptor: descriptor)
        return ribbonTexture
    }

    func draw(in view: MTKView) {
        guard
            view.drawableSize.width > 0,
            view.drawableSize.height > 0,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let now = CACurrentMediaTime()
        stateLock.lock()
        var uniforms = sampleTransition(at: now)
        applyOrbAudio(&uniforms, audio)
        if let tint = colorTint {
            func put(_ index: Int, _ color: SIMD4<Float>) {
                uniforms[index] = color.x
                uniforms[index + 1] = color.y
                uniforms[index + 2] = color.z
                uniforms[index + 3] = 1
            }
            put(40, tint.0)
            put(44, tint.1)
            put(48, tint.2)
            put(52, tint.3)
        }
        stateLock.unlock()
        let frameDelta = min(0.1, max(0, now - lastFrameAt))
        lastFrameAt = now
        motionPhase += frameDelta * CFTimeInterval(max(uniforms[3], 0))
        uniforms[0] = Float(view.drawableSize.width)
        uniforms[1] = Float(view.drawableSize.height)
        uniforms[2] = Float(motionPhase / CFTimeInterval(max(uniforms[3], 0.001)))
        let isParticleRibbon = round(uniforms[15]) == orbRibbonStyleIndex
        if isParticleRibbon {
            guard let ribbonTexture = ensureRibbonTexture(for: view) else { return }
            let ribbonPass = MTLRenderPassDescriptor()
            ribbonPass.colorAttachments[0].texture = ribbonTexture
            ribbonPass.colorAttachments[0].loadAction = .clear
            ribbonPass.colorAttachments[0].storeAction = .store
            ribbonPass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0
            )
            guard let ribbonEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: ribbonPass
            ) else { return }
            ribbonEncoder.setRenderPipelineState(ribbonPipeline)
            uniforms.withUnsafeBytes { bytes in
                ribbonEncoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                ribbonEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            ribbonEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: orbRibbonInstanceCount
            )
            ribbonEncoder.endEncoding()
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(isParticleRibbon ? ribbonCompositePipeline : pipeline)
        uniforms.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        if isParticleRibbon {
            encoder.setFragmentTexture(ribbonTexture, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private final class LiquidOrbCoordinator {
    private var renderer: LiquidOrbRenderer?

    func setAudio(_ audio: LiquidOrbAudio) { renderer?.setAudio(audio) }

    func setColorTint(_ tint: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)?) {
        renderer?.setColorTint(tint)
    }

    func makeView(state: LiquidOrbState) -> MTKView {
        let view = MTKView(frame: .zero, device: nil)
        do {
            let renderer = try LiquidOrbRenderer(view: view, state: state)
            self.renderer = renderer
            view.delegate = renderer
            return view
        } catch {
            print("Liquid Orb Metal initialization failed: \(error)")
            return view
        }
    }

    func setState(_ state: LiquidOrbState) {
        renderer?.setState(state)
    }
}

private struct LiquidOrbSurface: NSViewRepresentable {
    let state: LiquidOrbState
    var audio = LiquidOrbAudio()
    var colorTint: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)?

    func makeCoordinator() -> LiquidOrbCoordinator { LiquidOrbCoordinator() }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView(state: state) }
    func updateNSView(_ view: MTKView, context: Context) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if view.layer?.contentsScale != scale {
            view.layer?.contentsScale = scale
        }
        context.coordinator.setState(state)
        context.coordinator.setAudio(audio)
        context.coordinator.setColorTint(colorTint)
    }
}

public struct LiquidOrbView: View {
    private let state: LiquidOrbState
    private var audio = LiquidOrbAudio()
    private var colorTint: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)?

    public init(state: LiquidOrbState = .idle) {
        self.state = state
    }

    public init(state: LiquidOrbState = .idle, audio: LiquidOrbAudio) {
        self.state = state
        self.audio = audio
    }

    init(
        state: LiquidOrbState = .idle,
        audio: LiquidOrbAudio = LiquidOrbAudio(),
        colorTint: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)?
    ) {
        self.state = state
        self.audio = audio
        self.colorTint = colorTint
    }

    public var body: some View {
        LiquidOrbSurface(state: state, audio: audio, colorTint: colorTint)
    }
}

private let orbIdleUniformSeed: [Float] = [
    1, 1, 0, 0.8199999928474426, 0.699999988079071, 0.3312000036239624, 1.1959999799728394, 0.1932000070810318,
    2.200000047683716, 0.17000000178813934, 0, 0, 0.8399999737739563, 1, 1, 19,
    0.004999999888241291, 0, 0, 1, 0.5699999928474426, 0.029999999329447746, 2, 0.41999998688697815,
    0.7699999809265137, 0.23000000417232513, 65, 0, 0, 1, 0.2199999988079071, 0.25,
    0.7200000286102295, 5, 0.41999998688697815, 1.25, 0.550000011920929, 0.30000001192092896, 1.2000000476837158, 0.699999988079071,
    0.0313725508749485, 0.019607843831181526, 0.04313725605607033, 1, 0.18431372940540314, 0.3176470696926117, 0.4156862795352936, 1,
    0.27450981736183167, 0.40784314274787903, 0.5490196347236633, 1, 0.0313725508749485, 0.019607843831181526, 0.04313725605607033, 1,
    0.5411764979362488, 0.6274510025978088, 0.7098039388656616, 1, 1, 1, 1, 1,
    0.9372549057006836, 0.20392157137393951, 0.29019609093666077, 1, 0.5647059082984924, 0.23529411852359772, 0.29411765933036804, 1,
    1, 0.9450980424880981, 0.9803921580314636, 1, 0.9058823585510254, 0.8509804010391235, 1, 1,
    0.0784313753247261, 0.0784313753247261, 0.0784313753247261, 1, 0.42352941632270813, 0.24313725531101227, 0.4470588266849518, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]

private let orbThinkingUniformSeed: [Float] = [
    1, 1, 0, 3, 0.699999988079071, 0.6399999856948853, 1.9500000476837158, 0.5899999737739563,
    2.200000047683716, 0.07999999821186066, 0, 0, 0.8399999737739563, 1, 1.350000023841858, 19,
    0.004999999888241291, 0, 0, 1, 0.5699999928474426, 0, 2, 0.41999998688697815,
    0.7699999809265137, 0.23000000417232513, 65, 0, 0, 1, 0.2199999988079071, 0.25,
    0.7200000286102295, 5, 0.41999998688697815, 1.25, 0.550000011920929, 0.30000001192092896, 1.2000000476837158, 0.699999988079071,
    0, 0, 0, 1, 0.2235294133424759, 0.6509804129600525, 0.8352941274642944, 1,
    0.18431372940540314, 0.3960784375667572, 0.7137255072593689, 1, 0, 0, 0, 1,
    0.5960784554481506, 0.7098039388656616, 0.8235294222831726, 1, 1, 1, 1, 1,
    0.9372549057006836, 0.20392157137393951, 0.29019609093666077, 1, 0.5647059082984924, 0.23529411852359772, 0.29411765933036804, 1,
    1, 0.9450980424880981, 0.9803921580314636, 1, 0.9058823585510254, 0.8509804010391235, 1, 1,
    0.0784313753247261, 0.0784313753247261, 0.0784313753247261, 1, 0.8078431487083435, 0.1725490242242813, 0.7960784435272217, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]
