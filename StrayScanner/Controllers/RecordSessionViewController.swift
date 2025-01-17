//
//  RecordSessionViewController.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import Foundation
import UIKit
import Metal
import ARKit
import CoreData
import CoreMotion
import AVFoundation
//import DropDown

let FpsDividers: [Int] = [1, 2, 4, 12, 60]
let AvailableFpsSettings: [Int] = FpsDividers.map { Int(60 / $0) }
let FpsUserDefaultsKey: String = "FPS"

class MetalView : UIView {
    override class var layerClass: AnyClass {
        get {
            return CAMetalLayer.self
        }
    }
    override var layer: CAMetalLayer {
        return super.layer as! CAMetalLayer
    }
}

class RecordingState {
    static let shared = RecordingState()
    private init() {}

    var frequencyList: [Int] = Array(stride(from: 30000, through: 1000, by: -1000))
    
     var currentPhase: Phase = .pre
     var currentFrequencyIndex: Int = 0

     enum Phase {
        case pre
        case during
        case post
    }
}


class RecordSessionViewController : UIViewController, ARSessionDelegate {
    private var unsupported: Bool = false
    private var arConfiguration: ARWorldTrackingConfiguration?
    private let session = ARSession()
    private let motionManager = CMMotionManager()
    private var renderer: CameraRenderer?
    private var updateLabelTimer: Timer?
    private var startedRecording: Date?
    private var dataContext: NSManagedObjectContext!
    private var datasetEncoder: DatasetEncoder?
    private let imuOperationQueue = OperationQueue()
    private var chosenFpsSetting: Int = 0
    @IBOutlet private var rgbView: MetalView!
    @IBOutlet private var depthView: MetalView!
    @IBOutlet private var recordButton: RecordButton!
    @IBOutlet private var timeLabel: UILabel!
    @IBOutlet weak var fpsButton: UIButton!
    var dismissFunction: Optional<() -> Void> = Optional.none
    
    var audioPlayer: AVAudioPlayer?
    var attack: Bool = true
    var loadSignals: Bool = false
    

    
    
    func setDismissFunction(_ fn: Optional<() -> Void>) {
        self.dismissFunction = fn
    }
    override func viewWillAppear(_ animated: Bool) {
        self.chosenFpsSetting = UserDefaults.standard.integer(forKey: FpsUserDefaultsKey)
        updateFpsSetting()
    }

    override func viewDidLoad() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        self.dataContext = appDelegate.persistentContainer.newBackgroundContext()
        self.renderer = CameraRenderer(rgbLayer: rgbView.layer, depthLayer: depthView.layer)

        depthView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        rgbView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        
        setViewProperties()
        session.delegate = self

        recordButton.setCallback { [weak self] (recording: Bool) in
            guard let self = self else { return }
            guard recording else { return } // Ignore if button is clicked to stop
            
            let state = RecordingState.shared

            // Ensure we still have frequencies to process
            guard state.currentFrequencyIndex < state.frequencyList.count else {
                print("All frequencies have been processed.")
                return
            }

            let currentFrequency = state.frequencyList[state.currentFrequencyIndex]

            // Handle the current phase
            switch state.currentPhase {
            case .pre:
                print("Recording silence (pre) for \(currentFrequency)Hz")
                self.startRecording(freq: 0, folderName: "pre_\(currentFrequency)")
                state.currentPhase = .during // Move to the next phase

            case .during:
                print("Recording with \(currentFrequency)Hz audio")
                self.startRecording(freq: currentFrequency, folderName: "\(currentFrequency)")
                state.currentPhase = .post // Move to the next phase

            case .post:
                print("Recording silence (post) for \(currentFrequency)Hz")
                self.startRecording(freq: 0, folderName: "post_\(currentFrequency)")
                state.currentPhase = .pre // Reset to pre phase
                state.currentFrequencyIndex += 1 // Move to the next frequency
            }
        }

        fpsButton.layer.masksToBounds = true
        fpsButton.layer.cornerRadius = 12.0
        
        imuOperationQueue.qualityOfService = .userInitiated
    }

    
    private func startRecording(freq: Int, folderName: String) {
        print("Starting recording in folder: \(folderName) with freq: \(freq)")
        
        let directoryName = folderName

        if freq != 0 && attack == true {
            let attack_vector = "\(freq)Hz.wav"
            playSound(fileName: attack_vector, loop: true)
        }

        self.startedRecording = Date()
        updateTime()
        updateLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateTime()
        }
        datasetEncoder = DatasetEncoder(arConfiguration: arConfiguration!, fpsDivider: FpsDividers[chosenFpsSetting], dirName: directoryName)
