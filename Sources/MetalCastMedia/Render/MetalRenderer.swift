import Foundation
import Metal
import MetalKit
import CoreVideo

public final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    // Atomic latest frame slot for zero-latency drop-frame rendering
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var renderedFrameCount = 0

    private static let embeddedShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RasterizerData {
        float4 position [[position]];
        float2 texCoords;
    };

    vertex RasterizerData vertexShader(uint vertexID [[vertex_id]]) {
        float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };

        float2 texCoords[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };

        RasterizerData out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.texCoords = texCoords[vertexID];
        return out;
    }

    fragment float4 fragmentShader(
        RasterizerData in [[stage_in]],
        texture2d<float, access::sample> yTexture [[texture(0)]],
        texture2d<float, access::sample> uvTexture [[texture(1)]]
    ) {
        constexpr sampler textureSampler (mag_filter::linear, min_filter::linear);
        float y = yTexture.sample(textureSampler, in.texCoords).r;
        float2 uv = uvTexture.sample(textureSampler, in.texCoords).rg - float2(0.5, 0.5);

        float3 rgb;
        rgb.r = y + 1.5748 * uv.y;
        rgb.g = y - 0.1873 * uv.x - 0.4681 * uv.y;
        rgb.b = y + 1.8556 * uv.x;
        return float4(rgb, 1.0);
    }
    """

    public init?(metalView: MTKView) {
        guard let defaultDevice = MTLCreateSystemDefaultDevice(),
              let queue = defaultDevice.makeCommandQueue() else {
            return nil
        }

        self.device = defaultDevice
        self.commandQueue = queue

        // Setup Texture Cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, defaultDevice, nil, &cache)
        self.textureCache = cache

        // Setup Pipeline State with multi-tier fallback
        var loadedLib: MTLLibrary?
        if let defaultLib = defaultDevice.makeDefaultLibrary(),
           defaultLib.makeFunction(name: "vertexShader") != nil {
            loadedLib = defaultLib
        } else if let bundleLib = try? defaultDevice.makeDefaultLibrary(bundle: Bundle.module),
                  bundleLib.makeFunction(name: "vertexShader") != nil {
            loadedLib = bundleLib
        } else {
            loadedLib = try? defaultDevice.makeLibrary(source: MetalRenderer.embeddedShaderSource, options: nil)
        }

        guard let library = loadedLib,
              let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            print("❌ [MetalRenderer] 无法加载或编译 Metal 着色器")
            return nil
        }

        do {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

            self.pipelineState = try defaultDevice.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[MetalRenderer] Pipeline creation failed: \(error)")
            return nil
        }

        super.init()
        metalView.device = defaultDevice
        metalView.delegate = self
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = true
    }

    /// Enqueues the latest decoded frame; overwrites older unrendered frames instantly
    public func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestPixelBuffer = pixelBuffer
        renderedFrameCount += 1
        let count = renderedFrameCount
        lock.unlock()

        if count == 1 || count % 60 == 0 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            print("🎨 [MetalRenderer] 收到第 \(count) 帧视频画面数据 (\(w)x\(h))")
        }
    }

    /// Access the latest uncompressed raw frame for lossless high-resolution screenshot
    public func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestPixelBuffer
    }

    public func draw(in view: MTKView) {
        lock.lock()
        guard let pixelBuffer = latestPixelBuffer else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let textureCache = textureCache,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Map Plane 0 (Y)
        var yTextureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,
            &yTextureRef
        )

        // Map Plane 1 (UV)
        var uvTextureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            width / 2,
            height / 2,
            1,
            &uvTextureRef
        )

        guard let yTex = yTextureRef.flatMap(CVMetalTextureGetTexture),
              let uvTex = uvTextureRef.flatMap(CVMetalTextureGetTexture) else {
            encoder.endEncoding()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
