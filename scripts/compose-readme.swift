import AppKit
import ImageIO
import UniformTypeIdentifiers

// A deterministic 25 fps editorial composition of unmodified native UI captures.
// Pixel positions and alpha derive from time, not wall-clock capture intervals.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let iconURL = URL(fileURLWithPath: CommandLine.arguments[3])
let width = 1200, height = 760
let fps = 25, duration = 17.0
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func load(_ url: URL) -> CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)! }
let scenes = (0..<4).map { load(root.appendingPathComponent("scene-\($0).png")) }
let icon = load(iconURL)
func ease(_ x: Double) -> Double { let t = min(1,max(0,x)); return t*t*t*(t*(t*6-15)+10) }
func mix(_ a: Double,_ b: Double,_ t: Double) -> Double { a+(b-a)*t }
func color(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> CGColor { CGColor(red:r,green:g,blue:b,alpha:a) }
let white = NSColor.white
func text(_ s: String,_ x: Double,_ y: Double,_ size: Double,_ weight: NSFont.Weight = .regular,_ alpha: Double = 1,_ centered: Bool = false) {
  let attr: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:white.withAlphaComponent(alpha)]
  let line=NSAttributedString(string:s,attributes:attr)
  line.draw(at:CGPoint(x:centered ? x-line.size().width/2:x,y:y))
}
func drawImage(_ ctx: CGContext,_ image: CGImage,_ rect: CGRect,_ alpha: Double = 1) {
  ctx.saveGState();ctx.setAlpha(alpha)
  ctx.translateBy(x:rect.minX,y:rect.maxY);ctx.scaleBy(x:1,y:-1)
  ctx.draw(image,in:CGRect(x:0,y:0,width:rect.width,height:rect.height));ctx.restoreGState()
}
func rounded(_ rect: CGRect,_ r: Double) -> CGPath { CGPath(roundedRect:rect,cornerWidth:r,cornerHeight:r,transform:nil) }
let labels = ["Reminders", "Agents + quotas", "Music", "Clipboard"]
let descriptions = ["Plan the day. Make a little progress.","Keep an eye on your agents, without switching windows.","Your soundtrack, controls and lyrics within reach.","The things you copied, ready when you need them."]
let tabs = [330.0,510.0,690.0,870.0]
func render(_ t: Double) -> CGImage {
  let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x:0,y:Double(height));ctx.scaleBy(x:1,y:-1)
  NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:true)
  ctx.setFillColor(color(0.035,0.043,0.065));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
  let glow=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color(0.14,0.18,0.35,0.44),color(0.04,0.05,0.08,0)] as CFArray,locations:[0,1])!
  ctx.drawRadialGradient(glow,startCenter:CGPoint(x:600,y:410),startRadius:10,endCenter:CGPoint(x:600,y:410),endRadius:570,options:[])
  drawImage(ctx,icon,CGRect(x:44,y:29,width:34,height:34))
  text("Pulse",88,33,22,.semibold)
  text("NATIVE TO macOS",1090,39,11,.medium,0.42,true)
  text("Your day. In one little island.",600,78,39,.semibold,1,true)
  text("Reminders, agents, music and everyday tools. Always within reach.",600,132,16,.regular,0.52,true)

  var current=0,next=0,progress=0.0
  if t >= 3.6 && t < 4.4 { current=0;next=1;progress=ease((t-3.6)/0.8) }
  else if t >= 4.4 && t < 7.4 { current=1;next=1 }
  else if t >= 7.4 && t < 8.2 { current=1;next=2;progress=ease((t-7.4)/0.8) }
  else if t >= 8.2 && t < 11.2 { current=2;next=2 }
  else if t >= 11.2 && t < 12 { current=2;next=3;progress=ease((t-11.2)/0.8) }
  else if t >= 12 && t < 16.15 { current=3;next=3 }
  var expansion=1.0
  if t >= 15 && t < 15.65 { expansion=1-ease((t-15)/0.65) }
  else if t >= 15.65 && t < 16.15 { expansion=0 }
  else if t >= 16.15 { expansion=ease((t-16.15)/0.85) }
  let w=mix(340,900,expansion),h=mix(38,448,expansion)
  let rect=CGRect(x:600-w/2,y:194,width:w,height:h)
  ctx.saveGState()
  ctx.setShadow(offset:CGSize(width:0,height:18),blur:38,color:color(0,0,0,0.55))
  ctx.setFillColor(color(0,0,0));ctx.addPath(rounded(rect,mix(19,26,expansion)));ctx.fillPath();ctx.restoreGState()
  ctx.saveGState();ctx.addPath(rounded(rect,mix(19,26,expansion)));ctx.clip()
  let paneRect=CGRect(x:150,y:194,width:900,height:448)
  // Fit the 760 x 420 production surface at its native aspect ratio, cropping
  // only the unused bottom padding. Header and all feature controls stay visible.
  let nativeRect=CGRect(x:paneRect.minX,y:paneRect.minY,width:900,height:900*420/760)
  let contentAlpha=ease((expansion-0.18)/0.82)
  if current == next { drawImage(ctx,scenes[current],nativeRect,contentAlpha) }
  else {
    drawImage(ctx,scenes[current],nativeRect.offsetBy(dx:-30*progress,dy:0),(1-progress)*contentAlpha)
    drawImage(ctx,scenes[next],nativeRect.offsetBy(dx:30*(1-progress),dy:0),progress*contentAlpha)
  }
  if expansion < 1 {
    ctx.saveGState();ctx.setAlpha(1-ease(expansion/0.35))
    text("✓",452,203,17,.semibold,0.9)
    text("4 reminders",480,205,13,.medium,0.8)
    text("●",708,203,17,.medium,0.9)
    ctx.restoreGState()
  }
  ctx.restoreGState()
  ctx.setStrokeColor(color(1,1,1,0.065));ctx.setLineWidth(1);ctx.addPath(rounded(rect,mix(19,26,expansion)));ctx.strokePath()
  let selected = t >= 15 ? mix(3, 0, ease((t - 15) / 2)) : mix(Double(current),Double(next),progress)
  for i in 0..<4 {
    let focus=max(0,1-abs(selected-Double(i)))
    text(labels[i],tabs[i],677,14,.medium,mix(0.36,0.98,focus),true)
  }
  let underlineX = 330 + 180 * selected
  ctx.setFillColor(color(0.38,0.69,1));ctx.addPath(rounded(CGRect(x:underlineX-20,y:702,width:40,height:2),1));ctx.fillPath()
  if current == next { text(descriptions[current],600,650,13,.regular,0.48 * expansion,true) }
  else {
    text(descriptions[current],600-10*progress,650,13,.regular,0.48*(1-progress),true)
    text(descriptions[next],600+10*(1-progress),650,13,.regular,0.48*progress,true)
  }
  text("Actual app views · Fictional demo data",600,730,10,.regular,0.28,true)
  NSGraphicsContext.restoreGraphicsState()
  return ctx.makeImage()!
}
func png(_ image: CGImage,_ url: URL) {
  let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(dest,image,nil);precondition(CGImageDestinationFinalize(dest))
}
let count = CommandLine.arguments.contains("--preview") ? 1 : Int(duration*Double(fps))
for frame in 0..<count {
  autoreleasepool { png(render(Double(frame)/Double(fps)),output.appendingPathComponent(String(format:"frame-%04d.png",frame))) }
}
// Static companion keeps all four scenes available without motion.
let ctx=CGContext(data:nil,width:2400,height:1520,bitsPerComponent:8,bytesPerRow:0,
 space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
for (i,t) in [1.0,5.0,9.0,13.0].enumerated() { ctx.draw(render(t),in:CGRect(x:(i%2)*1200,y:(1-i/2)*760,width:1200,height:760)) }
png(ctx.makeImage()!,output.appendingPathComponent("pulse-overview.png"))
print("Rendered \(count) deterministic frames at 25 fps, plus static overview.")
