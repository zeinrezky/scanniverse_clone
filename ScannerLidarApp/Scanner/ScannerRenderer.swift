//
//  ScannerRenderer.swift
//  ScannerLidarApp
//
//  Created by Juli Yanti on 12/04/24.
//

import Metal
import MetalKit
import ARKit
import Foundation
import UIKit

final class ScannerRenderer {
    // Whether recording is on
    public var isRecording = false;
    // Current folder for saving data
    public var currentFolder = ""
    // Pick every n frames (~1/sampling frequency)
    public var pickFrames = 50 // default to save 1/5 of the new frames
    public var currentFrameIndex = 0;
    // Task delegate for informing ViewController of tasks
    public weak var delegate: TaskDelegate?
    
    // Maximum number of points we store in the point cloud
    private let maxPoints = 3500_000
    // Number of sample points on the grid
    private let numGridPoints = 500
    // Particle's size in pixels
    private let particleSize: Float = 25
    // We only use landscape orientation in this app
    private let orientation = UIInterfaceOrientation.landscapeRight
    // Camera's threshold values for detecting when the camera moves so that we can accumulate the points
    private let cameraRotationThreshold = cos(2 * .degreesToRadian)
    private let cameraTranslationThreshold: Float = pow(0.02, 2)   // (meter-squared)
    // The max number of command buffers in flight
    private let maxInFlightBuffers = 3
    
    public var header: String = ""
    public var textureImage: UIImage?
    public var objURL: URL?
    public var picURL: URL?
    
    
    private lazy var rotateToARCamera = Self.makeRotateToARCameraMatrix(orientation: orientation)
    private let session: ARSession
    public var imagesAndAnchor = [UUID: UIImage]()
    
    public var testNode: [SCNNode] = []
    
    
    
    // Metal objects and textures
    private let device: MTLDevice
    private let library: MTLLibrary
    private let renderDestination: RenderDestinationProvider
    private let relaxedStencilState: MTLDepthStencilState
    private let depthStencilState: MTLDepthStencilState
    private let commandQueue: MTLCommandQueue
    private lazy var unprojectPipelineState = makeUnprojectionPipelineState()!
    private lazy var rgbPipelineState = makeRGBPipelineState()!
    private lazy var particlePipelineState = makeParticlePipelineState()!
    // texture cache for captured image
    private lazy var textureCache = makeTextureCache()
    private var capturedImageTextureY: CVMetalTexture?
    private var capturedImageTextureCbCr: CVMetalTexture?
    private var depthTexture: CVMetalTexture?
    private var confidenceTexture: CVMetalTexture?
    
    // Multi-buffer rendering pipeline
    private let inFlightSemaphore: DispatchSemaphore
    private var currentBufferIndex = 0
    
    // The current viewport size
    private var viewportSize = CGSize()
    // The grid of sample points
    private lazy var gridPointsBuffer = MetalBuffer<Float2>(device: device,
                                                            array: makeGridPoints(),
                                                            index: kGridPoints.rawValue, options: [])
    
    // RGB buffer
    private lazy var rgbUniforms: RGBUniforms = {
        var uniforms = RGBUniforms()
        uniforms.radius = rgbRadius
        uniforms.viewToCamera.copy(from: viewToCamera)
        uniforms.viewRatio = Float(viewportSize.width / viewportSize.height)
        return uniforms
    }()
    
    private var rgbUniformsBuffers = [MetalBuffer<RGBUniforms>]()
    // Point Cloud buffer
    // This is not the point cloud data, but some parameters
    
    private lazy var pointCloudUniforms: PointCloudUniforms = {
        var uniforms = PointCloudUniforms()
        uniforms.maxPoints = Int32(maxPoints)
        uniforms.confidenceThreshold = Int32(confidenceThreshold)
        uniforms.particleSize = particleSize
        uniforms.cameraResolution = cameraResolution
        return uniforms
    }()
    private var pointCloudUniformsBuffers = [MetalBuffer<PointCloudUniforms>]()
    // Particles buffer
    // Saves the point cloud data, filled by unprojectVertex func in Shaders.metal
    private var particlesBuffer: MetalBuffer<ParticleUniforms>
    private var currentPointIndex = 0
    private var currentPointCount = 0
    
