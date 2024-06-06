//
//  PreviewController.swift
//  ScannerLidarApp
//
//  Created by Juli Yanti on 30/04/24.
//

import UIKit
import SceneKit.ModelIO
import ARKit


class PreviewController: UIViewController {
    weak var delegate: PreviewControllerDelegate?
    private var sceneView: SCNView?
    private var mdlAsset: MDLAsset?
    private var metaData: String?
    private var imageData: UIImage?
    private var objUrl: URL?
    private var picURL: URL?
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        sceneView = SCNView(frame: self.view.frame)
        self.view.addSubview(sceneView!)
        
        sceneView?.autoenablesDefaultLighting = true
        sceneView?.allowsCameraControl = true
        
        delegate?.sendARData()
        delegate?.sendExportData()
        
        // Add export button
        let exportButton = UIButton(type: .system)
        exportButton.setTitle("Export", for: .normal)
        exportButton.addTarget(self, action: #selector(exportButtonTapped), for: .touchUpInside)
        exportButton.frame = CGRect(x: 20, y: 20, width: 100, height: 40)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(exportButton)
        
        NSLayoutConstraint.activate([
            exportButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            exportButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40)])
    }
    
    func getScannedNodes(nodes: [SCNNode]) {
        let scene = SCNScene()
        let nodesScanned = nodes
        
        for childNode in nodesScanned {
            if let geometry = childNode.geometry {
                for material in geometry.materials {
                    if let textureName = material.diffuse.contents as? String {
                        // Load the texture
                        if let texture = UIImage(named: textureName) {
                            material.diffuse.contents = texture
                        } else {
                            print("Failed to load texture: \(textureName)")
                        }
                    }
                }
            }
            scene.rootNode.addChildNode(childNode)
            
        }
        sceneView?.scene = scene
    }
    
    func getScannedAsset(nodes: MDLAsset) {
        sceneView?.scene?.rootNode.childNodes.forEach { $0.removeFromParentNode() }
            
        let scene = SCNScene()
        let modelScene = SCNScene(mdlAsset: nodes)
        
        for node in modelScene.rootNode.childNodes {
            scene.rootNode.addChildNode(node)
        }
        
        sceneView?.scene = scene
        
    }
    
    func updateExportData(imageTexture: UIImage, obj: URL, pic: URL, meta:String) {
        imageData = imageTexture
        objUrl = obj
        picURL = pic
        metaData = meta
    }
    
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    
    
    @objc func exportButtonTapped() {
        // Handle export functionality here
        // For example, you can export the scene as an OBJ file
        
        do {
            
            try mdlAsset?.export(to: objUrl!)
            
        } catch {
            fatalError("Error \(error.localizedDescription)")
        }
        
        do {
            
            try imageData?.jpegData(compressionQuality: 0)?.write(to: picURL!)
            
        } catch {
            fatalError("Error \(error.localizedDescription)")
        }
        
        // handle metadata
        
        do {
            let existingContent = (try? String(contentsOfFile: objUrl!.path))
            // print(existingContent, "content")
            let fileHandler = FileHandle(forWritingAtPath: objUrl!.path)
            try fileHandler?.seek(toOffset: 0)
            fileHandler?.write((metaData!.data(using: .utf8)!))
            fileHandler?.write((existingContent?.data(using: .utf8))!)
            try fileHandler?.close()
            
            
        } catch {
            fatalError("Error \(error.localizedDescription)")
        }
        
        metaData = ""
        print ("export")
        
    }
}
