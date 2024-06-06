//
//  ScannerController.swift
//  ScannerLidarApp
//
//  Created by Juli Yanti on 29/03/24.
//

import UIKit
import ARKit
import MetalKit


final class ScannerController: UIViewController, ARSessionDelegate, CLLocationManagerDelegate {
    
    private let isUIEnabled = true
    private let rgbRadiusSlider = UISlider()
    private var isRecording = false
    
    private let textLabel = UILabel()
    
    private var taskNum = 0;
    private var completedTaskNum = 0;
    
    private let session = ARSession()
    private var renderer: ScannerRenderer!
    let locationManager = CLLocationManager()
    private var imagesWithAnchor = [UUID: UIImage]()
    
    // Shutter Button
    
    let customButton = UIButton()

    private lazy var redRectangleLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        let diameter: CGFloat = 40
        let rectangleSize = CGSize(width: 25, height: 25)
        let originRectX = ((diameter - rectangleSize.width) / 2)
        let originRectY = ((diameter - rectangleSize.height) / 2)
        let redRectanglePath = UIBezierPath(rect: CGRect(origin: CGPoint(x: originRectX + 30, y: originRectY + 30), size: rectangleSize))
        layer.path = redRectanglePath.cgPath
        layer.fillColor = UIColor.red.cgColor
        return layer
    }()

    private lazy var redCircleLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        let diameter: CGFloat = 40
        let originX = (customButton.bounds.width - diameter) / 2
        let originY = (customButton.bounds.height - diameter) / 2
        let redCirclePath = UIBezierPath(ovalIn: CGRect(x: originX, y: originY, width: diameter, height: diameter))
        layer.path = redCirclePath.cgPath
        layer.fillColor = UIColor.red.cgColor
        return layer
    }()

    private lazy var whiteCircleLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        let diameter: CGFloat = 40
        let whiteDiameter: CGFloat = diameter + 4
        let whiteOriginX = (customButton.bounds.width - whiteDiameter) / 2
        let whiteOriginY = (customButton.bounds.height - whiteDiameter) / 2
        let whiteCirclePath = UIBezierPath(ovalIn: CGRect(x: whiteOriginX, y: whiteOriginY, width: whiteDiameter, height: whiteDiameter))
        layer.path = whiteCirclePath.cgPath
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.white.cgColor
        layer.lineWidth = 2
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return
        }
        
        session.delegate = self
        locationManager.delegate = self
        
        guard let metalView = self.view as? MTKView else {
            fatalError("View is not a MTKView")
        }
        
        // Set the view to use the default device
        metalView.device = device
        metalView.backgroundColor = UIColor.clear
        
        // we need this to enable depth test
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.contentScaleFactor = 1
        metalView.delegate = self
        
        
        // Configure the renderer to draw to the view
        renderer = ScannerRenderer(session: session, metalDevice: device, renderDestination: metalView)
        renderer.drawRectResized(size: metalView.bounds.size)
        renderer.delegate = self
        
        // RGB Radius control
        rgbRadiusSlider.minimumValue = 0
        rgbRadiusSlider.maximumValue = 1.5
        rgbRadiusSlider.isContinuous = true
        rgbRadiusSlider.value = renderer.rgbRadius
        rgbRadiusSlider.addTarget(self, action: #selector(viewValueChanged), for: .valueChanged)
        
        // Set up customButton
        customButton.frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        customButton.backgroundColor = .clear
        customButton.addTarget(self, action: #selector(customButtonTapped), for: .touchUpInside)
        view.addSubview(customButton)
        
        // UILabel
        textLabel.text = "  1 of frames"
        textLabel.textColor = .white
        textLabel.backgroundColor = UIColor.darkGray.withAlphaComponent(0.5)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.layer.masksToBounds = true
        textLabel.layer.cornerRadius = 8
        textLabel.textAlignment = .right
        textLabel.sizeToFit()
        textLabel.numberOfLines = 2
        
        
        customButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            customButton.widthAnchor.constraint(equalToConstant: 100),
            customButton.heightAnchor.constraint(equalToConstant: 100),
            customButton.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -20), // Adjust the constant for desired spacing
            customButton.centerYAnchor.constraint(equalTo: metalView.centerYAnchor)
        ])
        
        // Initial appearance with red circle
        customButton.layer.addSublayer(whiteCircleLayer)
        customButton.layer.addSublayer(redCircleLayer)
        
        let stackView = UIStackView(arrangedSubviews: [rgbRadiusSlider])
        stackView.isHidden = !isUIEnabled
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 10
        view.addSubview(stackView)
        view.addSubview(textLabel)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo:metalView.centerXAnchor),
            stackView.widthAnchor.constraint(equalToConstant: 150),
            stackView.heightAnchor.constraint(equalToConstant: 150),
            stackView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor, constant: -20),
            textLabel.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -60),
            textLabel.bottomAnchor.constraint(equalTo: metalView.bottomAnchor, constant: -20),
            textLabel.heightAnchor.constraint(equalToConstant: 50),
        ])
        
    }
    
    private func initARSession() -> ARWorldTrackingConfiguration {
        // Create a world-tracking configuration, and
        // enable the scene depth frame-semantic.
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]
        
        
        configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        return configuration
    }
    
    private func resetARSession() {
        // Create a new ARWorldTrackingConfiguration with your desired settings
        let configuration = ARWorldTrackingConfiguration()
        // Restart the session with the new configuration
        session.run(configuration, options: [.removeExistingAnchors, .resetSceneReconstruction])
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let config = initARSession()
        session.run(config)
        
        
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        
        updateTextLabel()
        
        // The screen shouldn't dim during AR experiences.
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.pause()
        locationManager.stopUpdatingLocation()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        
        print("memory warning!!!")
        memoryAlert()
        updateIsRecording(_isRecording: false)
    }
    
    private func showAlert(textTitle: String, textMessage: String) -> UIAlertController {
        let alert = UIAlertController(title: textTitle, message: textMessage, preferredStyle: .alert)
        self.present(alert, animated: true, completion: nil)
        return alert
    }
    
    private func memoryAlert() {
        let alert = UIAlertController(title: "Low Memory Warning", message: "The recording has been paused. Do not quit the app until all files have been saved.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Default action"), style: .default, handler: { _ in
            NSLog("The \"OK\" alert occured.")
        }))
        self.present(alert, animated: true, completion: nil)
    }
    
    // MARK: Handle Button Recording
    
    @objc func customButtonTapped() {
        print("tapped")
        updateIsRecording(_isRecording: !isRecording)

        
        if renderer.currentFrameIndex < renderer.pickFrames {
            // Display an alert indicating that OBJ file cannot be saved
            let alert = showAlert(textTitle: "Attention", textMessage: "Minimum frames need to be recorded at least \(renderer.pickFrames) frames to see preview")
           
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                alert.dismiss(animated: true, completion: nil)
            }
            
        }
        
        if renderer.currentFrameIndex >= renderer.pickFrames{
            session.pause()
            
            let alert = showAlert(textTitle: "You can see the preview", textMessage: "Frames are recorded already \(renderer.currentFrameIndex) frames. You can see see preview")
            
            let scanAgainAction = UIAlertAction(title: "Scan Again", style: .default) { [self] _ in
                renderer.currentFrameIndex = 0
                // TODO: reset ARSession
                resetARSession()
                alert.dismiss(animated: true, completion: nil)
                
            }
            
            let seePreviewAction = UIAlertAction(title: "See Preview", style: .default) { [self] _ in
                toPreview()
                alert.dismiss(animated: true, completion: nil)
            }
            
            alert.addAction(scanAgainAction)
            alert.addAction(seePreviewAction)
            
        }
    }
    
    private func toPreview() {
        let storyboard = UIStoryboard(name: "Scanner", bundle: nil)
       
        guard let navigationController = self.navigationController else {
            fatalError("Current view controller is not embedded in a navigation controller.")
        }
        
        // TODO : Send MDLAssets or Frame Data to PreviewController
        if  let vc = storyboard.instantiateViewController(withIdentifier: "previewController") as? PreviewController {
            vc.delegate = self
            navigationController.pushViewController(vc, animated: true)
        }
        // TODO : Reset ARSession
        resetARSession()
        
    }
    
    private func updateIsRecording(_isRecording: Bool) {
        isRecording = _isRecording
        
        if (isRecording){
            if customButton.layer.sublayers?.contains(redCircleLayer) == true {
                // Switch to red rectangle
                redCircleLayer.removeFromSuperlayer()
                customButton.layer.addSublayer(redRectangleLayer)
            }
//            renderer.currentFolder = getTimeStr()
//            createDirectory(folder: renderer.currentFolder + "/data")
            
        } else {
            // Switch to red circle
            redRectangleLayer.removeFromSuperlayer()
            customButton.layer.addSublayer(redCircleLayer)
            renderer.getLocationProperties(long: (locationManager.location?.coordinate.longitude)!, lat: (locationManager.location?.coordinate.latitude)!, el: (locationManager.location?.altitude)!)
        }
        renderer.isRecording = isRecording
        
    }
    
    // Auto-hide the home indicator to maximize immersion in AR experiences.
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    // Hide the status bar to maximize immersion in AR experiences.
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    
    @objc
    private func viewValueChanged(view: UIView) {
        switch view {
            
        case rgbRadiusSlider:
            renderer.rgbRadius = rgbRadiusSlider.value
            
        default:
            break
        }
    }
    
    private func updateTextLabel() {
        let text = "  \(self.renderer.currentFrameIndex) of frames taken"
        DispatchQueue.main.async {
            self.textLabel.text = text
            
        }
    }
    
    // MARK: Session
    
    //Store every new anchor with the current frame image
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let cameraImage = captureCamera() else { return }
        
        anchors.forEach { anchor in 
            if anchor is ARMeshAnchor {
                self.imagesWithAnchor[anchor.identifier] = cameraImage
            }
        }
    }
        
    //In case of an anchor update, texture needs to be updated too(not sure it's necessary or not)
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let cameraImage = captureCamera() else { return }
        
        anchors.forEach { anchor in
            if anchor is ARMeshAnchor {
                self.imagesWithAnchor[anchor.identifier] = cameraImage
            }
        }
    }

    //Remove every removed anchor to free up the memory
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        anchors.forEach { anchor in
            self.imagesWithAnchor.removeValue(forKey: anchor.identifier)
        }
    }
    
    internal func captureCamera() -> UIImage? {
        guard let frame = session.currentFrame else {return nil}

        let pixelBuffer = frame.capturedImage

        let image = CIImage(cvPixelBuffer: pixelBuffer)

        let context = CIContext(options:nil)
        guard let cameraImage = context.createCGImage(image, from: image.extent) else {return nil}

        return UIImage(cgImage: cameraImage)
    }
    
    
}

    // MARK: PreviewControllerDelegate
