#if canImport(CarPlay)
    import UIKit

    /// The car's pictures, drawn from the same shapes the phone uses: seven capsules, one palette.
    @MainActor
    enum SparkCarPlayArtwork {
        static let barShape: [CGFloat] = [0.3, 0.65, 0.85, 1.0, 0.85, 0.65, 0.3]
        static let canvas = CGSize(width: 220, height: 140)

        /// A still frame of the resting bars, for the idle and attention states.
        static func restingBars(tint: UIColor) -> UIImage {
            frame(tint: tint, alpha: 0.35) { shape, _ in 16 + 24 * shape }
        }

        /// The listening bars, held tall so the driver sees the microphone is open.
        static func listeningBars(tint: UIColor) -> UIImage {
            frame(tint: tint, alpha: 0.9) { shape, _ in 18 + 64 * shape }
        }

        /// The thinking bars, mid-height and calm.
        static func workingBars(tint: UIColor) -> UIImage {
            frame(tint: tint, alpha: 0.6) { shape, _ in 18 + 34 * shape }
        }

        /// The speaking animation the phone draws with a timeline, rendered as frames for the car.
        static func speakingBars(tint: UIColor, reduceMotion: Bool) -> UIImage {
            guard !reduceMotion else {
                return frame(tint: tint, alpha: 1) { shape, _ in 20 + 24 * shape }
            }
            let frames = (0..<24).map { step -> UIImage in
                let time = Double(step) / 24 * 1.6
                return frame(tint: tint, alpha: 1) { shape, index in
                    let pulse = (sin(time * 6.4 + Double(index) * 0.9) + 1) / 2
                    let swell = (sin(time * 2.3 + Double(index) * 0.35) + 1) / 2
                    return 18 + 76 * shape * CGFloat(0.2 + 0.8 * pulse * swell)
                }
            }
            return UIImage.animatedImage(with: frames, duration: 1.6) ?? frames[0]
        }

        /// A template symbol for a list row, so CarPlay tints it with the car's own style.
        static func symbol(_ name: String) -> UIImage? {
            let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
            return UIImage(systemName: name, withConfiguration: configuration)?
                .withRenderingMode(.alwaysTemplate)
        }

        private static func frame(
            tint: UIColor,
            alpha: CGFloat,
            height: (CGFloat, Int) -> CGFloat
        ) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: canvas)
            let width: CGFloat = 13
            let spacing: CGFloat = 8
            let total = CGFloat(barShape.count) * width + CGFloat(barShape.count - 1) * spacing
            let left = (canvas.width - total) / 2
            return renderer.image { context in
                tint.withAlphaComponent(alpha).setFill()
                for (index, shape) in barShape.enumerated() {
                    let barHeight = min(canvas.height, height(shape, index))
                    let x = left + CGFloat(index) * (width + spacing)
                    let rect = CGRect(
                        x: x,
                        y: (canvas.height - barHeight) / 2,
                        width: width,
                        height: barHeight
                    )
                    UIBezierPath(roundedRect: rect, cornerRadius: width / 2).fill()
                }
                _ = context
            }
        }
    }
#endif
