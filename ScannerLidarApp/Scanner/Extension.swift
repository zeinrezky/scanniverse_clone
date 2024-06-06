//
//  Extension.swift
//  ScannerLidarApp
//
//  Created by Juli Yanti on 01/05/24.
//
import ARKit
import RealityKit
import MetalKit
import SceneKit
import ModelIO



extension simd_float4x4 {
    var position: SIMD3<Float> {
        return SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension Transform {
    static func * (left: Transform, right: Transform) -> Transform {
        return Transform(matrix: simd_mul(left.matrix, right.matrix))
    }
}

    // MARK: extension ARMeshGeometry


extension ARMeshGeometry {
    func vertex(at index: UInt32) -> (Float, Float, Float) {
        assert(vertices.format == MTLVertexFormat.float3, "Expected three floats (twelve bytes) per vertex.")
        let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * Int(index)))
        let vertex = vertexPointer.assumingMemoryBound(to: (Float, Float, Float).self).pointee
        return vertex
    }
    
    func toMDLMesh(device: MTLDevice, transform: simd_float4x4, image: UIImage ) -> MDLMesh {
        
        let allocator = MTKMeshBufferAllocator(device: device)
        
        let textureLoader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option : Any] = [
            .origin : MTKTextureLoader.Origin.bottomLeft,
            .SRGB : false
        ]
        
        guard (try? textureLoader.newTexture(cgImage: image.cgImage!, options: options)) != nil else {
            fatalError("Texture creation failed")
        }
        
        let vertexFormat = MTKModelIOVertexFormatFromMetal(vertices.format)
        
        
        let vertexDescriptor = MDLVertexDescriptor()
        
        vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                            format: vertexFormat,
                                                            offset: 0,
                                                            bufferIndex: 0)
        
        // Texture coordinate attribute (if needed)
        vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate,
                                                            format: .float2,
                                                            offset: MemoryLayout<Float>.size * 3,
                                                            bufferIndex: 0)
        
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: vertices.stride)
        
        let cgImage = image.cgImage
        let pixelData = cgImage?.dataProvider?.data
        let dataImage: Data = pixelData! as Data
        
        let imageWidth = cgImage?.width
        let imageHeight = cgImage?.height
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * imageWidth!
        
        
        let data = Data.init(bytes: transformedVertexBuffer(transform), count: vertices.stride * vertices.count)
        
        let vertexBuffer = allocator.newBuffer(with: data , type: .vertex)
        
        let indexData = Data.init(bytes: faces.buffer.contents(), count: faces.bytesPerIndex * faces.count * faces.indexCountPerPrimitive)
        
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)
        
        let material = MDLMaterial(name: "jpegTexture", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        //        let color = CGColor(red: 0, green: 0.5, blue: 1.0, alpha: 1.0) // Red color, adjust as needed
        //        let property = MDLMaterialProperty(name: "color", semantic: .baseColor, color: color)
        //        material.setProperty(property)
        
        let mdlTexture = MDLTexture(data: dataImage, topLeftOrigin: true, name: "jpegTexture", dimensions: vector_int2(Int32(imageWidth!), Int32(imageHeight!)), rowStride: bytesPerRow, channelCount: 4, channelEncoding: .uInt8, isCube: false)
        
        let imageFromTexture = mdlTexture.imageFromTexture()
        print(imageFromTexture!, "image")
        
        
        let textureProperty = MDLMaterialProperty(name: "imageTexture", semantic: .baseColor, textureSampler: nil)
        let sampler = MDLTextureSampler()
        sampler.transform = MDLTransform(matrix: transform)
        sampler.texture = mdlTexture
        sampler.hardwareFilter?.magFilter = .nearest
        sampler.hardwareFilter?.minFilter = .nearest
        sampler.hardwareFilter?.mipFilter = .nearest
        sampler.hardwareFilter?.rWrapMode = .repeat
        sampler.hardwareFilter?.tWrapMode = .repeat
        sampler.hardwareFilter?.sWrapMode = .repeat
        
        textureProperty.textureSamplerValue = sampler
        material.setProperty(textureProperty)
        
        
        let submesh = MDLSubmesh(indexBuffer: indexBuffer,
                                 indexCount: faces.count * faces.indexCountPerPrimitive,
                                 indexType: .uint32,
                                 geometryType: .triangles,
                                 material: material)
        
        
        let mdlMesh = MDLMesh(vertexBuffer: vertexBuffer,
                              vertexCount: vertices.count,
                              descriptor: vertexDescriptor,
                              submeshes: [submesh])
        
        return mdlMesh
    }
    
    func transformedVertexBuffer(_ transform: simd_float4x4) -> [Float] {
        var result = [Float]()
        for index in 0..<vertices.count {
            let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + vertices.stride * index)
            let vertex = vertexPointer.assumingMemoryBound(to: (Float, Float, Float).self).pointee
            var vertextTransform = matrix_identity_float4x4
            vertextTransform.columns.3 = SIMD4<Float>(vertex.0, vertex.1, vertex.2, 1)
            let position = (transform * vertextTransform).position
            result.append(position.x)
            result.append(position.y)
            result.append(position.z)
        }
        return result
    }
    
    
}

    // MARK: Scanner Renderer

