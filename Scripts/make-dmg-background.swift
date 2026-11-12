import AppKit

// 生成 DMG 安装窗口的背景：浅灰底 + 指向 Applications 的箭头。
// 输出 1x/2x PNG，再由 package.sh 合成 HiDPI tiff。

let canvas = CGSize(width: 600, height: 400)
let arrowCenterY = 190.0      // 与 package.sh 里的图标 y 坐标保持一致
let arrowStartX = 252.0
let arrowEndX = 350.0

func render(scale: CGFloat) -> CGImage? {
    let pixelWidth = Int(canvas.width * scale)
    let pixelHeight = Int(canvas.height * scale)
    guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    context.setFillColor(CGColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1))
    context.fill(CGRect(origin: .zero, size: canvas))

    // CoreGraphics 原点在左下，Finder 图标坐标原点在左上
    let y = canvas.height - arrowCenterY
    let arrow = CGColor(srgbRed: 0.541, green: 0.541, blue: 0.557, alpha: 1)
    let headLength = 16.0
    let headHalfHeight = 9.0

    context.setStrokeColor(arrow)
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: arrowStartX, y: y))
    context.addLine(to: CGPoint(x: arrowEndX - headLength, y: y))
    context.strokePath()

    context.setFillColor(arrow)
    context.move(to: CGPoint(x: arrowEndX, y: y))
    context.addLine(to: CGPoint(x: arrowEndX - headLength, y: y + headHalfHeight))
    context.addLine(to: CGPoint(x: arrowEndX - headLength, y: y - headHalfHeight))
    context.closePath()
    context.fillPath()

    return context.makeImage()
}

func write(_ image: CGImage, to path: String) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "WindowSwitch.DMGBackground", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    guard let image = render(scale: scale) else {
        FileHandle.standardError.write(Data("Could not render \(name)\n".utf8))
        exit(1)
    }
    try write(image, to: "\(outputDirectory)/\(name)")
}
