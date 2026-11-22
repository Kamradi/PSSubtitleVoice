import Foundation
import AppKit
import CoreGraphics
import Vision
setbuf(stdout, nil)

let width = 1920, height = 1080
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(NSColor.darkGray.cgColor)
context.fill(CGRect(x: 0,y: 0,width: width,height: height))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
("J26 4B7" as NSString).draw(at: NSPoint(x:900,y:65), withAttributes: [.font:NSFont.monospacedSystemFont(ofSize:24,weight:.bold), .foregroundColor:NSColor.systemRed])
("Осталось 25 секунд. Езжай быстрее!" as NSString).draw(at: NSPoint(x:500,y:135), withAttributes:[.font:NSFont.systemFont(ofSize:34,weight:.bold),.foregroundColor:NSColor.systemYellow])
("SATURDAY AUGUST 6.30PM & 8.30PM" as NSString).draw(at: NSPoint(x:850,y:245), withAttributes:[.font:NSFont.systemFont(ofSize:24,weight:.bold),.foregroundColor:NSColor.white])
NSGraphicsContext.restoreGraphicsState()
let image = context.makeImage()!
let inspection = VNRecognizeTextRequest()
inspection.usesCPUOnly = true; inspection.recognitionLevel = .accurate
inspection.recognitionLanguages = ["ru-RU", "en-US"]; inspection.usesLanguageCorrection = true
inspection.regionOfInterest = CGRect(x:0,y:0,width:1,height:0.3)
try VNImageRequestHandler(cgImage:image).perform([inspection])
for box in inspection.results ?? [] {
    let text = box.topCandidates(1).first!.string
    print("BOX",text,box.boundingBox,SubtitleTextFilter.isVehiclePlate(text,bounds:SubtitleTextFilter.frameBounds(box.boundingBox,region:inspection.regionOfInterest)))
}
let raw = try SubtitleRecognition.text(in:image,region:SubtitleRegion(height:0.3,bottom:0,width:1,ignoreVehiclePlates:false))
let filtered = try SubtitleRecognition.text(in:image,region:SubtitleRegion(height:0.3,bottom:0,width:1,ignoreVehiclePlates:true))
print("RAW:",raw)
print("FILTERED:",filtered)
precondition(raw.contains("J26"), "Fixture must contain a recognized plate")
precondition(!filtered.contains("SATURDAY"), "Poster above a subtitle must not be joined to it")
precondition(!filtered.contains("J26"), "Plate must be removed before joining dialogue")
precondition(filtered.contains("25") && filtered.contains("Езжай"), "Coloured dialogue and spoken numbers must survive")
print("PASS: real Vision OCR removes red plate and retains yellow Russian subtitle with a number")
