import AppKit
func fixture(menu: Bool) -> CGImage {
    let image = NSImage(size: NSSize(width:1280,height:720))
    image.lockFocus()
    NSColor(calibratedWhite:0.15,alpha:1).setFill()
    NSRect(x:0,y:0,width:1280,height:720).fill()
    func label(_ value:String,x:CGFloat,y:CGFloat,size:CGFloat) {
        (value as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.semibold),.foregroundColor:NSColor.white])
    }
    if menu { label("КАРТА   ЖУРНАЛ   ПРОГРЕСС",x:310,y:658,size:23) }
    else { label("Здоровье",x:30,y:658,size:23) }
    label("Лусия: Нам нужно добраться до машины.",x:230,y:66,size:25)
    image.unlockFocus()
    return image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
}
let game = fixture(menu:false), map = fixture(menu:true)
var region = SubtitleRegion(height:0.3,bottom:0,width:0.92,ignoreVehiclePlates:true,dialogueOnly:true)
let speech = try SubtitleRecognition.text(in:game,region:region)
precondition(speech.contains("добраться"),"Actual dialogue must remain: " + speech)
let blocked = try SubtitleRecognition.text(in:map,region:region)
precondition(blocked.isEmpty,"Top menu markers must suppress even a sentence-like label inside the subtitle ROI: " + blocked)
region.dialogueOnly = false
let bypass = try SubtitleRecognition.text(in:map,region:region)
precondition(bypass.contains("добраться"),"Turning filter off restores OCR behavior")
print("PASS: real Vision OCR detects top menu outside subtitle ROI; gameplay dialogue retained; opt-out works")
