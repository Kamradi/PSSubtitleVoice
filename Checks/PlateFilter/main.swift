import Foundation
import CoreGraphics
let small = CGRect(x: 0.45, y: 0.06, width: 0.07, height: 0.017)
for plate in ["J26 4B7", "j26 4b7", "0 | J26 4B7", "| J26 4B7", "P J26 4B7", "J26 487", "46EEK572", "А123ВС77", "А 123 ВС 777", "0 A SZ J26 4B7"] {
    precondition(SubtitleTextFilter.isVehiclePlate(plate, bounds: small), "Plate missed: \(plate)")
}
for line in ["Езжай быстрее!", "Осталось 25 секунд.", "GTA 5", "Gran Turismo 7", "WAIT 123", "UNIT 007", "FBI", "R2 L2", "T-800", "123456", "2026", "Встретимся в 12:30", "Номер J26 4B7, запомни!", "The plate is J26 4B7."] {
    precondition(!SubtitleTextFilter.isVehiclePlate(line, bounds: small), "Dialogue removed: \(line)")
}
precondition(!SubtitleTextFilter.isVehiclePlate("J26 4B7", bounds: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.06)), "Full-size subtitle code preserved")
var gate = SubtitleTracker()
func accept(_ text: String, at t: Double) -> String? { _ = gate.accept(text, at: t); return gate.accept(text, at: t+0.3) }
let boxes = [("J26 4B7",small),("Езжай быстрее!",CGRect(x:0.3,y:0.1,width:0.3,height:0.03))]
let cleaned = boxes.filter { !SubtitleTextFilter.isVehiclePlate($0.0, bounds:$0.1) }.map(\.0).joined(separator:" ")
precondition(cleaned == "Езжай быстрее!")
precondition(accept(cleaned, at:0) == "Езжай быстрее!")
precondition(accept(cleaned, at:1) == nil, "Plate removal must not break duplicate suppression")
let legacy = GameProfile(id:"legacy",name:"Game")
let data = try! JSONEncoder().encode(legacy)
precondition(try! JSONDecoder().decode(GameProfile.self,from:data).ignoreVehiclePlates == nil)
var enabled = legacy; enabled.ignoreVehiclePlates = false
let saved = try! JSONEncoder().encode(enabled)
precondition(try! JSONDecoder().decode(GameProfile.self,from:saved).ignoreVehiclePlates == false)
print("PASS: observed plate and OCR variants removed; dialogue, numbers and large text retained; repeats and old profiles preserved")

let split = [SubtitleTextFilter.Line(text:"J26",bounds:CGRect(x:0.45,y:0.06,width:0.025,height:0.016)),
             SubtitleTextFilter.Line(text:"4B7",bounds:CGRect(x:0.49,y:0.06,width:0.025,height:0.016)),
             SubtitleTextFilter.Line(text:"Езжай быстрее!",bounds:CGRect(x:0.3,y:0.13,width:0.35,height:0.03))]
precondition(SubtitleTextFilter.filter(split,enabled:true).map(\.text) == ["Езжай быстрее!"], "Split plate boxes removed without touching subtitle above")
precondition(SubtitleTextFilter.filter(split,enabled:false).count == 3, "Off switch preserves original OCR")
let distant = [split[0],SubtitleTextFilter.Line(text:"4B7",bounds:CGRect(x:0.8,y:0.06,width:0.025,height:0.016))]
precondition(SubtitleTextFilter.filter(distant,enabled:true).count == 2, "Do not join unrelated distant codes")
let differentRows = [split[0],SubtitleTextFilter.Line(text:"4B7",bounds:CGRect(x:0.49,y:0.13,width:0.025,height:0.016))]
precondition(SubtitleTextFilter.filter(differentRows,enabled:true).count == 2, "Do not join separate subtitle rows")
print("PASS: split plate, separate dialogue, off switch, and unrelated boxes")

for source in ["J26 4B7 Возьмите напитки в баре.", "Возьмите напитки в баре. J26 4B7", "P J26 4B7 Возьмите напитки в баре."] {
    precondition(SubtitleTextFilter.cleanEdges(source) == "Возьмите напитки в баре.", "Strip plate merged with dialogue: " + source)
}
precondition(SubtitleTextFilter.cleanEdges("J26 4B7").isEmpty)
for source in ["Номер машины J26 4B7, запомни!", "The plate is J26 4B7.", "Осталось 25 секунд.", "AT 1234 PM", "Gran Turismo 7"] {
    precondition(SubtitleTextFilter.cleanEdges(source) == source, "Preserve spoken context: " + source)
}
print("PASS: joined plate edges removed; explicit spoken plate references and normal numbers preserved")

let plateWithHeader = [SubtitleTextFilter.Line(text:"LEONIDA",bounds:CGRect(x:0.45,y:0.078,width:0.065,height:0.009)),
                       SubtitleTextFilter.Line(text:"78",bounds:CGRect(x:0.44,y:0.074,width:0.012,height:0.007)),
                       SubtitleTextFilter.Line(text:"J26 4B7",bounds:small),
                       SubtitleTextFilter.Line(text:"Войдите в «Ржавый якорь».",bounds:CGRect(x:0.3,y:0.02,width:0.38,height:0.027))]
precondition(SubtitleTextFilter.filter(plateWithHeader,enabled:true).map(\.text) == ["Войдите в «Ржавый якорь»."], "Plate header and tiny marks removed; real subtitle kept")
let farHeader = SubtitleTextFilter.Line(text:"LEONIDA",bounds:CGRect(x:0.1,y:0.15,width:0.1,height:0.022))
precondition(SubtitleTextFilter.filter([farHeader,plateWithHeader[2]],enabled:true).map(\.text) == ["LEONIDA"], "Names elsewhere in the image must survive")
print("PASS: plate header/marks excluded by proximity; subtitle and unrelated names retained")

let tinyMarks = [SubtitleTextFilter.Line(text:"78 \" LEONIDA *",bounds:CGRect(x:0.45,y:0.08,width:0.07,height:0.009)),
                 SubtitleTextFilter.Line(text:"NO",bounds:CGRect(x:0.3,y:0.02,width:0.03,height:0.011)),
                 SubtitleTextFilter.Line(text:"Да",bounds:CGRect(x:0.4,y:0.02,width:0.03,height:0.011)),
                 SubtitleTextFilter.Line(text:"LEONIDA",bounds:CGRect(x:0.1,y:0.15,width:0.1,height:0.025))]
precondition(SubtitleTextFilter.filter(tinyMarks,enabled:true).map(\.text) == ["NO","Да","LEONIDA"], "Tiny plate marks ignored even when the plate is obscured; real text retained")
print("PASS: obscured plate's tiny marks excluded; short and full-size dialogue retained")
