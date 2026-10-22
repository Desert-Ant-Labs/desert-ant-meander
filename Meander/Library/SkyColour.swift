import CoreGraphics
import UIKit

/// The colour of the top of a photo, where the sky usually is.
enum SkyColour {
    /// Whether the top third is mostly the pink, orange, red or purple of a sunrise or sunset.
    /// Grey, blue and pale skies don't count, and neither does a dark night sky.
    static func isWarm(_ image: UIImage) -> Bool {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            // Drawn the way it is displayed, so the top of the photo is the top here.
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return false }

        var warm = 0
        let rows = side / 3
        for row in 0..<rows {
            for column in 0..<side {
                let i = (row * side + column) * 4
                let colour = UIColor(red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                     blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
                colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
                let degrees = hue * 360
                // Red, orange and gold up to 50°; pink and purple from 270°.
                let isWarmHue = degrees <= 50 || degrees >= 270
                if isWarmHue && saturation > 0.2 && brightness > 0.25 { warm += 1 }
            }
        }
        return Double(warm) / Double(rows * side) >= 0.35
    }
}
