//
//  MetalBuffer+Helpers+Utils.swift
//  ScannerLidarApp
//
//  Created by Juli Yanti on 12/04/24.
//

import MetalKit
import ARKit
import Foundation
import UIKit
import VideoToolbox

protocol Resource {
    associatedtype Element
}

/// A wrapper around MTLBuffer which provides type safe access and assignment to the underlying MTLBuffer's contents.

struct MetalBuffer<Element>: Resource {
        
    /// The underlying MTLBuffer.
    fileprivate let buffer: MTLBuffer
    
    /// The index that the buffer should be bound to during encoding.
    /// Should correspond with the index that the buffer is expected to be at in Metal shaders.
    fileprivate let index: Int
    
    /// The number of elements of T the buffer can hold.
    let count: Int
    var stride: Int {
        MemoryLayout<Element>.stride
    }

    /// Initializes the buffer with zeros, the buffer is given an appropriate length based on the provided element count.
    init(device: MTLDevice, count: Int, index: UInt32, label: String? = nil, options: MTLResourceOptions = []) {
        
        guard let buffer = device.makeBuffer(length: MemoryLayout<Element>.stride * count, options: options) else {
            fatalError("Failed to create MTLBuffer.")
        }
        self.buffer = buffer
        self.buffer.label = label
        self.count = count
        self.index = Int(index)
    }
    
    /// Initializes the buffer with the contents of the provided array.
    init(device: MTLDevice, array: [Element], index: UInt32, options: MTLResourceOptions = []) {
        
        guard let buffer = device.makeBuffer(bytes: array, length: MemoryLayout<Element>.stride * array.count, options: .storageModeShared) else {
            fatalError("Failed to create MTLBuffer")
        }
        self.buffer = buffer
        self.count = array.count
        self.index = Int(index)
    }
    
    /// Replaces the buffer's memory at the specified element index with the provided value.
    func assign<T>(_ value: T, at index: Int = 0) {
        precondition(index <= count - 1, "Index \(index) is greater than maximum allowable index of \(count - 1) for this buffer.")
        withUnsafePointer(to: value) {
            buffer.contents().advanced(by: index * stride).copyMemory(from: $0, byteCount: stride)
        }
    }
    
    /// Replaces the buffer's memory with the values in the array.
    func assign<Element>(with array: [Element]) {
        let byteCount = array.count * stride
        precondition(byteCount == buffer.length, "Mismatch between the byte count of the array's contents and the MTLBuffer length.")
        buffer.contents().copyMemory(from: array, byteCount: byteCount)
    }
    
    /// Returns a copy of the value at the specified element index in the buffer.
    subscript(index: Int) -> Element {
        get {
            precondition(stride * index <= buffer.length - stride, "This buffer is not large enough to have an element at the index: \(index)")
            return buffer.contents().advanced(by: index * stride).load(as: Element.self)
        }
        
        set {
            assign(newValue, at: index)
        }
    }
    
}

// Note: This extension is in this file because access to Buffer<T>.buffer is fileprivate.
// Access to Buffer<T>.buffer was made fileprivate to ensure that only this file can touch the underlying MTLBuffer.
extension MTLRenderCommandEncoder {
    func setVertexBuffer<T>(_ vertexBuffer: MetalBuffer<T>, offset: Int = 0) {
        setVertexBuffer(vertexBuffer.buffer, offset: offset, index: vertexBuffer.index)
    }
    
    func setFragmentBuffer<T>(_ fragmentBuffer: MetalBuffer<T>, offset: Int = 0) {
        setFragmentBuffer(fragmentBuffer.buffer, offset: offset, index: fragmentBuffer.index)
    }
    
    func setVertexResource<R: Resource>(_ resource: R) {
        if let buffer = resource as? MetalBuffer<R.Element> {
            setVertexBuffer(buffer)
        }
        
        if let texture = resource as? Texture {
            setVertexTexture(texture.texture, index: texture.index)
        }
    }
    
    func setFragmentResource<R: Resource>(_ resource: R) {
        if let buffer = resource as? MetalBuffer<R.Element> {
            setFragmentBuffer(buffer)
        }

        if let texture = resource as? Texture {
            setFragmentTexture(texture.texture, index: texture.index)
        }
    }
}

struct Texture: Resource {
    typealias Element = Any
    
    let texture: MTLTexture
    let index: Int
}


typealias Float2 = SIMD2<Float>
typealias Float3 = SIMD3<Float>

extension Float {
    static let degreesToRadian = Float.pi / 180
}

extension matrix_float3x3 {
    mutating func copy(from affine: CGAffineTransform) {
        columns.0 = Float3(Float(affine.a), Float(affine.c), Float(affine.tx))
        columns.1 = Float3(Float(affine.b), Float(affine.d), Float(affine.ty))
        columns.2 = Float3(0, 0, 1)
    }
}