extension ScannerRenderer {
    func getTextureImage(frame: ARFrame) -> UIImage? {

        let pixelBuffer = frame.capturedImage
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        
        let context = CIContext(options:nil)
        guard let cameraImage = context.createCGImage(image, from: image.extent) else {return nil}

        return UIImage(cgImage: cameraImage)
    }
    
    func getVertex(at index: UInt32, vertices: ARGeometrySource) -> SIMD3<Float> {
        assert(vertices.format == MTLVertexFormat.float3, "Expected three floats (twelve bytes) per vertex.")
        let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * Int(index)))
        let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
        return vertex
    }
    
    func getTextureCoord(frame: ARFrame, vert: SIMD3<Float>, aTrans: simd_float4x4) -> vector_float2 {
        
        // convert vertex to world coordinates
        let cam = frame.camera
        let size = cam.imageResolution
        let vertex4 = vector_float4(vert.x, vert.y, vert.z, 1)
        let world_vertex4 = simd_mul(aTrans, vertex4)
        let world_vector3 = simd_float3(x: world_vertex4.x, y: world_vertex4.y, z: world_vertex4.z)
        
        // project the point into the camera image to get u,v
        let pt = cam.projectPoint(world_vector3,
                                  orientation: .portrait,
                                  viewportSize: CGSize(
                                    width: CGFloat(size.height),
                                    height: CGFloat(size.width)))
        let v = 1.0 - Float(pt.x) / Float(size.height)
        let u = Float(pt.y) / Float(size.width)
        
        let tCoord = vector_float2(u, v)
        
        return tCoord
    }
    
    
    func getTextureCoords(frame: ARFrame, vertices: ARGeometrySource, aTrans: simd_float4x4) -> [vector_float2] {
        
        var tCoords: [vector_float2] = []
        
        for v in 0..<vertices.count {
            let vert = getVertex(at: UInt32(v), vertices: vertices)
            let tCoord = getTextureCoord(frame: frame, vert: vert, aTrans: aTrans)
            
            tCoords.append(tCoord)
        }
        
        return tCoords
    }
    
    func dist3D(a: SCNVector3, b: SCNVector3) -> CGFloat {
        let dist = sqrt(((b.x - a.x) * (b.x - a.x)) + ((b.y - a.y) * (b.y - a.y)) + ((b.z - a.z) * (b.z - a.z)))
        return CGFloat(dist)
    }
    
    func normal(at index: UInt32, normals: ARGeometrySource) -> SIMD3<Float> {
        assert(normals.format == MTLVertexFormat.float3, "Expected three floats (twelve bytes) per normal.")
        let normalPointer = normals.buffer.contents().advanced(by: normals.offset + (normals.stride * Int(index)))
        let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
        return normal
    }
    
    func face(at index: Int, faces: ARGeometryElement) -> [Int] {
        let indicesPerFace = faces.indexCountPerPrimitive
        let facesPointer = faces.buffer.contents()
        var vertexIndices = [Int]()
        for offset in 0..<indicesPerFace {
            let vertexIndexAddress = facesPointer.advanced(by: (index * indicesPerFace + offset) * MemoryLayout<UInt32>.size)
            vertexIndices.append(Int(vertexIndexAddress.assumingMemoryBound(to: UInt32.self).pointee))
        }
        return vertexIndices
    }
    
}

