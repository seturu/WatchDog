import AppKit

let out = CommandLine.arguments[1]
let symbols = ["sun.max","timer","checklist","clock.arrow.circlepath","checklist.checked","gearshape",
  "shield.lefthalf.filled","testtube.2","plus","trash","chart.bar.xaxis","square.grid.2x2","globe","list.bullet",
  "bolt.fill","brain.head.profile","figure.walk","cup.and.saucer.fill","speaker.wave.2.fill","eye.fill","eye",
  "power","play.fill","pause.fill","forward.end.fill","stop.fill","lock.fill","hourglass","sum","nosign",
  "xmark.circle.fill","checkmark.circle.fill","minus.circle.fill","exclamationmark.circle.fill","clock.fill",
  "circle.dashed","sparkles","eye.slash.fill","exclamationmark.triangle.fill","wifi","battery.100percent",
  "magnifyingglass","switch.2","sidebar.left","chevron.up.chevron.down","chevron.down","moon.zzz.fill",
  "pause.circle","checkmark","xmark","arrow.right","shield.fill","doc.text","network","trash.fill",
  "terminal.fill","lock.shield.fill","person.fill","bell.fill","app.badge","cpu","externaldrive.fill",
  "rectangle.stack.fill","hand.raised.fill","arrow.uturn.backward","heart.fill","exclamationmark.octagon.fill",
  "chevron.right","gauge.with.dots.needle.33percent","calendar","stopwatch","flame.fill","leaf.fill","command",
  "brain","ellipsis","applelogo","square.and.arrow.down","hammer.fill","wrench.and.screwdriver.fill" ]
for name in symbols {
  guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { print("missing", name); continue }
  let img = base.withSymbolConfiguration(.init(pointSize: 96, weight: .regular)) ?? base
  let size = img.size
  let scale: CGFloat = 1
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width*scale), pixelsHigh: Int(size.height*scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  img.draw(in: NSRect(origin: .zero, size: size))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/sym/\(name).png"))
}
let apps = ["xcode":"/Applications/Xcode.app","brave":"/Applications/Brave Browser.app","terminal":"/System/Applications/Utilities/Terminal.app",
  "notes":"/System/Applications/Notes.app","music":"/System/Applications/Music.app","messages":"/System/Applications/Messages.app",
  "mail":"/System/Applications/Mail.app","safari":"/Applications/Safari.app","chrome":"/Applications/Google Chrome.app","firefox":"/Applications/Firefox.app"]
for (key, path) in apps {
  let icon = NSWorkspace.shared.icon(forFile: path)
  let px = 256
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: px, height: px)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/apps/\(key).png"))
}
print("done")
