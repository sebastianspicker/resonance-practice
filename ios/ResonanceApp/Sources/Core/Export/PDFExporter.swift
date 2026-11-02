import Foundation
import UIKit

// Renders a course-scoped practice summary into an exportable PDF document.

struct PDFExporter {
    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 24
    private static let contentWidth: CGFloat = pageWidth - 2 * margin
    private static let maxYBeforeNewPage: CGFloat = 720

    static func export(entries: [LocalPracticeEntry], to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        try renderer.writePDF(to: url, withActions: { context in
            context.beginPage()
            var verticalPosition: CGFloat = margin
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 18)
            ]
            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12)
            ]

            "Resonance Export".draw(at: CGPoint(x: margin, y: verticalPosition), withAttributes: titleAttributes)
            verticalPosition += 28

            for entry in entries {
                let dateStr = entry.practiceDate.formatted(date: .abbreviated, time: .shortened)
                let goalSafe = sanitizeForPDF(entry.goalText)
                let line = "\(dateStr) - \(goalSafe)"

                verticalPosition = ensureSpaceAndDrawWrapped(
                    line, at: verticalPosition, attributes: bodyAttributes, context: context)
                verticalPosition += 6

                if let notes = entry.notes, !notes.isEmpty {
                    let notesSafe = sanitizeForPDF(notes)
                    verticalPosition = ensureSpaceAndDrawWrapped(
                        notesSafe, at: verticalPosition, attributes: bodyAttributes, context: context)
                    verticalPosition += 6
                }
                verticalPosition += 10
            }
        })
    }

    /// Draws wrapped text from the given y, continuing on new pages when a block is taller than the space left; returns final y.
    private static func ensureSpaceAndDrawWrapped(
        _ text: String,
        at verticalPosition: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        context: UIGraphicsPDFRendererContext
    ) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: attributes)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let lineHeight = ((attributes[.font] as? UIFont)?.lineHeight ?? 16).rounded(.up)
        var drawY = verticalPosition
        var location = 0
        while location < storage.length {
            if maxYBeforeNewPage - drawY < lineHeight {
                context.beginPage()
                drawY = margin
            }
            // Each container takes the glyphs that fit its page; the layout manager continues in the next one.
            let container = NSTextContainer(size: CGSize(width: contentWidth, height: maxYBeforeNewPage - drawY))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            guard glyphs.length > 0 else {
                // Nothing fit in the rest of this page: continue on a fresh page, stop only if even that fails.
                if drawY == margin { break }
                context.beginPage()
                drawY = margin
                continue
            }
            layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: margin, y: drawY))
            drawY += ceil(layout.usedRect(for: container).height)
            location = NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        return drawY
    }

    static func sanitizeForPDF(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withSpaces = trimmed.replacingOccurrences(of: "\n", with: " ")
        var result = ""
        for scalar in withSpaces.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                result.append(" ")
            } else {
                result.append(Character(scalar))
            }
        }
        return result
    }
}