    // Camera data
    private var sampleFrame: ARFrame { session.currentFrame! }
    private lazy var cameraResolution = Float2(Float(sampleFrame.camera.imageResolution.width), Float(sampleFrame.camera.imageResolution.height))
    private lazy var viewToCamera = sampleFrame.displayTransform(for: orientation, viewportSize: viewportSize).inverted()
    private lazy var lastCameraTransform = sampleFrame.camera.transform
    
    // interfaces
    var confidenceThreshold = 2 {
        didSet {
            // apply the change for the shader
            pointCloudUniforms.confidenceThreshold = Int32(confidenceThreshold)
        }
    }
    
    var rgbRadius: Float = 0 {
        didSet {
            // apply the change for the shader
            rgbUniforms.radius = rgbRadius
        }
    }
    
    init(session: ARSession, metalDevice device: MTLDevice, renderDestination: RenderDestinationProvider) {
        self.session = session
        self.device = device
        self.renderDestination = renderDestination
        
        library = device.makeDefaultLibrary()!
        commandQueue = device.makeCommandQueue()!
        
        // initialize our buffers
        for _ in 0 ..< maxInFlightBuffers {
            rgbUniformsBuffers.append(.init(device: device, count: 1, index: 0))
            pointCloudUniformsBuffers.append(.init(device: device, count: 1, index: kPointCloudUniforms.rawValue))
        }
        particlesBuffer = .init(device: device, count: maxPoints, index: kParticleUniforms.rawValue)
        
        // rbg does not need to read/write depth
        let relaxedStateDescriptor = MTLDepthStencilDescriptor()
        relaxedStencilState = device.makeDepthStencilState(descriptor: relaxedStateDescriptor)!
        
        // setup depth test for point cloud
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .lessEqual
        depthStateDescriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthStateDescriptor)!
        
