import AppKit
import AgentiaCore

/// How a styling role is drawn.
///
/// Kept apart from `SourceEditor` because it is the part with opinions in it —
/// sizes, weights, colours — and separating it makes those legible as choices
/// rather than as constants buried in a view.
struct EditorTypography {

    /// Base body size before the reader's text-size setting.
    static let baseSize: CGFloat = 15

    /// The column the text is laid out in, at scale 1.
    ///
    /// A measure, not the window width. Text that runs the full width of a
    /// 1600pt display is unreadable, and this is the same reason the rendered
    /// view has margins.
    static let baseMeasure: CGFloat = 720

    let scale: Double

    var size: CGFloat { EditorTypography.baseSize * CGFloat(scale) }
    var measure: CGFloat { EditorTypography.baseMeasure * CGFloat(scale) }

    /// Serif for body text, matching the rendered view.
    ///
    /// The point of this editor is that writing and reading look like the same
    /// document, so the body font is the one the reading themes use rather than
    /// the monospace font an editor would usually reach for. Code still gets a
    /// monospace face, because there the alignment carries meaning.
    var body: NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: size) else { return base }
        return serif
    }

    var monospace: NSFont {
        .monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
    }

    func heading(level: Int) -> NSFont {
        // Only h1 and h2 get a real jump. Six visually distinct heading sizes
        // means h5 and h6 differ from body text by a point, which reads as
        // inconsistency rather than hierarchy.
        let multiplier: CGFloat
        switch level {
        case 1: multiplier = 1.9
        case 2: multiplier = 1.45
        case 3: multiplier = 1.2
        default: multiplier = 1.05
        }
        let pointSize = size * multiplier
        let base = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: pointSize) else { return base }
        return serif
    }

    /// Add a trait to whatever font a range already has, rather than replacing
    /// it — so bold text inside a heading stays heading-sized.
    func adding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Line spacing is looser than a code editor's and tighter than the
    /// rendered view's.
    ///
    /// The rendered view separates paragraphs with margin, and it can: there is
    /// no blank line in the HTML. Here the blank line between two paragraphs is
    /// real text taking a real line, so adding a full paragraph's margin on top
    /// of it spaces everything twice and half the window ends up empty.
    var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        style.paragraphSpacing = size * 0.15
        return style
    }

    func headingParagraph(level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.1
        style.paragraphSpacingBefore = size * (level <= 2 ? 0.5 : 0.35)
        style.paragraphSpacing = size * 0.15
        return style
    }

    var quoteParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        style.paragraphSpacing = size * 0.15
        style.firstLineHeadIndent = size * 0.9
        style.headIndent = size * 0.9
        return style
    }

    // MARK: - Colours
    //
    // All dynamic system colours, so light and dark both work without the
    // editor knowing which one it is in.

    var text: NSColor { .labelColor }
    /// Markers — `##`, `**`, backticks. Dimmed so they recede while staying
    /// visible and editable.
    var syntax: NSColor { .tertiaryLabelColor }
    var code: NSColor { .secondaryLabelColor }
    var codeBackground: NSColor { .quaternaryLabelColor.withAlphaComponent(0.10) }
    var quote: NSColor { .secondaryLabelColor }
    var listMarker: NSColor { .tertiaryLabelColor }
    var link: NSColor { .linkColor }
}
