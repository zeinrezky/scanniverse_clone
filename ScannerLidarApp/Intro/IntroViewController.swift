//
//  IntroViewController.swift
//  ScannerLidarApp
//
//  Created by Juli Yanti on 22/03/24.
//

import UIKit

class IntroViewController: UIViewController {
    
    @IBOutlet weak var buttonScanner: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "dirtyWhite")
        // Do any additional setup after loading the view.
        
        setupButtonConstraint()
    }
    
    func setupButtonConstraint(){
        buttonScanner.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(buttonScanner)
        NSLayoutConstraint.activate([
            // buttonScanner.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            buttonScanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttonScanner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
    }
    

    @IBAction func showAlert(_ sender: Any) {
        let storyboard = UIStoryboard(name: "Scanner", bundle: nil)
        let vc = storyboard.instantiateViewController(withIdentifier: "scannerController")
        guard let navigationController = self.navigationController else {
                fatalError("Current view controller is not embedded in a navigation controller.")
            }
        navigationController.pushViewController(vc, animated: true)
    }
    
   
}