extension CGPoint {
    init(_ vector: vector_float2) {
        self.init(x: CGFloat(vector.x), y: CGFloat(vector.y))
    }
}

func convertVectorFloat2ArrayToPointArray(vectorArray: [vector_float2]) -> [CGPoint] {
    var pointArray = [CGPoint]()
    
    for vector in vectorArray {
        let point = CGPoint(vector)
        pointArray.append(point)
    }
    
    return pointArray
}


extension SCNGeometry {
    convenience init(geometry: ARMeshGeometry, camera: ARCamera, modelMatrix: simd_float4x4, needTexture: Bool = false) {
        func convertType(type: ARGeometryPrimitiveType) -> SCNGeometryPrimitiveType {
            switch type {
            case .line:
                return .line
            case .triangle:
                return .triangles
            @unknown default:
                fatalError("unknown type")
            }
            
        }
        // helps from: https://stackoverflow.com/questions/61538799/ipad-pro-lidar-export-geometry-texture
        func calcTextureCoordinates(verticles: ARGeometrySource, camera: ARCamera, modelMatrix: simd_float4x4) ->  SCNGeometrySource? {
            func getVertex(at index: UInt32) -> SIMD3<Float> {
                    assert(verticles.format == MTLVertexFormat.float3, "Expected three floats (twelve bytes) per vertex.")
                    let vertexPointer = verticles.buffer.contents().advanced(by: verticles.offset + (verticles.stride * Int(index)))
                    let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    return vertex
            }
            func buildCoordinates() -> [vector_float2]? {
                let size = camera.imageResolution
                let textureCoordinates = (0..<verticles.count).map { i -> vector_float2 in
                    let vertex = getVertex(at: UInt32(i))
                    let vertex4 = vector_float4(vertex.x, vertex.y, vertex.z, 1)
                    let world_vertex4 = simd_mul(modelMatrix, vertex4)
                    let world_vector3 = simd_float3(x: world_vertex4.x, y: world_vertex4.y, z: world_vertex4.z)
                    let pt = camera.projectPoint(world_vector3,
                                                 orientation: .portrait,
                        viewportSize: CGSize(
                            width: CGFloat(size.height),
                            height: CGFloat(size.width)))
                    let v = 1.0 - Float(pt.x) / Float(size.height)
                    let u = Float(pt.y) / Float(size.width)
                    return vector_float2(u, v)
                }
                return textureCoordinates
            }
            guard let texcoords = buildCoordinates() else {return nil}
            let result = SCNGeometrySource(textureCoordinates: texcoords)
            
            return result
        }
        let verticles = geometry.vertices
        let normals = geometry.normals
        let faces = geometry.faces
        let verticesSource = SCNGeometrySource(buffer: verticles.buffer, vertexFormat: verticles.format, semantic: .vertex, vertexCount: verticles.count, dataOffset: verticles.offset, dataStride: verticles.stride)
        let normalsSource = SCNGeometrySource(buffer: normals.buffer, vertexFormat: normals.format, semantic: .normal, vertexCount: normals.count, dataOffset: normals.offset, dataStride: normals.stride)
        let data = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let facesElement = SCNGeometryElement(data: data, primitiveType: convertType(type: faces.primitiveType), primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        var sources = [verticesSource, normalsSource]
        if needTexture {
            let textureCoordinates = calcTextureCoordinates(verticles: verticles, camera: camera, modelMatrix: modelMatrix)!
            sources.append(textureCoordinates)
        }
        self.init(sources: sources, elements: [facesElement])
    }
}

extension SCNGeometrySource {
    convenience init(textureCoordinates texcoord: [vector_float2]) {
        let stride = MemoryLayout<vector_float2>.stride
        let bytePerComponent = MemoryLayout<Float>.stride
        let data = Data(bytes: texcoord, count: stride * texcoord.count)
        self.init(data: data, semantic: SCNGeometrySource.Semantic.texcoord, vectorCount: texcoord.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: bytePerComponent, dataOffset: 0, dataStride: stride)
    }
}

