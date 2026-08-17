import AppKit
import ImageIO

/// The companion's artwork, in whichever form it was supplied.
///
/// Three, in order of preference: an animated file in `Resources/Cats`, a still
/// in the asset catalogue, and the system's cat emoji. Each is a complete
/// answer on its own, so a half-finished set runs — one mood can be animated
/// while the other four are stills.
///
/// Frames are decoded once and kept. Decoding sixteen 256px frames on every
/// pass of an animation loop would cost more than the drawing does, and there
/// are at most five short loops to hold.
enum CatArtwork {

    struct Animation {
        var frames: [NSImage]
        /// Seconds to hold each frame, as the file specified them. Kept
        /// per-frame rather than averaged: a good idle loop is mostly still
        /// with a flick in it, and averaging turns that into a constant jitter.
        var delays: [Double]

        var count: Int { frames.count }
        func delay(at index: Int) -> Double { delays[index % delays.count] }
    }

    /// Extensions tried, in order. All three are read by the same decoder, and
    /// the difference that matters is alpha: GIF has one transparent colour, so
    /// a soft-edged illustration gets a hard fringe on it. APNG and HEICS keep
    /// the full channel.
    private static let extensions = ["apng", "png", "heics", "gif"]

    private static var cache: [String: Animation?] = [:]

    /// Nil when there is no animated file for this name, including when a file
    /// exists but holds a single frame — that is a still, and the still path
    /// draws it without a timer.
    static func animation(named name: String) -> Animation? {
        if let known = cache[name] { return known }
        let loaded = load(name)
        cache[name] = loaded
        return loaded
    }

    private static func load(_ name: String) -> Animation? {
        guard let url = extensions.lazy
            .compactMap({ Bundle.main.url(forResource: name, withExtension: $0, subdirectory: "Cats")
                ?? Bundle.main.url(forResource: name, withExtension: $0) })
            .first,
            let data = try? Data(contentsOf: url),
            // Created from data rather than the URL so the file is identified by
            // its contents: an APNG named `.png` is still an APNG.
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        var frames: [NSImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(NSImage(cgImage: frame, size: .zero))
            delays.append(delay(of: source, at: index))
        }
        guard frames.count > 1 else { return nil }
        return Animation(frames: frames, delays: delays)
    }

    /// A frame's own duration, from whichever dictionary the format uses.
    ///
    /// The unclamped value is preferred and then floored: files in the wild
    /// carry delays of 0 or 0.01, which browsers silently treat as 0.1, and a
    /// literal reading would spin a desktop pet at 100fps.
    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]

        func seconds(in dictionary: CFString, unclamped: CFString, clamped: CFString) -> Double? {
            guard let container = properties?[dictionary] as? [CFString: Any] else { return nil }
            return (container[unclamped] as? Double) ?? (container[clamped] as? Double)
        }

        let found = seconds(in: kCGImagePropertyGIFDictionary,
                            unclamped: kCGImagePropertyGIFUnclampedDelayTime,
                            clamped: kCGImagePropertyGIFDelayTime)
            ?? seconds(in: kCGImagePropertyPNGDictionary,
                       unclamped: kCGImagePropertyAPNGUnclampedDelayTime,
                       clamped: kCGImagePropertyAPNGDelayTime)
            ?? seconds(in: kCGImagePropertyHEICSDictionary,
                       unclamped: kCGImagePropertyHEICSUnclampedDelayTime,
                       clamped: kCGImagePropertyHEICSDelayTime)

        guard let found, found > 0.011 else { return 0.1 }
        return found
    }
}