        inFlightSemaphore = DispatchSemaphore(value: maxInFlightBuffers)
    }
    
    func drawRectResized(size: CGSize) {
        viewportSize = size
    }
    
    //create Image Texture
    private func updateCapturedImageTextures(frame: ARFrame) {
        // Create two textures (Y and CbCr) from the provided frame's captured image
        let pixelBuffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else {
            return
        }
        
        capturedImageTextureY = makeTexture(fromPixelBuffer: pixelBuffer, pixelFormat: .r8Unorm, planeIndex: 0)
        capturedImageTextureCbCr = makeTexture(fromPixelBuffer: pixelBuffer, pixelFormat: .rg8Unorm, planeIndex: 1)
    }
    
    private func updateDepthTextures(frame: ARFrame) -> Bool {
        guard let depthMap = frame.sceneDepth?.depthMap,
              let confidenceMap = frame.sceneDepth?.confidenceMap else {
            return false
        }
        
        depthTexture = makeTexture(fromPixelBuffer: depthMap, pixelFormat: .r32Float, planeIndex: 0)
        confidenceTexture = makeTexture(fromPixelBuffer: confidenceMap, pixelFormat: .r8Uint, planeIndex: 0)
        
        return true
    }
    
    private func update(frame: ARFrame) {
        // frame dependent info
        let camera = frame.camera
        let cameraIntrinsicsInversed = camera.intrinsics.inverse
        let viewMatrix = camera.viewMatrix(for: orientation)
        let viewMatrixInversed = viewMatrix.inverse
        let projectionMatrix = camera.projectionMatrix(for: orientation, viewportSize: viewportSize, zNear: 0.001, zFar: 0)
        pointCloudUniforms.viewProjectionMatrix = projectionMatrix * viewMatrix
        pointCloudUniforms.localToWorld = viewMatrixInversed * rotateToARCamera
        pointCloudUniforms.cameraIntrinsicsInversed = cameraIntrinsicsInversed
    }
    
    // MARK: DRAW METAL
    
    func drawPointCloud() {
        guard let currentFrame = session.currentFrame,
              let renderDescriptor = renderDestination.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDescriptor) else {
            return
        }
        
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            if let self = self {
                self.inFlightSemaphore.signal()
            }
        }
        
        // update frame data
        update(frame: currentFrame)
        updateCapturedImageTextures(frame: currentFrame)
        
        
        // handle buffer rotating
        currentBufferIndex = (currentBufferIndex + 1) % maxInFlightBuffers
        pointCloudUniformsBuffers[currentBufferIndex][0] = pointCloudUniforms
        
        if shouldAccumulate(frame: currentFrame), updateDepthTextures(frame: currentFrame) {
            accumulatePoints(frame: currentFrame, commandBuffer: commandBuffer, renderEncoder: renderEncoder)
            
            if (checkSamplingRate()) {
                // save selected data to disk if not dropped
                
                autoreleasepool {
                    // selected data are deep copied into custom struct to release currentFrame
                    // if not, the pools of memory reserved for ARFrame will be full and later frames will be dropped
                    let data = ARFrameDataPack(
                        timestamp: currentFrame.timestamp,
                        cameraTransform: currentFrame.camera.transform,
                        cameraEulerAngles: currentFrame.camera.eulerAngles,
                        depthMap: duplicatePixelBuffer(input: currentFrame.sceneDepth!.depthMap),
                        smoothedDepthMap: duplicatePixelBuffer(input: currentFrame.smoothedSceneDepth!.depthMap),
                        confidenceMap: duplicatePixelBuffer(input: currentFrame.sceneDepth!.confidenceMap!),
                        capturedImage: duplicatePixelBuffer(input: currentFrame.capturedImage),
                        localToWorld: pointCloudUniforms.localToWorld,
                        cameraIntrinsicsInversed: pointCloudUniforms.cameraIntrinsicsInversed
                    )
                    //saveData(frame: data)
                    
                }
            }
        }
        
        // check and render rgb camera image
        if rgbUniforms.radius > 0 {
            var retainingTextures = [capturedImageTextureY, capturedImageTextureCbCr]
            commandBuffer.addCompletedHandler { buffer in
                retainingTextures.removeAll()
            }
            rgbUniformsBuffers[currentBufferIndex][0] = rgbUniforms
            
            renderEncoder.setDepthStencilState(relaxedStencilState)
            renderEncoder.setRenderPipelineState(rgbPipelineState)
            renderEncoder.setVertexBuffer(rgbUniformsBuffers[currentBufferIndex])
            renderEncoder.setFragmentBuffer(rgbUniformsBuffers[currentBufferIndex])
            renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(capturedImageTextureY!), index: Int(kTextureY.rawValue))
            renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(capturedImageTextureCbCr!), index: Int(kTextureCbCr.rawValue))
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        
        // render particles
        renderEncoder.setDepthStencilState(depthStencilState)
        renderEncoder.setRenderPipelineState(particlePipelineState)
        renderEncoder.setVertexBuffer(pointCloudUniformsBuffers[currentBufferIndex])
        renderEncoder.setVertexBuffer(particlesBuffer)
        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: currentPointCount)
        renderEncoder.endEncoding()
        
        commandBuffer.present(renderDestination.currentDrawable!)
        commandBuffer.commit()
    }
    
    func draw(){
        drawPointCloud()
    }
    
    
    // custom struct for pulling necessary data from arframes
    struct ARFrameDataPack {
        var timestamp: Double
        var cameraTransform: simd_float4x4
        var cameraEulerAngles: simd_float3
        var depthMap: CVPixelBuffer
        var smoothedDepthMap: CVPixelBuffer
        var confidenceMap: CVPixelBuffer
        var capturedImage: CVPixelBuffer
        var localToWorld: simd_float4x4
        var cameraIntrinsicsInversed: simd_float3x3
    }
    
    /// Save data to disk in json and jpeg formats.
    private func saveData(frame: ARFrameDataPack) {
        struct DataPack: Codable {
            var timestamp: Double
            var cameraTransform: simd_float4x4 // The position and orientation of the camera in world coordinate space.
            var cameraEulerAngles: simd_float3 // The orientation of the camera, expressed as roll, pitch, and yaw values.
            var depthMap: [[Float32]]
            var smoothedDepthMap: [[Float32]]
            var confidenceMap: [[UInt8]]
            var localToWorld: simd_float4x4
            var cameraIntrinsicsInversed: simd_float3x3
        }
        
        delegate?.didStartTask()
        Task.init(priority: .utility) {
            do {
                let dataPack = await DataPack(
                    timestamp: frame.timestamp,
                    cameraTransform: frame.cameraTransform,
                    cameraEulerAngles: frame.cameraEulerAngles,
                    depthMap: cvPixelBuffer2Map(rawDepth: frame.depthMap),
                    smoothedDepthMap: cvPixelBuffer2Map(rawDepth: frame.smoothedDepthMap),
                    confidenceMap: cvPixelBuffer2Map(rawDepth: frame.confidenceMap),
                    localToWorld: frame.localToWorld,
                    cameraIntrinsicsInversed: frame.cameraIntrinsicsInversed
                )
                
                let jsonEncoder = JSONEncoder()
                jsonEncoder.outputFormatting = .prettyPrinted
                
                let encoded = try jsonEncoder.encode(dataPack)
                let encodedStr = String(data: encoded, encoding: .utf8)!
                try await saveFile(content: encodedStr, filename: "\(frame.timestamp)_\(pickFrames).json", folder: currentFolder + "/data")
                try await savePic(pic: cvPixelBuffer2UIImage(pixelBuffer: frame.capturedImage), filename: "\(frame.timestamp)_\(pickFrames).jpeg", folder: currentFolder + "/data")
                delegate?.didFinishTask()
            } catch {
                print(error.localizedDescription)
            }
        }
    }
    
    /// Save all particles to a point cloud file in ply format.
    func savePointCloud() {
        delegate?.didStartTask()
        Task.init(priority: .utility) {
            do {
                var fileToWrite = ""
                let headers = ["ply", "format ascii 1.0", "element vertex \(currentPointCount)", "property float x", "property float y", "property float z", "property uchar red", "property uchar green", "property uchar blue", "element face 0", "property list uchar int vertex_indices", "end_header"]
                for header in headers {
                    fileToWrite += header
                    fileToWrite += "\r\n"
                }
                
                for i in 0..<currentPointCount {
                    let point = particlesBuffer[i]
                    let colors = point.color
                    
                    let red = colors.x * 255.0
                    let green = colors.y * 255.0
                    let blue = colors.z * 255.0
                    
                    let pvValue = "\(point.position.x) \(point.position.y) \(point.position.z) \(Int(red)) \(Int(green)) \(Int(blue))"
                    fileToWrite += pvValue
                    fileToWrite += "\r\n"
                }
                
                try await saveFile(content: fileToWrite, filename: "\(getTimeStr()).ply", folder: currentFolder)
                
                delegate?.didFinishTask()
            } catch {
                print(error.localizedDescription)
            }
        }
    }
    
    private func shouldAccumulate(frame: ARFrame) -> Bool {
        if (!isRecording) {
            return false
        }
        let cameraTransform = frame.camera.transform
        return currentPointCount == 0
        || dot(cameraTransform.columns.2, lastCameraTransform.columns.2) <= cameraRotationThreshold
        || distance_squared(cameraTransform.columns.3, lastCameraTransform.columns.3) >= cameraTranslationThreshold
    }
    
    /// Check if the current frame should be saved or dropped based on sampling rate configuration
    private func checkSamplingRate() -> Bool {
        currentFrameIndex += 1
        return currentFrameIndex % pickFrames == 0
    }
    
    private func accumulatePoints(frame: ARFrame, commandBuffer: MTLCommandBuffer, renderEncoder: MTLRenderCommandEncoder) {
        pointCloudUniforms.pointCloudCurrentIndex = Int32(currentPointIndex)
        
        var retainingTextures = [capturedImageTextureY, capturedImageTextureCbCr, depthTexture, confidenceTexture]
        
        commandBuffer.addCompletedHandler { buffer in
            retainingTextures.removeAll()
        }
        
        renderEncoder.setDepthStencilState(relaxedStencilState)
        renderEncoder.setRenderPipelineState(unprojectPipelineState)
        renderEncoder.setVertexBuffer(pointCloudUniformsBuffers[currentBufferIndex])
        renderEncoder.setVertexBuffer(particlesBuffer)
        renderEncoder.setVertexBuffer(gridPointsBuffer)
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(capturedImageTextureY!), index: Int(kTextureY.rawValue))
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(capturedImageTextureCbCr!), index: Int(kTextureCbCr.rawValue))
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(depthTexture!), index: Int(kTextureDepth.rawValue))
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(confidenceTexture!), index: Int(kTextureConfidence.rawValue))
        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: gridPointsBuffer.count)
        
        currentPointIndex = (currentPointIndex + gridPointsBuffer.count) % maxPoints
        currentPointCount = min(currentPointCount + gridPointsBuffer.count, maxPoints)
        lastCameraTransform = frame.camera.transform
    }
    
    // MARK: Mesh Texturing
    

    
    // MARK: - OBJ & Texturing
    /*
    func generateAsset() ->MDLAsset {
        guard let frame = session.currentFrame else {
            fatalError("Couldn't get the current ARFrame")
        }
        
        // Fetch the default MTLDevice to initialize a MetalKit buffer allocator with
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Failed to get the system's default Metal device!")
        }
        
        // Using the Model I/O framework to export the scan, so we're initialising an MDLAsset object,
        // which we can export to a file later, with a buffer allocator
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(bufferAllocator: allocator)
        
        let meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
        
        for anchor in meshAnchors {
            // Some short handles, otherwise stuff will get pretty long in a few lines
            let anchorId = anchor.identifier
            guard let image = imagesAndAnchor[anchorId] else { fatalError("error no image") }
            
            let cgImage = image.cgImage
            let imageWidth = cgImage?.width
            let imageHeight = cgImage?.height
            let pixelData = cgImage?.dataProvider?.data
            let dataImage: Data = pixelData! as Data
            
            let bytesPerPixel = 4 // Assuming RGBA format
            let bytesPerRow = bytesPerPixel * imageWidth!
            
            
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            let verticesPointer = vertices.buffer.contents()
            let facesPointer = faces.buffer.contents()
            
            // Converting each vertex of the geometry from the local space of their ARMeshAnchor to world space
            for vertexIndex in 0..<vertices.count {
                
                // Extracting the current vertex with an extension method provided by Apple in Extensions.swift
                let vertex = geometry.vertex(at: UInt32(vertexIndex))
                
                // Building a transform matrix with only the vertex position
                // and apply the mesh anchors transform to convert into world space
                var vertexLocalTransform = matrix_identity_float4x4
                vertexLocalTransform.columns.3 = SIMD4<Float>(x: vertex.0, y: vertex.1, z: vertex.2, w: 1)
                let vertexWorldPosition = (anchor.transform * vertexLocalTransform).position
                
                // Writing the world space vertex back into it's position in the vertex buffer
                let vertexOffset = vertices.offset + vertices.stride * vertexIndex
                let componentStride = vertices.stride / 3
                verticesPointer.storeBytes(of: vertexWorldPosition.x, toByteOffset: vertexOffset, as: Float.self)
                verticesPointer.storeBytes(of: vertexWorldPosition.y, toByteOffset: vertexOffset + componentStride, as: Float.self)
                verticesPointer.storeBytes(of: vertexWorldPosition.z, toByteOffset: vertexOffset + (2 * componentStride), as: Float.self)
            }
            
            
            let vertexCount = geometry.vertices.count
            let uvCoordinates = (0..<vertexCount).map { _ in simd_float2(Float.random(in: 0..<1), Float.random(in: 0..<1))}
            
            
            // Initializing MDLMeshBuffers with the content of the vertex and face MTLBuffers
            let byteCountVertices = vertices.count * vertices.stride
            let byteCountFaces = faces.count * faces.indexCountPerPrimitive * faces.bytesPerIndex
            let vertexBuffer = allocator.newBuffer(with: Data(bytesNoCopy: verticesPointer, count: byteCountVertices, deallocator: .none), type: .vertex)
            let indexBuffer = allocator.newBuffer(with: Data(bytesNoCopy: facesPointer, count: byteCountFaces, deallocator: .none), type: .index)
            
            // Creating a MDLSubMesh with the index buffer and a generic material
            let indexCount = faces.count * faces.indexCountPerPrimitive
            let material = MDLMaterial(name: "jpegTexture", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
//            let color = CGColor(red: 0, green: 0.5, blue: 1.0, alpha: 1.0) // Red color, adjust as needed
//            let property = MDLMaterialProperty(name: "color", semantic: .baseColor, color: color)
//            material.setProperty(property)
            
            let mdlTexture = MDLTexture(data: dataImage, topLeftOrigin: true, name: "jpegTexture", dimensions: vector_int2(Int32(imageWidth!), Int32(imageHeight!)), rowStride: bytesPerRow, channelCount: 4, channelEncoding: .uInt8, isCube: false)
            
            
            let textureProperty = MDLMaterialProperty(name: "imageTexture", semantic: .baseColor, textureSampler: nil)
            let sampler = MDLTextureSampler()
            sampler.texture = mdlTexture
            
            textureProperty.textureSamplerValue = sampler
            material.setProperty(textureProperty)
            
            let submesh = MDLSubmesh(indexBuffer: indexBuffer, indexCount: indexCount, indexType: .uInt32, geometryType: .triangles, material: material)
            
            // Creating a MDLVertexDescriptor to describe the memory layout of the mesh
            let vertexFormat = MTKModelIOVertexFormatFromMetal(vertices.format)
            let vertexDescriptor = MDLVertexDescriptor()
            vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: vertexFormat, offset: 0, bufferIndex: 0)
//            vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: vertexFormat, offset: MemoryLayout<Float>.size * 3, bufferIndex: 0)
            vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: vertexFormat, offset: MemoryLayout<Float>.size * 3, bufferIndex: 0)
            vertexDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: vertexFormat, offset: MemoryLayout<Float>.size * 6, bufferIndex: 0)
            vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: anchor.geometry.vertices.stride)
            
            
            // Finally creating the MDLMesh and adding it to the MDLAsset
            let mesh = MDLMesh(vertexBuffer: vertexBuffer, vertexCount: anchor.geometry.vertices.count, descriptor: vertexDescriptor, submeshes: [submesh])
            
            asset.add(mesh)
        }
        
        return asset
    } */
     
    
    func generateAsset() -> MDLAsset {
        guard let frame = session.currentFrame else {
            fatalError("Couldn't get the current ARFrame")
        }
        
        // Fetch the default MTLDevice to initialize a MetalKit buffer allocator with
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Failed to get the system's default Metal device!")
        }
        
        // Using the Model I/O framework to export the scan, so we're initialising an MDLAsset object,
        // which we can export to a file later, with a buffer allocator
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(bufferAllocator: allocator)
        
        
        let meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
        
        for anchor in meshAnchors {
            let anchorId = anchor.identifier
            guard let image = imagesAndAnchor[anchorId] else { fatalError("error no image") }
            let mesh = anchor.geometry.toMDLMesh(device: device, transform: anchor.transform, image: image)
            asset.add(mesh)
        }
        
        return asset
    }
    
    func getImageForTexture() -> UIImage? {
        guard let frame = session.currentFrame else {
            fatalError("Couldn't get the current ARFrame")
        }

        let pixelBuffer = frame.capturedImage
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        
        let context = CIContext(options:nil)
        guard let cameraImage = context.createCGImage(image, from: image.extent) else {return nil}

        return UIImage(cgImage: cameraImage)
    }
    
    func createAllTexturedMesh() {
        guard let frame = session.currentFrame else {
            fatalError("Couldn't get the current ARFrame")
        }
        
        // Fetch the default MTLDevice to initialize a MetalKit buffer allocator with
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Failed to get the system's default Metal device!")
        }
        
        // Using the Model I/O framework to export the scan, so we're initialising an MDLAsset object,
        // which we can export to a file later, with a buffer allocator
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(bufferAllocator: allocator)
        
        let meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
        
        
        for anchor in meshAnchors {
            let id = anchor.identifier
            let cameraImage = imagesAndAnchor[id]
            let node = SCNNode()
            let geom = scanGeometry(frame: frame, anchor: anchor, node: node, cameraImage: cameraImage, needTexture: true)
            node.geometry = geom
            print(node, "geom node")
            testNode.append(node)
            
        }
    }
    
    
    func scanGeometry(frame: ARFrame, anchor: ARMeshAnchor, node: SCNNode, cameraImage: UIImage? = nil, needTexture: Bool) -> SCNGeometry {

        let camera = frame.camera

        let geometry = SCNGeometry(geometry: anchor.geometry, camera: camera, modelMatrix: anchor.transform, needTexture: needTexture)

        if let image = cameraImage {
            geometry.firstMaterial?.diffuse.contents = image
            geometry.firstMaterial?.isDoubleSided = false
        } else {
            geometry.firstMaterial?.diffuse.contents = UIColor(red: 0.5, green: 1.0, blue: 0.0, alpha: 0.7)
        }
       // geometry.firstMaterial?.diffuse.contents = UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.7)
        node.geometry = geometry

        return geometry
    }
    
    
    
    // Export to OBJ
    func prepareToExport() {
        guard let frame = session.currentFrame else {
            fatalError("Couldn't get the current ARFrame")
        }
        let pic = cvPixelBuffer2UIImage(pixelBuffer: frame.capturedImage)
        textureImage = pic
        let url = getDocumentsDirectory().appendingPathComponent(currentFolder + "/data", isDirectory: true)
        let objUrl = url.appendingPathComponent("\(getTimeStr()).obj")
        objURL = objUrl
        let jpgUrl = url.appendingPathComponent("\(getTimeStr()).jpg")
        picURL = jpgUrl
        let metadata = generateMetaData()
        header = metadata
    }
    
    // get Metadata
    func generateMetaData() -> String {
        if header != "" {
            return header
        }
        return ""
    }
    
    func getLocationProperties(long: Double, lat: Double, el: Double) {
        let rotation = viewToCamera
        let radians = atan2(rotation.a, rotation.d)
        let degrees = radians * 180 / .pi
        
        print(el, "altitude")
        
        if header == "" {
            header += """
                    # Captured with Datamine
                    #
                    # Version:
                    # Mode:
                    # Unit: meter
                    # Latitude: \(lat)
                    # Longitude: \(long)
                    # Elevation: \(el)
                    # Rotation: \(degrees) deg
                    
                    
                    
                    """
        } else {
            header += ""
        }
    }
}

