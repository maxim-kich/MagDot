import AppKit

// The two destinations remain actual draggable Finder icons.
let size=NSSize(width:600,height:360)
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:720,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
bitmap.size=size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(calibratedWhite:0.96,alpha:1).setFill()
NSRect(origin:.zero,size:size).fill()
let arrow=NSBezierPath()
arrow.move(to:NSPoint(x:275,y:180));arrow.line(to:NSPoint(x:325,y:180))
arrow.move(to:NSPoint(x:314,y:191));arrow.line(to:NSPoint(x:325,y:180));arrow.line(to:NSPoint(x:314,y:169))
arrow.lineWidth=3;arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round
NSColor(calibratedWhite:0.5,alpha:1).setStroke();arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.tiffRepresentation!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
