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

    /// Ensures enough space on current page (starts new page if needed), draws text with wrapping, returns final y.
    private static func ensureSpaceAndDrawWrapped(
        _ text: String,
        at verticalPosition: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        context: UIGraphicsPDFRendererContext
    ) -> CGFloat {
        let string = text as NSString
        let constraint = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let rect = string.boundingRect(with: constraint, options: options, attributes: attributes, context: nil)
        let neededHeight = ceil(rect.height)
        var drawY = verticalPosition
        if drawY + neededHeight > maxYBeforeNewPage {
            context.beginPage()
            drawY = margin
        }
        let drawRect = CGRect(x: margin, y: drawY, width: contentWidth, height: neededHeight)
        string.draw(in: drawRect, withAttributes: attributes)
        return drawY + neededHeight
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
