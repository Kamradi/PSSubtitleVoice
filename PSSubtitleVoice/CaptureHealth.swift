import CoreGraphics

// Look at the interior rather than browser chrome. A dark scene is only a warning, never a capture error.
enum CaptureHealth {
    static func isNearlyBlack(_ image: CGImage) -> Bool {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let interior = image.cropping(to: CGRect(x: Double(image.width) * 0.05,
                                                       y: Double(image.height) * 0.18,
                                                       width: Double(image.width) * 0.9,
                                                       height: Double(image.height) * 0.70)) else { return false }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(interior, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return rendered && pixels.filter { $0 < 12 }.count > pixels.count * 97 / 100
    }
}
