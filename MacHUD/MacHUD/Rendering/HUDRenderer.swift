import AppKit
import CoreImage
import CoreText
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Everything that determines what the HUD looks like. If two scenes are equal, the
/// rendered frames are identical, so we can skip rendering and sending.
struct HUDScene: Equatable {
    enum Content: Equatable {
        /// `progress` is 0...1, or nil when the track has no known duration (streams).
        case track(title: String, artist: String, isPlaying: Bool,
                   progress: Double?, artworkID: String?)
        case clock(time: String, date: String, minute: Int, battery: BatteryInfo?, weather: WeatherChip?,
                   wallpaperID: String?, subtitle: String)
        case weather(WeatherCard)
        case notification(NotificationCard)
    }
    var content: Content
    /// Horizontal scroll (px) of the title / artist when they are too long to fit.
    /// Only used for lines that overflow; see `HUDRenderer.marqueeLoopLengths`.
    var titleScroll: CGFloat = 0
    var artistScroll: CGFloat = 0
    /// Artwork size: 1 while playing, `pausedArtScale` while paused, animated in between
    /// (like Music's play/pause spring). Also drives the ring's dimming.
    var artScale: CGFloat = 1

    static let pausedArtScale: CGFloat = 0.84

    /// The scene minus the moving parts (progress ring, scrolling text, play/pause scale).
    /// When this changes, the frame cross-fades; changes to the moving parts just move them.
    var withoutProgress: HUDScene {
        switch content {
        case let .track(title, artist, _, progress, artID):
            return HUDScene(content: .track(title: title, artist: artist, isPlaying: false,
                                            progress: progress == nil ? nil : 0, artworkID: artID))
        default:
            return self
        }
    }
}

/// Draws 240x240 HUD frames with Core Graphics and encodes them as JPEG.
final class HUDRenderer {
    static let size = 240
    private let S = CGFloat(HUDRenderer.size)
    private var c: CGFloat { S / 2 }
    /// Text must stay inside this radius (the progress ring lives outside it).
    private let safeRadius: CGFloat = 104
    private let ringRadius: CGFloat = 113
    private let ringWidth: CGFloat = 6

    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    private let artistFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
    /// Space between the end of scrolling text and its repeated copy.
    private let marqueeGap: CGFloat = 40
    /// Width of the soft fade at the edges of scrolling text.
    private let marqueeFade: CGFloat = 14

    // Cache of processed artwork for the current track.
    private var cachedArtID: String?
    private var cachedBackground: CGImage?
    private var cachedThumb: CGImage?
    private var cachedAccent: CGColor = CGColor(red: 1, green: 0.27, blue: 0.4, alpha: 1)

    // MARK: - Public

    func render(_ scene: HUDScene, artwork: CGImage?) -> CGImage? {
        guard let ctx = makeContext() else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldSmoothFonts(false)
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

        switch scene.content {
        case let .track(title, artist, _, progress, artID):   // play state is drawn via `artScale`
            prepareArtwork(id: artID, image: artwork)
            drawTrack(ctx, title: title, artist: artist, artScale: scene.artScale,
                      progress: progress, hasArt: artID != nil,
                      titleScroll: scene.titleScroll, artistScroll: scene.artistScroll)
        case let .clock(time, date, minute, battery, weather, wallpaperID, subtitle):
            // `artwork` carries the wallpaper image on the dashboard.
            prepareWallpaper(id: wallpaperID, image: artwork)
            drawClock(ctx, time: time, date: date, minute: minute, battery: battery, weather: weather,
                      hasWallpaper: wallpaperID != nil, subtitle: subtitle)
        case let .weather(card):
            drawWeather(ctx, card)
        case let .notification(card):
            drawNotification(ctx, card, icon: artwork)   // `artwork` carries the app icon here
        }
        return ctx.makeImage()
    }

    /// For each line that is too wide to fit, the distance (px) after which its scrolling
    /// loop repeats: text width plus the gap before the repeated copy. nil = fits, no scrolling.
    func marqueeLoopLengths(title: String, artist: String) -> (title: CGFloat?, artist: CGFloat?) {
        let layout = trackLayout(showArtist: !artist.isEmpty)
        func loop(_ text: String, _ font: NSFont, _ baseline: CGFloat) -> CGFloat? {
            let width = textWidth(text, font: font)
            return width > lineLimit(font: font, baseline: top(baseline)) ? width + marqueeGap : nil
        }
        return (loop(displayTitle(title), titleFont, layout.titleBaseline),
                artist.isEmpty ? nil : loop(artist, artistFont, layout.artistBaseline))
    }

