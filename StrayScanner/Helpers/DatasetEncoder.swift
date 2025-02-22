

import Foundation
import ARKit
import CryptoKit
import CoreMotion

class DatasetEncoder {
    enum Status {
        case allGood
        case videoEncodingError
        case directoryCreationError
    }
    private let rgbEncoder: VideoEncoder
    private let saveRGBFramesOnly: Bool  // ✅ New flag to control RGB frame saving
    private let depthEncoder: DepthEncoder
    private let confidenceEncoder: ConfidenceEncoder
    private let datasetDirectory: URL
    private let odometryEncoder: OdometryEncoder
    private let imuEncoder: IMUEncoder
    private var lastFrame: ARFrame?
    private var dispatchGroup = DispatchGroup()
    private var currentFrame: Int = -1
    private var savedFrames: Int = 0
    private let frameInterval: Int // Only save every frameInterval-th frame.
    public let id: UUID
    public var rgbFilePath: URL // Relative to app document directory.
    public let depthFilePath: URL // Relative to app document directory.
    public let cameraMatrixPath: URL
    public let odometryPath: URL
    public let imuPath: URL
    public var status = Status.allGood
    private let queue: DispatchQueue
    
    private var latestAccelerometerData: (timestamp: Double, data: simd_double3)?
    private var latestGyroscopeData: (timestamp: Double, data: simd_double3)?


    init(arConfiguration: ARWorldTrackingConfiguration, fpsDivider: Int = 1, dirName: String) {
        self.frameInterval = fpsDivider
        self.queue = DispatchQueue(label: "encoderQueue")
        
        let width = arConfiguration.videoFormat.imageResolution.width
        let height = arConfiguration.videoFormat.imageResolution.height
        let theId: UUID = UUID()
        datasetDirectory = DatasetEncoder.createDirectory(dir: dirName)
        self.id = theId
        
        self.saveRGBFramesOnly = true
        // ✅ Set file path dynamically
        self.rgbFilePath = datasetDirectory.appendingPathComponent(".")
        if saveRGBFramesOnly {
            rgbFilePath = datasetDirectory.appendingPathComponent("rgb_frames")  // Folder for PNG frames
        } else {
            rgbFilePath = datasetDirectory.appendingPathComponent("rgb.mp4")  // Video file
        }
        self.rgbEncoder = VideoEncoder(file: rgbFilePath, width: width, height: height, saveRGBFramesOnly: saveRGBFramesOnly)

        self.depthFilePath = datasetDirectory.appendingPathComponent("depth", isDirectory: true)
        self.depthEncoder = DepthEncoder(outDirectory: self.depthFilePath)
        let confidenceFilePath = datasetDirectory.appendingPathComponent("confidence", isDirectory: true)
        self.confidenceEncoder = ConfidenceEncoder(outDirectory: confidenceFilePath)
        self.cameraMatrixPath = datasetDirectory.appendingPathComponent("camera_matrix.csv", isDirectory: false)
        self.odometryPath = datasetDirectory.appendingPathComponent("odometry.csv", isDirectory: false)
        self.odometryEncoder = OdometryEncoder(url: self.odometryPath)
        self.imuPath = datasetDirectory.appendingPathComponent("imu.csv", isDirectory: false)
        self.imuEncoder = IMUEncoder(url: self.imuPath)
    }

    func add(frame: ARFrame) {
        let totalFrames: Int = currentFrame
        let frameNumber: Int = savedFrames
        currentFrame = currentFrame + 1
        if (currentFrame % frameInterval != 0) {
            return
        }
        dispatchGroup.enter()
        queue.async {
            if let sceneDepth = frame.sceneDepth {
                self.depthEncoder.encodeFrame(frame: sceneDepth.depthMap, frameNumber: frameNumber)
                if let confidence = sceneDepth.confidenceMap {
                    self.confidenceEncoder.encodeFrame(frame: confidence, frameNumber: frameNumber)
                } else {
                    print("warning: confidence map missing.")
                }
            } else {
                print("warning: scene depth missing.")
            }
            self.rgbEncoder.add(frame: VideoEncoderInput(buffer: frame.capturedImage, time: frame.timestamp), currentFrame: totalFrames)
            self.odometryEncoder.add(frame: frame, currentFrame: frameNumber)
            self.lastFrame = frame
            self.dispatchGroup.leave()
        }
        savedFrames = savedFrames + 1
    }
    
//    func addIMU(motion: CMDeviceMotion) -> Void {
//
//        let rotationRate: simd_double3 = simd_double3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
//        let acceleration: simd_double3 = simd_double3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z)
//        let gravity: simd_double3 = simd_double3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
//        let a = (acceleration + gravity) * 9.81
//        imuEncoder.add(timestamp: motion.timestamp, linear: a, angular: rotationRate)
//    }
    