protocol PreviewControllerDelegate: AnyObject {
//    var asset: MDLAsset { get set }
//    var image: UIImage { get set }
//    var metaString: String { get set }
    func sendARData()
    func sendExportData()
}

extension ScannerController: PreviewControllerDelegate {
//    var asset: MDLAsset {
//        get {
//            return asset
//        }
//        set {
////            code
//        }
//    }
//
    
    func sendARData() {
         let asset = renderer.generateAsset()
//        renderer.createAllTexturedMesh()
//        let nodes = renderer.testNode
        //let img = renderer.getImageForTexture()
        if let previewController = navigationController?.viewControllers.last as? PreviewController {
            previewController.getScannedAsset(nodes: asset)
            //previewController.getScannedNodes(nodes: nodes)
        }
    }
    
    func sendExportData() {
        renderer.prepareToExport()
        
//        let img = renderer.textureImage!
//        let obj = renderer.objURL!
//        let pic = renderer.picURL!
//        let txt = renderer.header
        if let previewController = navigationController?.viewControllers.last as? PreviewController {
            //previewController.updateExportData(imageTexture: img, obj: obj, pic: pic, meta: txt)
        }
    }
    
}

// update textlabel on tasks start/finish

    // MARK: TaskDelegate
extension ScannerController: TaskDelegate {
    func didStartTask() {
        self.taskNum += 1

    }
    
    func didFinishTask() {
        self.completedTaskNum += 1
    }
}

    // MARK: - MTKViewDelegate

extension ScannerController: MTKViewDelegate {
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        renderer.draw()
        renderer.imagesAndAnchor = imagesWithAnchor
        updateTextLabel()
    }
}

// MARK: - RenderDestinationProvider


protocol RenderDestinationProvider {
    var currentRenderPassDescriptor: MTLRenderPassDescriptor? { get }
    var currentDrawable: CAMetalDrawable? { get }
    var colorPixelFormat: MTLPixelFormat { get set }
    var depthStencilPixelFormat: MTLPixelFormat { get set }
    var sampleCount: Int { get set }
}

extension MTKView: RenderDestinationProvider {
    
}







