// Compares two reference frames pixel by pixel: `swift pngdiff.swift a.png b.png`.
// CoreImage's software renderer differs by a hair between macOS versions, so
// regenerated frames are judged with a tolerance, not byte for byte.
// Exit 0 when the mean difference is at most 0.5/255 and no channel is off by
// more than 64/255; prints the numbers either way. Across macOS 26 and 27 the
// frames differ by means of 0.001-0.03 and single pixels up to ~41 (edges);
// a real change (a moved frame, a different radius) goes far past either.
import CoreGraphics
import Foundation
import ImageIO

func pixels(_ path: String) -> (Int, Int, [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, buf) : nil
}

let args = CommandLine.arguments
guard args.count == 3, let a = pixels(args[1]), let b = pixels(args[2]) else {
    print("usage: pngdiff a.png b.png (both must be readable images)"); exit(2)
}
guard a.0 == b.0, a.1 == b.1 else { print("size differs: \(a.0)x\(a.1) vs \(b.0)x\(b.1)"); exit(1) }
var sum = 0, worst = 0
for i in 0..<a.2.count {
    let d = abs(Int(a.2[i]) - Int(b.2[i]))
    sum += d
    worst = max(worst, d)
}
let mean = Double(sum) / Double(a.2.count)
print(String(format: "mean %.3f/255, max %d/255", mean, worst))
exit(mean <= 0.5 && worst <= 64 ? 0 : 1)