    func addRawAccelerometer(data: CMAccelerometerData) {
        let acceleration = simd_double3(data.acceleration.x, data.acceleration.y, data.acceleration.z)
        latestAccelerometerData = (timestamp: data.timestamp, data: acceleration)
        tryWritingIMUData()
    }

    func addRawGyroscope(data: CMGyroData) {
        let rotationRate = simd_double3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
        latestGyroscopeData = (timestamp: data.timestamp, data: rotationRate)
        tryWritingIMUData()
    }

    private func tryWritingIMUData() {
        guard
            let accelerometer = latestAccelerometerData,
            let gyroscope = latestGyroscopeData
        else {
            return
        }

        // Write the row to the CSV with the most recent timestamp
        let timestamp = max(accelerometer.timestamp, gyroscope.timestamp)
        imuEncoder.add(
            timestamp: timestamp,
            linear: accelerometer.data,
            angular: gyroscope.data
        )

        // Clear the buffers after writing
        latestAccelerometerData = nil
        latestGyroscopeData = nil
    }
    
    

    func wrapUp() {
        dispatchGroup.wait()
        self.rgbEncoder.finishEncoding()
        self.imuEncoder.done()
        self.odometryEncoder.done()
        writeIntrinsics()
        switch self.rgbEncoder.status {
            case .allGood:
                status = .allGood
            case .error:
                status = .videoEncodingError
        }
        switch self.depthEncoder.status {
            case .allGood:
                status = .allGood
            case .frameEncodingError:
                status = .videoEncodingError
                print("Something went wrong encoding depth.")
        }
        switch self.confidenceEncoder.status {
            case .allGood:
                status = .allGood
            case .encodingError:
                status = .videoEncodingError
                print("Something went wrong encoding confidence values.")
        }
    }

    private func writeIntrinsics() {
        if let cameraMatrix = lastFrame?.camera.intrinsics {
            let rows = cameraMatrix.transpose.columns
            var csv: [String] = []
            for row in [rows.0, rows.1, rows.2] {
                let csvLine = "\(row.x), \(row.y), \(row.z)"
                csv.append(csvLine)
            }
            let contents = csv.joined(separator: "\n")
            do {
                try contents.write(to: self.cameraMatrixPath, atomically: true, encoding: String.Encoding.utf8)
            } catch let error {
                print("Could not write camera matrix. \(error.localizedDescription)")
            }
        }
    }

    static private func createDirectory(dir: String = ".") -> URL {
        let state = RecordingState.shared
        let attemptDirName = "attempt_\(state.attemptNumber)" // Add attempt folder
        let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let attemptDir = baseDir.appendingPathComponent(attemptDirName)

        // Ensure attempt directory exists
        if !FileManager.default.fileExists(atPath: attemptDir.path) {
            do {
                try FileManager.default.createDirectory(at: attemptDir, withIntermediateDirectories: true, attributes: nil)
            } catch let error as NSError {
                print("Error creating attempt directory. \(error), \(error.userInfo)")
            }
        }

        // Append specific directory (e.g., pre_1000, 1000, post_1000)
        let specificDir = attemptDir.appendingPathComponent(dir)
        if !FileManager.default.fileExists(atPath: specificDir.path) {
            do {
                try FileManager.default.createDirectory(at: specificDir, withIntermediateDirectories: true, attributes: nil)
            } catch let error as NSError {
                print("Error creating specific directory. \(error), \(error.userInfo)")
            }
        }
        return specificDir
    }


    static private func hashUUID(id: UUID) -> String {
        var hasher: SHA256 = SHA256()
        hasher.update(data: id.uuidString.data(using: .ascii)!)
        let digest = hasher.finalize()
        var string = ""
        digest.makeIterator().prefix(5).forEach { (byte: UInt8) in
            string += String(format: "%02x", byte)
        }
        print("Hash: \(string)")
        return string
    }
}

