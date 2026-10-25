import AppKit

// Code-native master artwork, rendered at every macOS icon resolution.
let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat=1)->NSColor {NSColor(calibratedRed:r,green:g,blue:b,alpha:a)}
func makeIcon(_ pixels:Int)->Data {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    let context=NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.current=context
    context.cgContext.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    context.imageInterpolation = .high
    let tile=NSBezierPath(roundedRect:NSRect(x:50,y:50,width:924,height:924),xRadius:215,yRadius:215)
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow();shadow.shadowColor=color(0.08,0.01,0.16,0.4);shadow.shadowBlurRadius=24;shadow.shadowOffset=NSSize(width:0,height:-12);shadow.set()
    color(0.15,0.035,0.29).setFill();tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors:[color(0.51,0.17,0.96),color(0.28,0.045,0.57),color(0.10,0.015,0.22)])!.draw(in:tile,angle:-65)
    let inner=NSBezierPath(roundedRect:NSRect(x:67,y:67,width:890,height:890),xRadius:200,yRadius:200)
    color(0.87,0.70,1,0.22).setStroke();inner.lineWidth=3;inner.stroke()
    NSGraphicsContext.saveGraphicsState();tile.addClip()
    // Quiet orbital lines keep the mark related to the ringtone library.
    for radius:CGFloat in [290,380,470] {
        let ring=NSBezierPath(ovalIn:NSRect(x:512-radius,y:520-radius,width:radius*2,height:radius*2))
        color(0.79,0.60,1,0.10).setStroke();ring.lineWidth=2;ring.stroke()
    }
    let letter="B" as NSString
    let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:690,weight:.black),.foregroundColor:color(0.97,0.94,1)]
    let size=letter.size(withAttributes:attrs)
    let letterShadow=NSShadow();letterShadow.shadowColor=color(0.02,0,0.08,0.45);letterShadow.shadowBlurRadius=16;letterShadow.shadowOffset=NSSize(width:8,height:-15);letterShadow.set()
    letter.draw(at:NSPoint(x:(1024-size.width)/2-8,y:(1024-size.height)/2+45),withAttributes:attrs)
    NSShadow().set()
    // The ripped, high-voltage waveform is the brand signature.
    let waveform=NSBezierPath();waveform.move(to:NSPoint(x:155,y:439))
    for point in [NSPoint(x:282,y:439),NSPoint(x:322,y:491),NSPoint(x:362,y:369),NSPoint(x:423,y:592),NSPoint(x:489,y:252),NSPoint(x:559,y:680),NSPoint(x:620,y:353),NSPoint(x:668,y:487),NSPoint(x:713,y:439),NSPoint(x:871,y:439)] {waveform.line(to:point)}
    waveform.lineJoinStyle = .miter;waveform.lineCapStyle = .round
    color(0.12,0.015,0.24).setStroke();waveform.lineWidth=69;waveform.stroke()
    color(0.77,1,0.20).setStroke();waveform.lineWidth=29;waveform.stroke()
    // A small razor-cut glint at the upper right adds a little attitude.
    let glint=NSBezierPath();glint.move(to:NSPoint(x:791,y:822));glint.line(to:NSPoint(x:837,y:848));glint.line(to:NSPoint(x:811,y:802));glint.line(to:NSPoint(x:765,y:776));glint.close()
    color(0.77,1,0.20).setFill();glint.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
var chunks=Data()
for (kind,size) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)] {
    let png=makeIcon(size)
    try png.write(to:output.appendingPathComponent("icon-\(size).png"))
    chunks.append(kind.data(using:.ascii)!)
    var length=UInt32(png.count+8).bigEndian;withUnsafeBytes(of:&length){chunks.append(contentsOf:$0)}
    chunks.append(png)
}
var icns=Data("icns".utf8);var total=UInt32(chunks.count+8).bigEndian
withUnsafeBytes(of:&total){icns.append(contentsOf:$0)};icns.append(chunks)
try icns.write(to:output.appendingPathComponent("BickRipassRingtones.icns"))