//        startAccelerometer()
        startRawIMU()

        // Stop recording after 3 seconds
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            self.stopRecording()
        }
    }



    override func viewDidDisappear(_ animated: Bool) {
        session.pause();
    }

    override func viewWillDisappear(_ animated: Bool) {
        updateLabelTimer?.invalidate()
        datasetEncoder = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        startSession()
    }

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        arConfiguration = config
        if !ARWorldTrackingConfiguration.isSupported || !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("AR is not supported.")
            unsupported = true
        } else {
            config.frameSemantics.insert(.sceneDepth)
            session.run(config)
        }
        
        if loadSignals==true {
            setupAcousticSignalsFolder()
            self.loadSignals = false
        }
    }
    
//    private func startAccelerometer() {
//        if self.motionManager.isAccelerometerAvailable {
//            self.motionManager.deviceMotionUpdateInterval = 1.0 / 1200.0
//            self.motionManager.startDeviceMotionUpdates(to: imuOperationQueue, withHandler: motionHandler)
//        }
//    }
//    
//    private func stopAccelerometer() {
//        self.motionManager.stopDeviceMotionUpdates()
//    }
    
    private func startRawIMU() {
        if self.motionManager.isAccelerometerAvailable {
            self.motionManager.accelerometerUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startAccelerometerUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving accelerometer data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawAccelerometer(data: data)
            }
        } else {
            print("Accelerometer not available on this device.")
        }

        if self.motionManager.isGyroAvailable {
            self.motionManager.gyroUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startGyroUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving gyroscope data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawGyroscope(data: data)
            }
        } else {
            print("Gyroscope not available on this device.")
        }
    }

    
    private func stopRawIMU() {
        if self.motionManager.isAccelerometerActive {
            self.motionManager.stopAccelerometerUpdates()
            print("Stopped accelerometer updates.")
        }
        if self.motionManager.isGyroActive {
            self.motionManager.stopGyroUpdates()
            print("Stopped gyroscope updates.")
        }
    }

    
//    private func motionHandler(motion: CMDeviceMotion?, error: Error?) -> Void {
//        if motion != nil && datasetEncoder != nil {
//            datasetEncoder!.addIMU(motion: motion!)
//        }
//    }

    private func stopRecording() {
        guard let started = self.startedRecording else {
            print("Hasn't started recording. Something is wrong.")
            return
        }
        
        // Stop the audio if it's playing
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
            print("Audio playback stopped.")
        }
        
        startedRecording = nil
        updateLabelTimer?.invalidate()
        updateLabelTimer = nil