/// Get current time in string.
func getTimeStr() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_hhmmss"
    return df.string(from: Date())
}

/// Save file to a directory.
func saveFile(content: String, filename: String, folder: String) async throws -> () {
    print("Save file to \(folder)/\(filename)")
    let url = getDocumentsDirectory().appendingPathComponent(folder, isDirectory: true).appendingPathComponent(filename)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

/// Save jpeg to a directory.
func savePic(pic: UIImage, filename: String, folder: String) async throws -> () {
    print("Save picture to \(folder)/\(filename)")
    let url = getDocumentsDirectory().appendingPathComponent(folder, isDirectory: true).appendingPathComponent(filename)
    try pic.jpegData(compressionQuality: 0)?.write(to: url)
}

/// Transform cvPixelBuffer of datatype <T> to a 2D array map.
func cvPixelBuffer2Map<T : Numeric>(rawDepth: CVPixelBuffer) async -> [[T]] {
    CVPixelBufferLockBaseAddress(rawDepth, CVPixelBufferLockFlags(rawValue: 0))
    let addr = CVPixelBufferGetBaseAddress(rawDepth)
    let height = CVPixelBufferGetHeight(rawDepth)
    let width = CVPixelBufferGetWidth(rawDepth)
    
    let TBuffer = unsafeBitCast(addr, to: UnsafeMutablePointer<T>.self)
    
    var TMap : [[T]] = Array(repeating: Array(repeating: T(exactly: 0)!, count: width), count: height)
    
    for row in 0...(height - 1){
        for col in 0...(width - 1){
            TMap[row][col] = TBuffer[row * width + col]
        }
    }
    CVPixelBufferUnlockBaseAddress(rawDepth, CVPixelBufferLockFlags(rawValue: 0))
    return TMap
}

/// Transform cvPixelBuffer to a UIImage.
func cvPixelBuffer2UIImage(pixelBuffer: CVPixelBuffer) -> UIImage {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    return UIImage(ciImage: ciImage)
}

func getDocumentsDirectory() -> URL {
    // find all possible documents directories for this user
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    
    // just send back the first one, which ought to be the only one
    return paths[0]
}

func createDirectory(folder: String) {
    let path = getDocumentsDirectory().appendingPathComponent(folder)
    do
    {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    catch let error as NSError
    {
        print("Unable to create directory \(error.debugDescription)")
    }
    
}

/// https://stackoverflow.com/questions/63661474/how-can-i-encode-an-array-of-simd-float4x4-elements-in-swift-convert-simd-float
extension simd_float4x4: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        try self.init(container.decode([SIMD4<Float>].self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode([columns.0, columns.1, columns.2, columns.3])
    }
}

extension simd_float3x3: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        try self.init(container.decode([SIMD3<Float>].self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode([columns.0, columns.1, columns.2])
    }
}

/// Send task start/finish messages.
protocol TaskDelegate: AnyObject {
    func didStartTask()
    func didFinishTask()
}

/// Deep copy CVPixelBuffer for depth data
/// https://stackoverflow.com/questions/65868215/deep-copy-cvpixelbuffer-for-depth-data-in-swift
func duplicatePixelBuffer(input: CVPixelBuffer) -> CVPixelBuffer {
    var copyOut: CVPixelBuffer?
    let bufferWidth = CVPixelBufferGetWidth(input)
    let bufferHeight = CVPixelBufferGetHeight(input)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(input)
    let bufferFormat = CVPixelBufferGetPixelFormatType(input)
    
    _ = CVPixelBufferCreate(kCFAllocatorDefault, bufferWidth, bufferHeight, bufferFormat, CVBufferGetAttachments(input, CVAttachmentMode.shouldPropagate), &copyOut)
    let output = copyOut!
    // Lock the depth map base address before accessing it
    CVPixelBufferLockBaseAddress(input, CVPixelBufferLockFlags.readOnly)
    CVPixelBufferLockBaseAddress(output, CVPixelBufferLockFlags(rawValue: 0))
    let baseAddress = CVPixelBufferGetBaseAddress(input)
    let baseAddressCopy = CVPixelBufferGetBaseAddress(output)
    memcpy(baseAddressCopy, baseAddress, bufferHeight * bytesPerRow)
    
    // Unlock the base address when finished accessing the buffer
    CVPixelBufferUnlockBaseAddress(input, CVPixelBufferLockFlags.readOnly)
    CVPixelBufferUnlockBaseAddress(output, CVPixelBufferLockFlags(rawValue: 0))
    return output
}

