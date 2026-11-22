import Foundation
import ImageIO

while let line = readLine() {
    autoreleasepool {
        do {
            let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard let path = input["path"] as? String,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NSError(domain: "OCRWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось открыть кадр для распознавания."])
            }
            let region = SubtitleRegion(height: input["height"] as? Double ?? 0.3,
                                        bottom: input["bottom"] as? Double ?? 0,
                                        width: input["width"] as? Double ?? 0.92,
                                        ignoreVehiclePlates: input["ignorePlates"] as? Bool ?? true)
            let text = try SubtitleRecognition.text(in: image, region: region)
            let data = try JSONSerialization.data(withJSONObject: ["text": text])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            let data = try! JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
            print(String(decoding: data, as: UTF8.self))
        }
        fflush(stdout)
    }
}
