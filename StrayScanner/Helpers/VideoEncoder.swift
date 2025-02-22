//
//  VideoEncoder.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 12/30/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import Foundation
import ARKit

struct VideoEncoderInput {
    let buffer: CVPixelBuffer
    let time: TimeInterval // Relative to boot time.
}

class VideoEncoder {
    enum EncodingStatus {
        case allGood
        case error
    }
    
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var videoAdapter: AVAssetWriterInputPixelBufferAdaptor?
    private let timeScale = CMTimeScale(60)
    public let width: CGFloat
    public let height: CGFloat
    private let systemBootedAt: TimeInterval
    private var done: Bool = false
    private var previousFrame: Int = -1
    public var filePath: URL
    public var status: EncodingStatus = EncodingStatus.allGood
    
    private var saveRGBFramesOnly: Bool  // ✅ New flag

    init(file: URL, width: CGFloat, height: CGFloat, saveRGBFramesOnly: Bool = true) {
        self.systemBootedAt = ProcessInfo.processInfo.systemUptime
        self.filePath = file
        self.width = width
        self.height = height
        self.saveRGBFramesOnly = saveRGBFramesOnly

        if !saveRGBFramesOnly {
            initializeFile()
        }
    }

    func finishEncoding() {
        self.doneRecording()
    }

    func add(frame: VideoEncoderInput, currentFrame: Int) {
        if saveRGBFramesOnly {
            saveFrameAsPNG(frame: frame, frameNumber: currentFrame)  // ✅ Save frame as PNG instead
        } else {
            previousFrame = currentFrame
            while !videoWriterInput!.isReadyForMoreMediaData {
                print("Sleeping.")
                Thread.sleep(until: Date() + TimeInterval(0.01))
            }
            encode(frame: frame, frameNumber: currentFrame)
        }
    }

    private func initializeFile() {
        do {
            videoWriter = try AVAssetWriter(outputURL: self.filePath, fileType: .mp4)
            let settings: [String : Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: self.width,
                AVVideoHeightKey: self.height
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            input.mediaTimeScale = timeScale
            input.performsMultiPassEncodingIfSupported = false
            videoAdapter = createVideoAdapter(input)
            if videoWriter!.canAdd(input) {
                videoWriter!.add(input)
                videoWriterInput = input
                videoWriter!.startWriting()
                videoWriter!.startSession(atSourceTime: .zero)
            } else {
                print("Can't create writer.")
            }
        } catch let error as NSError {
            print("Creating AVAssetWriter failed. \(error), \(error.userInfo)")
        }
    }

    private func encode(frame: VideoEncoderInput, frameNumber: Int) {
        let image: CVPixelBuffer = frame.buffer
        let time = CMTime(value: Int64(frameNumber), timescale: timeScale)
        let success = videoAdapter!.append(image, withPresentationTime: time)
        if !success {
            print("Pixel buffer could not be appended. \(videoWriter!.error!.localizedDescription)")
        }
    }

    private func doneRecording() {
        if videoWriter?.status == .failed {
            let error = videoWriter!.error
            print("Something went wrong when writing video. \(error!.localizedDescription)")
            self.status = .error
        } else {
            videoWriterInput?.markAsFinished()
            videoWriter?.finishWriting { [weak self] in
                self?.videoWriter = nil
                self?.videoWriterInput = nil
                self?.videoAdapter = nil
            }
        }
    }

    private func createVideoAdapter(_ input: AVAssetWriterInput) -> AVAssetWriterInputPixelBufferAdaptor {
        return AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }
    
    private func saveFrameAsPNG(frame: VideoEncoderInput, frameNumber: Int) {
        let rgbFramesDir = filePath // ✅ Uses `rgb_frames/` as file path

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: rgbFramesDir.path) {
            do {
                try FileManager.default.createDirectory(at: rgbFramesDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Failed to create RGB frames directory: \(error.localizedDescription)")
                return
            }
        }

        // Convert pixel buffer to UIImage
        let uiImage = convertPixelBufferToUIImage(pixelBuffer: frame.buffer)
        let framePath = rgbFramesDir.appendingPathComponent(String(format: "%06d", frameNumber)).appendingPathExtension("png")

        // Save image as PNG
        do {
            if let pngData = uiImage.pngData() {
                try pngData.write(to: framePath)
            }
        } catch {
            print("Failed to save RGB frame \(frameNumber) as PNG: \(error.localizedDescription)")
        }
    }

    
    private func convertPixelBufferToUIImage(pixelBuffer: CVPixelBuffer) -> UIImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            return UIImage(cgImage: cgImage)
        } else {
            fatalError("Failed to convert PixelBuffer to UIImage")
        }
    }


}