// MARK: - Metal Helpers

private extension ScannerRenderer {
    func makeUnprojectionPipelineState() -> MTLRenderPipelineState? {
        guard let vertexFunction = library.makeFunction(name: "unprojectVertex") else {
            return nil
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.isRasterizationEnabled = false
        descriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    func makeRGBPipelineState() -> MTLRenderPipelineState? {
        guard let vertexFunction = library.makeFunction(name: "rgbVertex"),
              let fragmentFunction = library.makeFunction(name: "rgbFragment") else {
            return nil
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    func makeParticlePipelineState() -> MTLRenderPipelineState? {
        guard let vertexFunction = library.makeFunction(name: "particleVertex"),
              let fragmentFunction = library.makeFunction(name: "particleFragment") else {
            return nil
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    /// Makes sample points on camera image, also precompute the anchor point for animation
    func makeGridPoints() -> [Float2] {
        let gridArea = cameraResolution.x * cameraResolution.y
        let spacing = sqrt(gridArea / Float(numGridPoints))
        let deltaX = Int(round(cameraResolution.x / spacing))
        let deltaY = Int(round(cameraResolution.y / spacing))
        
        var points = [Float2]()
        for gridY in 0 ..< deltaY {
            let alternatingOffsetX = Float(gridY % 2) * spacing / 2
            for gridX in 0 ..< deltaX {
                let cameraPoint = Float2(alternatingOffsetX + (Float(gridX) + 0.5) * spacing, (Float(gridY) + 0.5) * spacing)
                
                points.append(cameraPoint)
            }
        }
        
        return points
    }
    
    func makeTextureCache() -> CVMetalTextureCache {
        // Create captured image texture cache
        var cache: CVMetalTextureCache!
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        
        return cache
    }
    
    func makeTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var texture: CVMetalTexture? = nil
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &texture)
        
        if status != kCVReturnSuccess {
            texture = nil
        }
        
        return texture
    }
    
    static func cameraToDisplayRotation(orientation: UIInterfaceOrientation) -> Int {
        switch orientation {
        case .landscapeLeft:
            return 180
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return -90
        default:
            return 0
        }
    }
    
    static func makeRotateToARCameraMatrix(orientation: UIInterfaceOrientation) -> matrix_float4x4 {
        // flip to ARKit Camera's coordinate
        let flipYZ = matrix_float4x4(
            [1, 0, 0, 0],
            [0, -1, 0, 0],
            [0, 0, -1, 0],
            [0, 0, 0, 1] )
        
        let rotationAngle = Float(cameraToDisplayRotation(orientation: orientation)) * .degreesToRadian
        return flipYZ * matrix_float4x4(simd_quaternion(rotationAngle, Float3(0, 0, 1)))
    }
}
