import Foundation
import ARKit

class IMUEncoder {
    let path: URL
    let fileHandle: FileHandle

    init(url: URL) {
        self.path = url
        FileManager.default.createFile(atPath: self.path.path, contents: Data("".utf8), attributes: nil)
        do {
            try "".write(to: self.path, atomically: true, encoding: .utf8)
            self.fileHandle = try FileHandle(forWritingTo: self.path)
            let heading: String = "timestamp, a_x, a_y, a_z, alpha_x, alpha_y, alpha_z\n"
            self.fileHandle.write(heading.data(using: .utf8)!)
        } catch let error {
            print("Can't create file \(self.path.path). \(error.localizedDescription)")
            preconditionFailure("Can't open IMU file for writing.")
        }
    }

    func add(timestamp: Double, linear: simd_double3, angular: simd_double3) {
        let line = "\(timestamp), \(linear.x), \(linear.y), \(linear.z), \(angular.x), \(angular.y), \(angular.z)\n"
        self.fileHandle.write(line.data(using: .utf8)!)
    }


    func done() {
        do {
            try self.fileHandle.close()
        } catch let error {
            print("Closing IMU \(self.path.path) file handle failed. \(error.localizedDescription)")
        }
    }
}
