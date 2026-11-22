import CoreGraphics
func image(gray: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 100, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    return context.makeImage()!
}
precondition(CaptureHealth.isNearlyBlack(image(gray: 0)))
precondition(!CaptureHealth.isNearlyBlack(image(gray: 0.5)))
print("PASS: blank capture warning and visible capture distinction")