    /// Blend two frames: `t` = 0 shows `from`, 1 shows `to`.
    func crossfade(from: CGImage, to: CGImage, t: CGFloat) -> CGImage? {
        guard let ctx = makeContext() else { return nil }
        let rect = CGRect(x: 0, y: 0, width: S, height: S)
        ctx.draw(from, in: rect)
        ctx.setAlpha(min(max(t, 0), 1))
        ctx.draw(to, in: rect)
        return ctx.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: CGFloat = 0.93) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        // Baseline (non-progressive) JPEG. The ESP32 decoder (TJpgDec) needs that.
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Track screen

    private func drawTrack(_ ctx: CGContext, title: String, artist: String, artScale: CGFloat,
                           progress: Double?, hasArt: Bool, titleScroll: CGFloat, artistScroll: CGFloat) {
        // Background
        if hasArt, let bg = cachedBackground {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: 0, y: 0, width: S, height: S))
            ctx.clip()
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: S, height: S))
            ctx.restoreGState()
        } else {
            drawRadialBackground(ctx, inner: CGColor(gray: 0.16, alpha: 1), outer: CGColor(gray: 0.04, alpha: 1))
        }

        // Artwork (top): rounded square with Apple's continuous ("squircle") corners.
        let showArtist = !artist.isEmpty
        let layout = trackLayout(showArtist: showArtist)
        // 0 = fully paused look, 1 = fully playing (can overshoot slightly with the spring).
        let playAmount = (artScale - HUDScene.pausedArtScale) / (1 - HUDScene.pausedArtScale)
        let side = layout.side * artScale
        let artCenterY = top(layout.blockTop + side / 2)
        let artRect = CGRect(x: c - side / 2, y: artCenterY - side / 2, width: side, height: side)
        let artPath = RoundedRectangle(cornerRadius: side * 0.13, style: .continuous).path(in: artRect).cgPath
        ctx.saveGState()
        // Bigger, deeper shadow while playing, as if the artwork is lifted off the background.
        let lift = min(max(playAmount, 0), 1.2)
        ctx.setShadow(offset: CGSize(width: 0, height: -(1 + 3 * lift)), blur: 4 + 10 * lift,
                      color: CGColor(gray: 0, alpha: 0.35 + 0.3 * min(lift, 1)))
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.addPath(artPath)
        ctx.fillPath()
        ctx.restoreGState()
        if hasArt, let thumb = cachedThumb {
            ctx.saveGState()
            ctx.addPath(artPath)
            ctx.clip()
            ctx.draw(thumb, in: artRect)
            ctx.restoreGState()
        } else {
            drawNote(ctx, center: CGPoint(x: c, y: artCenterY), size: 44 * artScale)
        }
        ctx.saveGState()
        ctx.addPath(artPath)
        ctx.clip()
        ctx.addPath(artPath)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        ctx.setLineWidth(2)   // clipped to the inside, so 1 px visible
        ctx.strokePath()
        ctx.restoreGState()

        // Text: centred if it fits, otherwise scrolling.
        drawLine(ctx, displayTitle(title), font: titleFont, color: CGColor(gray: 1, alpha: 1),
                 baseline: top(layout.titleBaseline), scroll: titleScroll)
        if showArtist {
            drawLine(ctx, artist, font: artistFont, color: CGColor(gray: 1, alpha: 0.78),
                     baseline: top(layout.artistBaseline), scroll: artistScroll)
        }

        // Progress ring
        ctx.setLineCap(.round)
        ctx.setLineWidth(ringWidth)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        ctx.addArc(center: CGPoint(x: c, y: c), radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        if let progress {
            let p = CGFloat(min(max(progress, 0), 1))
            if p > 0 {
                let start = CGFloat.pi / 2
                let ringAlpha = 0.55 + 0.45 * min(max(playAmount, 0), 1)
                ctx.setStrokeColor(cachedAccent.copy(alpha: ringAlpha)!)
                ctx.addArc(center: CGPoint(x: c, y: c), radius: ringRadius,
                           startAngle: start, endAngle: start - p * 2 * .pi, clockwise: true)
                ctx.strokePath()
            }
        }
    }

    /// Layout of the track screen: artwork, title and artist form one block, centred
    /// vertically in the circle. Text is measured by cap height (top of the letters) to its
    /// baseline, so the gaps you see are the gaps specified. All values measured from the top.
    private func trackLayout(showArtist: Bool) -> (side: CGFloat, blockTop: CGFloat,
                                                    titleBaseline: CGFloat, artistBaseline: CGFloat) {
        let side: CGFloat = 100
        let artToTitle: CGFloat = 14      // artwork bottom -> title cap top
        let titleToArtist: CGFloat = 9    // title baseline -> artist cap top
        let opticalLift: CGFloat = 2      // nudge up slightly; true centre looks low
        let blockHeight = side + artToTitle + titleFont.capHeight
            + (showArtist ? titleToArtist + artistFont.capHeight : 0)
        let blockTop = (S - blockHeight) / 2 - opticalLift
        let titleBaseline = blockTop + side + artToTitle + titleFont.capHeight
        let artistBaseline = titleBaseline + titleToArtist + artistFont.capHeight
        return (side, blockTop, titleBaseline, artistBaseline)
    }

    private func displayTitle(_ title: String) -> String { title.isEmpty ? "Unknown Title" : title }

    private func textAttributes(_ font: NSFont, _ color: CGColor) -> [NSAttributedString.Key: Any] {
        [NSAttributedString.Key(kCTFontAttributeName as String): font,
         NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: textAttributes(font, .white)))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Usable width for a line of `font` with its baseline at `baseline` (Core Graphics coords).
    private func lineLimit(font: NSFont, baseline: CGFloat) -> CGFloat {
        safeWidth(lineTop: baseline + font.ascender, lineBottom: baseline + font.descender)
    }

    /// Draws a line centred if it fits; otherwise as a marquee scrolled by `scroll` px.
    private func drawLine(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor,
                          baseline: CGFloat, scroll: CGFloat) {
        let limit = lineLimit(font: font, baseline: baseline)
        let width = textWidth(text, font: font)
        guard width > limit, limit > 10 else {
            drawCenteredText(ctx, text, font: font, color: color, baseline: baseline)
            return
        }

        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: textAttributes(font, color)))
        let loop = width + marqueeGap
        let offset = scroll.truncatingRemainder(dividingBy: loop)
        let x0 = c - limit / 2
        let box = CGRect(x: x0, y: baseline + font.descender - 3,
                         width: limit, height: font.ascender - font.descender + 6)

        ctx.saveGState()
        ctx.clip(to: box)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.textMatrix = .identity
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.7))
        for copy in 0..<2 {
            ctx.textPosition = CGPoint(x: x0 - offset + CGFloat(copy) * loop, y: baseline)
            CTLineDraw(line, ctx)
        }
        // Soft edges: keep the text where the mask is opaque. The left edge fades in as the
        // text starts moving and out again as the next copy arrives, so the first letters
        // are crisp while it rests.
        let leftFade = min(min(offset, loop - offset) / marqueeFade, 1)
        let f = marqueeFade / limit
        if let mask = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(gray: 0, alpha: 1 - leftFade), CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0),
        ] as CFArray, locations: [0, f, 1 - f, 1]) {
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(mask, start: CGPoint(x: box.minX, y: 0), end: CGPoint(x: box.maxX, y: 0), options: [])
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawNote(_ ctx: CGContext, center: CGPoint, size: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: .regular)
        drawCenteredText(ctx, "♪", font: font, color: CGColor(gray: 1, alpha: 0.7), centerY: center.y, maxWidth: 60)
    }

    // MARK: - Apple-style design tokens (dashboard + weather)

    /// SF Pro Rounded, the design Apple uses for numerals on Watch faces.
    private func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    /// SF Pro in its compressed width (narrow, tall numerals), as on the iOS lock screen clock.
    private func condensed(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let d = base.fontDescriptor.addingAttributes([.traits: [
            NSFontDescriptor.TraitKey.width: -0.3, NSFontDescriptor.TraitKey.weight: weight.rawValue,
        ]])
        return NSFont(descriptor: d, size: size) ?? base
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    // Apple system colours (dark appearance)
    private var appleOrange: CGColor { rgb(255, 159, 10) }
    private var appleGreen: CGColor { rgb(48, 209, 88) }
    private var appleRed: CGColor { rgb(255, 69, 58) }
    private var appleYellow: CGColor { rgb(255, 214, 10) }

    // MARK: - Clock screen (watch-face style)

    private func drawClock(_ ctx: CGContext, time: String, date: String, minute: Int,
                           battery: BatteryInfo?, weather: WeatherChip?, hasWallpaper: Bool, subtitle: String) {
        if hasWallpaper, let wallpaper = cachedWallpaper {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: 0, y: 0, width: S, height: S))
            ctx.clip()
            ctx.draw(wallpaper, in: CGRect(x: 0, y: 0, width: S, height: S))
            ctx.restoreGState()
        } else {
            ctx.setFillColor(.black)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: S, height: S))
        }

        // Date, in the accent colour, small caps style.
        drawCenteredText(ctx, date.uppercased(), font: rounded(13, .semibold), color: appleOrange,
                         centerY: top(46))

        // Time: big rounded numerals with a small AM/PM beside them.
        // Tall, narrow numerals like the iOS lock screen clock: SF's compressed width, stretched a bit vertically.
        let timeFont = condensed(92, .medium)
        let stretch: CGFloat = 1.22
        var digits = time, suffix = ""
        if let space = time.lastIndex(where: { $0 == " " || $0 == "\u{202F}" }),
           !time[time.index(after: space)...].contains(where: \.isNumber) {
            digits = String(time[..<space])
            suffix = String(time[time.index(after: space)...])
        }
        let suffixFont = rounded(14, .semibold)   // AM/PM
        let digitsW = textWidth(digits, font: timeFont)
        let suffixW = suffix.isEmpty ? 0 : textWidth(suffix, font: suffixFont) + 4
        let startX = c - (digitsW + suffixW) / 2
        // Baseline so the stretched digits are centred on y = 101 (measured from the top).
        let timeBaseline = top(101) - timeFont.capHeight * stretch / 2
        ctx.saveGState()
        ctx.translateBy(x: 0, y: timeBaseline)
        ctx.scaleBy(x: 1, y: stretch)
        ctx.translateBy(x: 0, y: -timeBaseline)
        drawCenteredText(ctx, digits, font: timeFont, color: .white, baseline: timeBaseline,
                         centerX: startX + digitsW / 2)
        ctx.restoreGState()
        if !suffix.isEmpty {
            drawCenteredText(ctx, suffix, font: suffixFont, color: CGColor(gray: 1, alpha: 0.6),
                             baseline: timeBaseline, centerX: startX + digitsW + 4 + (suffixW - 4) / 2)
        }

        // Complications: circular gauges along the bottom, like a watch face.
        var gauges = [Int]()   // 0 = battery, 1 = weather
        if battery != nil { gauges.append(0) }
        if weather != nil { gauges.append(1) }
        let d: CGFloat = 50, gap: CGFloat = 12
        let total = CGFloat(gauges.count) * d + CGFloat(max(gauges.count - 1, 0)) * gap
        for (i, kind) in gauges.enumerated() {
            let center = CGPoint(x: c - total / 2 + d / 2 + CGFloat(i) * (d + gap), y: top(177))
            if kind == 0, let battery { drawBatteryGauge(ctx, battery, center: center, diameter: d) }
            if kind == 1, let weather { drawWeatherGauge(ctx, weather, center: center, diameter: d) }
        }

        if !subtitle.isEmpty {
            drawCenteredText(ctx, subtitle, font: rounded(11.5, .medium), color: CGColor(gray: 1, alpha: 0.5),
                             centerY: top(gauges.isEmpty ? 172 : 213))
        }
    }

    /// A circular gauge: dim track plus a coloured arc from 12 o'clock, `fraction` of the way round.
    /// With `notch`, a small gap is cut out of the ring at 12 o'clock to make room for an indicator.
    private func drawGaugeRing(_ ctx: CGContext, center: CGPoint, diameter: CGFloat, fraction: CGFloat,
                               color: CGColor, notch: Bool = false) {
        let radius = diameter / 2 - 2.5
        // Dark backing disc: keeps the gauge crisp and readable over a busy wallpaper.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))

        ctx.saveGState()
        if notch {
            let hole = CGRect(x: center.x - 9.5, y: center.y + radius - 9.5, width: 19, height: 19)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: S, height: S))
            path.addEllipse(in: hole)
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(4.5)
        ctx.setStrokeColor(color.copy(alpha: 0.24)!)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        let f = min(max(fraction, 0), 1)
        if f > 0 {
            ctx.setStrokeColor(color)
            ctx.addArc(center: center, radius: radius, startAngle: .pi / 2,
                       endAngle: .pi / 2 - f * 2 * .pi, clockwise: true)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Battery gauge in the style of the iOS Batteries widget: a large centred percentage, and while
    /// charging a lightning bolt sitting on the ring at 12 o'clock.
    private func drawBatteryGauge(_ ctx: CGContext, _ b: BatteryInfo, center: CGPoint, diameter: CGFloat) {
        let tint = b.charging ? appleGreen : (b.percent <= 10 ? appleRed : (b.percent <= 20 ? appleYellow : appleGreen))
        drawGaugeRing(ctx, center: center, diameter: diameter, fraction: CGFloat(b.percent) / 100,
                      color: tint, notch: b.charging)

        // Digits centred by their real height (cap height), so they sit in the exact middle.
        let font = rounded(b.percent >= 100 ? 15 : 21, .semibold)
        drawCenteredText(ctx, "\(b.percent)", font: font, color: .white,
                         baseline: center.y - font.capHeight / 2, centerX: center.x)

        if b.charging {
            let p = CGPoint(x: center.x, y: center.y + diameter / 2 - 2.5)   // on the ring, at 12 o'clock
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.scaleBy(x: 1.3, y: 1.3)
            ctx.translateBy(x: -p.x, y: -p.y)
            ctx.setFillColor(tint)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: p.x + 2.4, y: p.y + 6.5))
            ctx.addLine(to: CGPoint(x: p.x - 3.8, y: p.y - 0.6))
            ctx.addLine(to: CGPoint(x: p.x - 0.4, y: p.y - 0.6))
            ctx.addLine(to: CGPoint(x: p.x - 2.4, y: p.y - 6.5))
            ctx.addLine(to: CGPoint(x: p.x + 3.8, y: p.y + 0.6))
            ctx.addLine(to: CGPoint(x: p.x + 0.4, y: p.y + 0.6))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func drawWeatherGauge(_ ctx: CGContext, _ chip: WeatherChip, center: CGPoint, diameter: CGFloat) {
        drawGaugeRing(ctx, center: center, diameter: diameter, fraction: 1, color: rgb(10, 132, 255))
        drawSymbol(ctx, chip.symbol, size: 19, center: CGPoint(x: center.x, y: center.y + 7), shadow: false)
        drawCenteredText(ctx, "\(chip.temperature)°", font: rounded(12.5, .semibold), color: .white,
                         centerY: center.y - 9, centerX: center.x)
    }

    // MARK: - Notification screen

    private func drawNotification(_ ctx: CGContext, _ card: NotificationCard, icon: CGImage?) {
        drawRadialBackground(ctx, inner: CGColor(gray: 0.20, alpha: 1), outer: CGColor(gray: 0.03, alpha: 1))

        // The sending app's icon, drawn as-is (app icons already have their own shape). With no icon
        // found, a plain white bell. No tile or shadow behind either.
        let side: CGFloat = 66
        let rect = CGRect(x: c - side / 2, y: top(58) - side / 2, width: side, height: side)
        if let icon {
            ctx.draw(icon, in: rect)
        } else {
            drawSymbol(ctx, "bell.fill", size: 44, center: CGPoint(x: c, y: top(58)), shadow: false, white: true)
        }

        var y: CGFloat = 104
        if !card.appName.isEmpty {
            drawCenteredText(ctx, card.appName.uppercased(), font: rounded(11, .semibold),
                             color: CGColor(gray: 1, alpha: 0.55), centerY: top(y))
            y += 21
        } else {
            y += 4
        }
        if card.body.isEmpty {
            // No body: the title may use two lines.
            drawWrapped(ctx, card.title, font: titleFont, color: .white,
                        firstBaseline: top(y) - (titleFont.ascender + titleFont.descender) / 2,
                        lineHeight: 21, maxLines: 2)
        } else {
            drawCenteredText(ctx, card.title, font: titleFont, color: .white, centerY: top(y))
            let bodyFont = NSFont.systemFont(ofSize: 14, weight: .regular)
            drawWrapped(ctx, card.body, font: bodyFont, color: CGColor(gray: 1, alpha: 0.78),
                        firstBaseline: top(y + 24) - (bodyFont.ascender + bodyFont.descender) / 2,
                        lineHeight: 17, maxLines: 3)
        }
    }

    /// Draws centred text wrapped at word boundaries inside the circle, ending in "…" if cut off.
    private func drawWrapped(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor,
                             firstBaseline: CGFloat, lineHeight: CGFloat, maxLines: Int) {
        let attributed = NSAttributedString(string: text, attributes: textAttributes(font, color))
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = attributed.string as NSString
        var start = 0
        for i in 0..<maxLines {
            while start < ns.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: start)) ?? "x") {
                start += 1
            }
            guard start < ns.length else { return }
            let baseline = firstBaseline - CGFloat(i) * lineHeight
            let limit = lineLimit(font: font, baseline: baseline)
            guard limit > 30 else { return }
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(limit))
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            if i == maxLines - 1, start + count < ns.length {
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: ns.length - start))
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: textAttributes(font, color)))
                line = CTLineCreateTruncatedLine(rest, Double(limit), .end, token) ?? line
            }
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.7))
            ctx.textPosition = CGPoint(x: c - width / 2, y: baseline)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            start += count
        }
    }

    // MARK: - Weather screen (Apple Weather style)

    /// SF Symbol rendered to a bitmap (multicolour where the symbol defines colours). Cached.
    private var symbolCache: [String: CGImage] = [:]
    private func symbol(_ name: String, size: CGFloat, white: Bool = false) -> CGImage? {
        let key = "\(name)@\(size)\(white ? "w" : "")"
        if let hit = symbolCache[key] { return hit }
        let base = NSImage.SymbolConfiguration(pointSize: size * 2, weight: .regular)
        let config = white ? base.applying(.init(paletteColors: [.white])) : base.applying(.preferringMulticolor())
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        symbolCache[key] = cg
        return cg
    }

    /// Draws `name` aspect-fit into a `size` square centred at `center`.
    private func drawSymbol(_ ctx: CGContext, _ name: String, size: CGFloat, center: CGPoint,
                            shadow: Bool = true, white: Bool = false) {
        guard let img = symbol(name, size: size, white: white) else { return }
        let scale = min(size / CGFloat(img.width), size / CGFloat(img.height))
        let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(gray: 0, alpha: 0.3)) }
        ctx.draw(img, in: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    /// Sky gradient stops from the top of the screen to the bottom, after Apple Weather's backdrops.
    /// The clear-night one is measured from the Weather app itself (navy at the top to a dusty
    /// mauve glow at the bottom); the others are estimates in the same style.
    private func weatherSky(_ theme: WeatherTheme) -> [(color: CGColor, at: CGFloat)] {
        switch theme {
        case .clearNight: return [(rgb(32, 63, 99), 0), (rgb(81, 91, 127), 0.5), (rgb(154, 131, 135), 1)]
        case .clearDay: return [(rgb(41, 112, 200), 0), (rgb(104, 170, 236), 1)]
        case .cloudy: return [(rgb(84, 100, 122), 0), (rgb(142, 158, 178), 1)]
        case .rain: return [(rgb(48, 60, 78), 0), (rgb(96, 112, 132), 1)]
        case .snow: return [(rgb(112, 130, 152), 0), (rgb(186, 200, 216), 1)]
        case .storm: return [(rgb(34, 32, 58), 0), (rgb(86, 82, 120), 1)]
        case .fog: return [(rgb(122, 128, 136), 0), (rgb(176, 180, 186), 1)]
        }
    }

    /// A few faint stars in the upper sky (fixed positions, so frames don't flicker).
    private func drawStars(_ ctx: CGContext) {
        let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)] = [
            (62, 36, 1.1, 0.7), (98, 22, 0.8, 0.5), (150, 30, 1.0, 0.65), (186, 52, 0.8, 0.5),
            (44, 74, 0.9, 0.55), (196, 88, 1.1, 0.7), (78, 58, 0.7, 0.4), (166, 70, 0.7, 0.45),
            (124, 14, 0.8, 0.5), (34, 112, 0.8, 0.4), (210, 124, 0.8, 0.4), (108, 46, 0.7, 0.35),
        ]
        for st in stars {
            ctx.setFillColor(CGColor(gray: 1, alpha: st.a))
            ctx.fillEllipse(in: CGRect(x: st.x - st.r, y: top(st.y) - st.r, width: st.r * 2, height: st.r * 2))
        }
    }

    private func drawWeather(_ ctx: CGContext, _ card: WeatherCard) {
        let sky = weatherSky(card.theme)
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 0, y: 0, width: S, height: S))
        ctx.clip()
        if let g = CGGradient(colorsSpace: colorSpace, colors: sky.map(\.color) as CFArray,
                              locations: sky.map(\.at)) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
        }
        if card.theme == .clearNight { drawStars(ctx) }
        // soft highlight near the top, like a sky glow
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [CGColor(gray: 1, alpha: 0.14), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: S), startRadius: 0,
                                   endCenter: CGPoint(x: c, y: S), endRadius: 150, options: [])
        }
        ctx.restoreGState()

        let white = CGColor(gray: 1, alpha: 1)

        // One block, centred in the circle. Every gap is measured between the visible tops and
        // bottoms of the glyphs (cap heights), so the spacing looks even whatever the text says.
        let cityFont = NSFont.systemFont(ofSize: 20, weight: .medium)
        let tempFont = NSFont.systemFont(ofSize: 82, weight: .thin)
        let degreeFont = NSFont.systemFont(ofSize: 46, weight: .thin)
        let condFont = NSFont.systemFont(ofSize: 18, weight: .medium)
        let rangeFont = NSFont.systemFont(ofSize: 17, weight: .medium)
        let icon: CGFloat = 22
        let hasCity = !card.place.isEmpty

        let gapCityTemp: CGFloat = 11, gapTempCond: CGFloat = 12, gapCondRange: CGFloat = 9
        let condRow = max(icon, condFont.capHeight)
        let blockHeight = (hasCity ? cityFont.capHeight + gapCityTemp : 0) + tempFont.capHeight
            + gapTempCond + condRow + gapCondRange + rangeFont.capHeight
        let blockTop = (S - blockHeight) / 2 - 2          // measured from the top; slight optical lift

        var y = blockTop                                   // top of the next element
        if hasCity {
            y += cityFont.capHeight
            drawCenteredText(ctx, card.place, font: cityFont, color: white, baseline: top(y), centerX: c)
            y += gapCityTemp
        }

        // Temperature: large and thin, with the degree sign hanging off the digits like Apple Weather.
        y += tempFont.capHeight
        let tempBaseline = top(y)
        let digits = "\(card.temperature)"
        let digitsW = textWidth(digits, font: tempFont), degreeW = textWidth("°", font: degreeFont)
        drawCenteredText(ctx, digits, font: tempFont, color: white, baseline: tempBaseline, centerX: c)
        drawCenteredText(ctx, "°", font: degreeFont, color: white,
                         baseline: tempBaseline + tempFont.capHeight - degreeFont.capHeight,
                         centerX: c + digitsW / 2 + degreeW / 2 - 4)

        // Condition: small symbol + text, vertically centred on one row.
        y += gapTempCond
        let rowCenter = y + condRow / 2
        let condW = textWidth(card.condition, font: condFont)
        let gap: CGFloat = 6
        let cx0 = c - (icon + gap + condW) / 2
        drawSymbol(ctx, card.symbol, size: icon, center: CGPoint(x: cx0 + icon / 2, y: top(rowCenter)), shadow: false)
        drawCenteredText(ctx, card.condition, font: condFont, color: white,
                         baseline: top(rowCenter + condFont.capHeight / 2), centerX: cx0 + icon + gap + condW / 2)
        y += condRow

        // High / low.
        y += gapCondRange + rangeFont.capHeight
        drawCenteredText(ctx, "H:\(card.high)°  L:\(card.low)°", font: rangeFont,
                         color: CGColor(gray: 1, alpha: 0.85), baseline: top(y), centerX: c)
    }

    // MARK: - Helpers

    /// Converts a y coordinate measured from the top to Core Graphics' bottom-up space.
    private func top(_ y: CGFloat) -> CGFloat { S - y }

    private func drawRadialBackground(_ ctx: CGContext, inner: CGColor, outer: CGColor) {
        guard let g = CGGradient(colorsSpace: colorSpace, colors: [inner, outer] as CFArray, locations: [0, 1])
        else { return }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 0, y: 0, width: S, height: S))
        ctx.clip()
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c + 30), startRadius: 0,
                               endCenter: CGPoint(x: c, y: c), endRadius: c, options: .drawsAfterEndLocation)
        ctx.restoreGState()
    }

    /// Width available for a line spanning `lineBottom...lineTop` (Core Graphics coords)
    /// while staying inside the safe circle.
    private func safeWidth(lineTop: CGFloat, lineBottom: CGFloat) -> CGFloat {
        let dy = max(abs(lineTop - c), abs(lineBottom - c))
        guard dy < safeRadius else { return 0 }
        return 2 * sqrt(safeRadius * safeRadius - dy * dy) - 8
    }

    /// Draws text vertically centred on `centerY` (by its ascender/descender box).
    private func drawCenteredText(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor,
                                  centerY: CGFloat, centerX: CGFloat? = nil, maxWidth: CGFloat? = nil) {
        let baseline = centerY - (font.ascender + font.descender) / 2
        drawCenteredText(ctx, text, font: font, color: color, baseline: baseline,
                         centerX: centerX, maxWidth: maxWidth)
    }

    /// Draws text horizontally centred with its baseline at `baseline` (Core Graphics coords),
    /// truncated with "…" to fit inside the safe circle.
    private func drawCenteredText(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor,
                                  baseline: CGFloat, centerX: CGFloat? = nil, maxWidth: CGFloat? = nil) {
        let attrs = textAttributes(font, color)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let limit = maxWidth ?? lineLimit(font: font, baseline: baseline)
        guard limit > 10 else { return }

        var drawLine = line
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(limit) {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            drawLine = CTLineCreateTruncatedLine(line, Double(limit), .end, token) ?? line
        }
        let width = CGFloat(CTLineGetTypographicBounds(drawLine, nil, nil, nil))

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.7))
        ctx.textPosition = CGPoint(x: (centerX ?? c) - width / 2, y: baseline)
        CTLineDraw(drawLine, ctx)
        ctx.restoreGState()
    }

    // MARK: - Wallpaper (dashboard background)

    private var cachedWallpaperID: String?
    private var cachedWallpaper: CGImage?

    /// Blurs and darkens the wallpaper once per picture so the time and gauges stay readable.
    private func prepareWallpaper(id: String?, image: CGImage?) {
        guard id != cachedWallpaperID else { return }
        cachedWallpaperID = id
        cachedWallpaper = nil
        guard id != nil, let image, let filled = scaled(image, to: Self.size) else { return }

        let base = CIImage(cgImage: filled)
        let blurred = base.clampedToExtent()
            .applyingGaussianBlur(sigma: 3)
            .cropped(to: base.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15, kCIInputBrightnessKey: -0.04])
        guard let blurredCG = ciContext.createCGImage(blurred, from: base.extent),
              let ctx = makeContext() else { return }
        let rect = CGRect(x: 0, y: 0, width: S, height: S)
        ctx.draw(blurredCG, in: rect)
        // Darker for bright wallpapers, lighter for dark ones, so white text always reads.
        let darkness = 0.22 + 0.36 * averageLuminance(of: blurred, extent: base.extent)
        ctx.setFillColor(CGColor(gray: 0, alpha: darkness))
        ctx.fill(rect)
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.35)] as CFArray,
                              locations: [0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0,
                                   endCenter: CGPoint(x: c, y: c), endRadius: c, options: [])
        }
        cachedWallpaper = ctx.makeImage()
    }

    /// Average brightness of an image, 0 (black) to 1 (white).
    private func averageLuminance(of image: CIImage, extent: CGRect) -> CGFloat {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: colorSpace)
        return (0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2])) / 255
    }

    // MARK: - Artwork processing (cached per track)

    private func prepareArtwork(id: String?, image: CGImage?) {
        guard id != cachedArtID else { return }
        cachedArtID = id
        cachedBackground = nil
        cachedThumb = nil
        cachedAccent = CGColor(red: 1, green: 0.27, blue: 0.4, alpha: 1)
        guard id != nil, let image else { return }

        cachedThumb = scaled(image, to: 224)

        // Blurred + darkened background.
        let base = CIImage(cgImage: scaled(image, to: Self.size) ?? image)
        let blurred = base.clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .cropped(to: base.extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.06, kCIInputSaturationKey: 1.2,
            ])
        if let blurredCG = ciContext.createCGImage(blurred, from: base.extent),
           let ctx = makeContext() {
            let rect = CGRect(x: 0, y: 0, width: S, height: S)
            ctx.draw(blurredCG, in: rect)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
            ctx.fill(rect)
            // Vignette so the edge (ring) and the text area read well.
            if let g = CGGradient(colorsSpace: colorSpace,
                                  colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.4)] as CFArray,
                                  locations: [0.55, 1]) {
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0,
                                       endCenter: CGPoint(x: c, y: c), endRadius: c, options: [])
            }
            cachedBackground = ctx.makeImage()
        }

        cachedAccent = accentColor(from: base) ?? cachedAccent
    }

    private func makeContext(side: Int = HUDRenderer.size) -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// Aspect-fill scale to a square of `side` pixels.
    private func scaled(_ image: CGImage, to side: Int) -> CGImage? {
        guard let ctx = makeContext(side: side) else { return nil }
        ctx.interpolationQuality = .high
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = CGFloat(side) / min(w, h)
        let dw = w * scale, dh = h * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - dw) / 2, y: (CGFloat(side) - dh) / 2, width: dw, height: dh))
        return ctx.makeImage()
    }

    /// Average colour of the artwork, pushed to a bright, saturated variant for the ring.
    private func accentColor(from image: CIImage) -> CGColor? {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: colorSpace)
        let ns = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
        if sat < 0.12 { return CGColor(gray: 0.92, alpha: 1) }   // greyscale art -> white ring
        return NSColor(hue: hue, saturation: max(sat, 0.55), brightness: max(bri, 0.92), alpha: 1).cgColor
    }
}