//      stopAccelerometer()
        
        // Stop IMU updates
        stopRawIMU()
        
        datasetEncoder?.wrapUp()
        if let encoder = datasetEncoder {
            switch encoder.status {
                case .allGood:
                    saveRecording(started, encoder)
                case .videoEncodingError:
                    showError()
                case .directoryCreationError:
                    showError()
            }
        } else {
            print("No dataset encoder. Something is wrong.")
        }
        self.dismissFunction?()
    }

    private func saveRecording(_ started: Date, _ encoder: DatasetEncoder) {
        let sessionCount = countSessions()
        
        let duration = Date().timeIntervalSince(started)
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: self.dataContext)!
        let recording: Recording = Recording(entity: entity, insertInto: self.dataContext)
        recording.setValue(datasetEncoder!.id, forKey: "id")
        recording.setValue(duration, forKey: "duration")
        recording.setValue(started, forKey: "createdAt")
        recording.setValue("Recording \(sessionCount)", forKey: "name")
        recording.setValue(datasetEncoder!.rgbFilePath.relativeString, forKey: "rgbFilePath")
        recording.setValue(datasetEncoder!.depthFilePath.relativeString, forKey: "depthFilePath")
        do {
            try self.dataContext.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }

    private func showError() {
        let controller = UIAlertController(title: "Error",
            message: "Something went wrong when encoding video. This should not have happened. You might want to file a bug report.",
            preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Default Action"), style: .default, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        }))
        self.present(controller, animated: true, completion: nil)
    }

    private func updateTime() {
        guard let started = self.startedRecording else { return }
        let seconds = Date().timeIntervalSince(started)
        let minutes: Int = Int(floor(seconds / 60).truncatingRemainder(dividingBy: 60))
        let hours: Int = Int(floor(seconds / 3600))
        let roundSeconds: Int = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        self.timeLabel.text = String(format: "%02d:%02d:%02d", hours, minutes, roundSeconds)
    }

    @objc func viewTapped() {
        switch renderer!.renderMode {
            case .depth:
                renderer!.renderMode = RenderMode.rgb
                rgbView.isHidden = false
                depthView.isHidden = true
            case .rgb:
                renderer!.renderMode = RenderMode.depth
                depthView.isHidden = false
                rgbView.isHidden = true
        }
    }
    
    @IBAction func fpsButtonTapped() {
        chosenFpsSetting = (chosenFpsSetting + 1) % AvailableFpsSettings.count
        updateFpsSetting()
        UserDefaults.standard.set(chosenFpsSetting, forKey: FpsUserDefaultsKey)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        self.renderer!.render(frame: frame)
        if startedRecording != nil {
            if let encoder = datasetEncoder {
                encoder.add(frame: frame)
            } else {
                print("There is no video encoder. That can't be good.")
            }
            
        }
    }
    

    func setupAcousticSignalsFolder() {
        let fileManager = FileManager.default

        // Get the path to the Documents directory
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Failed to find the Documents directory.")
            return
        }

        // Define the acoustic_signals folder path
        let acousticSignalsFolder = documentsDir.appendingPathComponent("acoustic_signals")

        // Create the folder if it doesn't already exist
        if !fileManager.fileExists(atPath: acousticSignalsFolder.path) {
            do {
                try fileManager.createDirectory(at: acousticSignalsFolder, withIntermediateDirectories: true, attributes: nil)
                print("Folder acoustic_signals created successfully.")
            } catch {
                print("Failed to create folder acoustic_signals: \(error.localizedDescription)")
                return
            }
        } else {
            print("Folder acoustic_signals already exists.")
        }

        // List of files to copy
        let fileNames = [
            "1000Hz.wav", "2000Hz.wav", "3000Hz.wav", "4000Hz.wav", "5000Hz.wav",
            "6000Hz.wav", "7000Hz.wav", "8000Hz.wav", "9000Hz.wav", "10000Hz.wav",
            "11000Hz.wav", "12000Hz.wav", "13000Hz.wav", "14000Hz.wav", "15000Hz.wav",
            "16000Hz.wav", "17000Hz.wav", "18000Hz.wav", "19000Hz.wav", "20000Hz.wav",
            "21000Hz.wav", "22000Hz.wav", "23000Hz.wav", "24000Hz.wav", "25000Hz.wav",
            "26000Hz.wav", "27000Hz.wav", "28000Hz.wav", "29000Hz.wav", "30000Hz.wav"
        ]


        for fileName in fileNames {
            // Get the file path in the app bundle
            if let bundlePath = Bundle.main.path(forResource: fileName, ofType: nil) {
                let destinationPath = acousticSignalsFolder.appendingPathComponent(fileName)
                do {
                    // Check if the file already exists in the acoustic_signals folder
                    if !fileManager.fileExists(atPath: destinationPath.path) {
                        try fileManager.copyItem(atPath: bundlePath, toPath: destinationPath.path)
                        print("\(fileName) copied successfully to acoustic_signals folder.")
                    } else {
                        print("\(fileName) already exists in acoustic_signals folder.")
                    }
                } catch {
                    print("Error copying \(fileName): \(error.localizedDescription)")
                }
            } else {
                print("File \(fileName) not found in the app bundle.")
            }
        }
    }
    

    

    func playSound(fileName: String, loop: Bool = false) {
        // Get the path to the file in the Documents directory
        let fileManager = FileManager.default
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Failed to find the Documents directory.")
            return
        }
        
        let filePath = documentsDir.appendingPathComponent("acoustic_signals").appendingPathComponent(fileName)
        
        // Check if the file exists
        guard fileManager.fileExists(atPath: filePath.path) else {
            print("File \(fileName) not found in the acoustic_signals folder.")
            return
        }
        
        // Try to initialize the audio player and play the sound
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: filePath)
            
            // Set the loop condition
            audioPlayer?.numberOfLoops = loop ? -1 : 0 // -1 means infinite looping
            
            audioPlayer?.play()
            print("Playing sound: \(fileName)")
        } catch {
            print("Failed to play sound \(fileName): \(error.localizedDescription)")
        }
    }


    private func setViewProperties() {
        self.view.backgroundColor = UIColor(named: "BackgroundColor")
    }
    
    private func updateFpsSetting() {
        let fps = AvailableFpsSettings[chosenFpsSetting]
        let buttonLabel: String = "\(fps) fps"
        fpsButton.setTitle(buttonLabel, for: UIControl.State.normal)
    }
    
    private func showUnsupportedAlert() {
        let alert = UIAlertController(title: "Unsupported device", message: "This device doesn't seem to have the required level of ARKit support.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            self.dismissFunction?()
        }))
        self.present(alert, animated: true)
    }
    
    private func countSessions() -> Int {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return 0 }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try appDelegate.persistentContainer.viewContext.fetch(request)
            return fetched.count
        } catch let error {
            print("Could not fetch sessions for counting. \(error.localizedDescription)")
        }
        return 0
    }
}
