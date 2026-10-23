import AppKit
import ImageIO
import UniformTypeIdentifiers

// Product-film choreography. Native view pixels stay intact inside individual
// panes; only their entrance, the island silhouette and the mascot are animated.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let width = 1200, height = 700, fps = 50
let duration = 22.0
let scale = 1040.0 / 760.0
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func load(_ url: URL) -> CGImage {
  CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
}
let scenes = (0..<4).map { load(root.appendingPathComponent("scene-\($0).png")) }
func unit(_ x: Double) -> Double { min(1, max(0, x)) }
func ease(_ x: Double) -> Double { let t = unit(x); return t*t*t*(t*(t*6-15)+10) }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a+(b-a)*t }
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(red:r, green:g, blue:b, alpha:a)
}
func rounded(_ rect: CGRect, _ r: Double) -> CGPath {
  CGPath(roundedRect:rect, cornerWidth:r, cornerHeight:r, transform:nil)
}
func drawImage(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect, alpha: Double = 1) {
  ctx.saveGState(); ctx.setAlpha(alpha)
  ctx.translateBy(x:rect.minX, y:rect.maxY); ctx.scaleBy(x:1, y:-1)
  ctx.draw(image, in:CGRect(x:0,y:0,width:rect.width,height:rect.height))
  ctx.restoreGState()
}
func crop(_ image: CGImage, _ rect: CGRect) -> CGImage {
  let r = Double(image.width) / 760.0
  return image.cropping(to:CGRect(x:rect.minX*r, y:rect.minY*r, width:rect.width*r, height:rect.height*r))!
}
struct Pane {
  let image: CGImage
  let rect: CGRect
}
let regions: [[CGRect]] = [
  [CGRect(x:40,y:38,width:252,height:328), CGRect(x:302,y:48,width:442,height:316)],
  [CGRect(x:40,y:42,width:708,height:65), CGRect(x:40,y:113,width:708,height:65)],
  [CGRect(x:40,y:38,width:168,height:324), CGRect(x:218,y:38,width:236,height:324), CGRect(x:464,y:38,width:284,height:324)],
  [CGRect(x:40,y:40,width:708,height:20), CGRect(x:40,y:66,width:220,height:252),
   CGRect(x:272,y:66,width:220,height:252), CGRect(x:504,y:66,width:220,height:252),
   CGRect(x:384,y:325,width:20,height:12)]
]
let panes: [[Pane]] = (0..<4).map { i in regions[i].map { Pane(image:crop(scenes[i],$0), rect:$0) } }
let headers = crop(scenes[0],CGRect(x:0,y:0,width:760,height:34))
let sidebars = scenes.map { crop($0,CGRect(x:12,y:38,width:26,height:112)) }
let heights = [530.0,280.0,530.0,490.0]
let changes = [(3.0,0,1),(6.7,1,2),(11.3,2,3)]
struct Shot {
  var from: Int = 0
  var to: Int = 0
  var progress: Double = 0
  var hero: Double = 0
}
func shot(_ t: Double) -> Shot {
  var s = Shot()
  for (start,from,to) in changes {
    if t >= start && t < start+1.15 { s.from=from; s.to=to; s.progress=(t-start)/1.15 }
    else if t >= start+1.15 { s.from=to; s.to=to }
  }
  if t >= 15.5 && t < 17.3 { s.hero=ease((t-15.5)/1.8) }
  else if t >= 17.3 && t < 19.8 { s.hero=1 }
  else if t >= 19.8 { s.from=0; s.to=0; s.hero=1-ease((t-19.8)/2.2) }
  return s
}
// A blink closes faster than it opens. Two close blinks read as a small,
// considered reaction rather than the even pulse of a mechanical timer.
func blink(_ t: Double, at start: Double, length: Double = 0.25) -> Double {
  let p=(t-start)/length
  guard p >= 0 && p <= 1 else { return 1 }
  return p < 0.43 ? mix(1,0.06,ease(p/0.43)) : mix(0.06,1,ease((p-0.43)/0.57))
}
func envelope(_ t: Double, _ start: Double, _ end: Double, ramp: Double = 0.3) -> Double {
  ease((t-start)/ramp) * (1-ease((t-end)/ramp))
}
func mascot(_ ctx: CGContext, at t: Double, center: CGPoint, diameter: Double) {
  let breath=sin(2 * .pi * t / 4.4)
  let music=envelope(t,7.7,11.0)
  let beat=sin(2 * .pi * (t-7.7) / 0.68) * music
  let curious=envelope(t,17.55,18.4,ramp:0.35)
  let acknowledgement=envelope(t,18.8,19.3,ramp:0.25)
  let anticipation=changes.reduce(0.0) { $0+envelope(t,$1.0-0.48,$1.0+0.5,ramp:0.28) }
  let rotation=0.025*sin(2 * .pi * t / 11) - 0.16*curious + 0.07*acknowledgement + 0.055*beat
  let glance = -0.65*anticipation + 0.55*curious + 0.7*envelope(t,19.35,20.05)
  let look = 0.35*anticipation - 0.36*curious
  var eyeOpen=1.0
  for start in [1.1,4.65,9.4,13.6,16.9,18.45,18.78,20.7] { eyeOpen *= blink(t,at:start) }
  eyeOpen *= 1 + 0.16*acknowledgement
  let bob = 0.012*breath + 0.025*beat - 0.035*acknowledgement
  ctx.saveGState()
  ctx.translateBy(x:center.x, y:center.y+diameter*bob)
  ctx.rotate(by:rotation)
  let squash=0.012*breath+0.018*beat
  ctx.scaleBy(x:1-squash*0.4,y:1+squash)
  ctx.setFillColor(color(0.98,0.98,0.99))
  ctx.fillEllipse(in:CGRect(x:-diameter/2,y:-diameter/2,width:diameter,height:diameter))
  ctx.setFillColor(color(0.09,0.09,0.10))
  for side in [-1.0,1.0] {
    ctx.saveGState()
    ctx.translateBy(x:side*diameter*0.175+glance*diameter*0.07, y:-diameter*0.02+look*diameter*0.08)
    ctx.rotate(by:0.065+0.05*glance)
    let w=diameter*0.14, h=max(diameter*0.025,diameter*0.346*eyeOpen)
    ctx.addPath(rounded(CGRect(x:-w/2,y:-h/2,width:w,height:h),min(w,h)/2));ctx.fillPath()
    ctx.restoreGState()
  }
  ctx.restoreGState()
}
func render(_ t: Double) -> CGImage {
  let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  ctx.translateBy(x:0,y:Double(height));ctx.scaleBy(x:1,y:-1)
  NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:true)
  ctx.setFillColor(color(0.025,0.030,0.043));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
  // A single quiet pool of blue-violet light; no border, stage, badges or tabs.
  ctx.saveGState();ctx.translateBy(x:600,y:450);ctx.scaleBy(x:1,y:0.62)
  let glow=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),
    colors:[color(0.12,0.16,0.28,0.55),color(0.065,0.07,0.16,0.2),color(0.025,0.030,0.043,0)] as CFArray,
    locations:[0,0.52,1])!
  ctx.drawRadialGradient(glow,startCenter:.zero,startRadius:0,endCenter:.zero,endRadius:610,options:[])
  ctx.restoreGState()
  let s=shot(t), p=ease(s.progress)
  let h=mix(heights[s.from],heights[s.to],p)
  let product=CGRect(x:68,y:350-h/2,width:1064,height:h)
  let w=mix(product.width,116,s.hero), mh=mix(h,116,s.hero)
  let cx=mix(600,525,s.hero), cy=mix(350,345,s.hero)
  let shell=CGRect(x:cx-w/2,y:cy-mh/2,width:w,height:mh)
  let shellAlpha=1-ease((s.hero-0.8)/0.2)
  ctx.saveGState();ctx.setAlpha(shellAlpha)
  ctx.setShadow(offset:CGSize(width:0,height:25),blur:45,color:color(0,0,0,0.5))
  ctx.setFillColor(color(0,0,0));ctx.addPath(rounded(shell,mix(30,58,s.hero)));ctx.fillPath()
  ctx.restoreGState()
  let origin=CGPoint(x:80,y:product.minY+10)
  ctx.saveGState();ctx.addPath(rounded(shell,mix(30,58,s.hero)));ctx.clip()
  let contentAlpha=1-ease(s.hero/0.66)
  drawImage(ctx,headers,CGRect(x:origin.x,y:origin.y,width:1040,height:34*scale),alpha:contentAlpha)
  // Replace only the captured still face, preserving production proportions.
  ctx.setFillColor(color(0,0,0));ctx.fill(CGRect(x:origin.x+696*scale,y:origin.y,width:45*scale,height:32*scale))
  func sidebar(_ index: Int, alpha: Double) {
    drawImage(ctx,sidebars[index],CGRect(x:origin.x+12*scale,y:origin.y+38*scale,
      width:26*scale,height:112*scale),alpha:alpha*contentAlpha)
  }
  if s.from == s.to { sidebar(s.from,alpha:1) }
  else { sidebar(s.from,alpha:1-p);sidebar(s.to,alpha:p) }
  func scene(_ index: Int, incoming: Bool) {
    for (i,pane) in panes[index].enumerated() {
      var reveal=1.0, dy=0.0
      if s.from != s.to {
        let delay=Double(i)*0.045
        if incoming {
          reveal=ease((s.progress-0.20-delay)/0.64)
          dy=22*(1-reveal)
        } else {
          reveal=1-ease((s.progress-delay)/0.66)
          dy = -12*(1-reveal)
        }
      }
      let r=pane.rect
      drawImage(ctx,pane.image,CGRect(x:origin.x+r.minX*scale,y:origin.y+r.minY*scale+dy,
        width:r.width*scale,height:r.height*scale),alpha:reveal*contentAlpha)
    }
  }
  scene(s.from,incoming:false)
  if s.from != s.to { scene(s.to,incoming:true) }
  ctx.restoreGState()
  let botHeader=CGPoint(x:origin.x+718*scale,y:origin.y+15*scale)
  let flight=sin(.pi*s.hero)
  let bot=CGPoint(x:mix(botHeader.x,525,s.hero),y:mix(botHeader.y,345,s.hero)-52*flight)
  mascot(ctx,at:t,center:bot,diameter:mix(24*scale,96,s.hero))
  let brandAlpha=ease((s.hero-0.82)/0.18)
  let word=NSAttributedString(string:"Pulse",attributes:[
    .font:NSFont.systemFont(ofSize:46,weight:.light),.kern:1.2,
    .foregroundColor:NSColor.white.withAlphaComponent(0.9*brandAlpha)])
  word.draw(at:CGPoint(x:596,y:316+8*(1-brandAlpha)))
  NSGraphicsContext.restoreGraphicsState()
  return ctx.makeImage()!
}
func png(_ image: CGImage, _ url: URL) {
  let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(dest,image,nil);precondition(CGImageDestinationFinalize(dest))
}
let preview=CommandLine.arguments.contains("--preview")
let times=preview ? [0.0,3.5,5.0,8.7,12.8,16.4,17.8,18.56,19.25,20.7,21.98] : (0..<Int(duration*Double(fps))).map { Double($0)/Double(fps) }
for (frame,t) in times.enumerated() {
  autoreleasepool { png(render(t),output.appendingPathComponent(String(format:"frame-%04d.png",frame))) }
}
let ctx=CGContext(data:nil,width:2400,height:1400,bitsPerComponent:8,bytesPerRow:0,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
for (i,t) in [0.0,5.0,8.7,12.8].enumerated() {
  ctx.draw(render(t),in:CGRect(x:(i%2)*1200,y:(1-i/2)*700,width:1200,height:700))
}
png(ctx.makeImage()!,output.appendingPathComponent("pulse-overview.png"))
print("Rendered \(times.count) frames at \(fps) fps, plus a static overview.")
