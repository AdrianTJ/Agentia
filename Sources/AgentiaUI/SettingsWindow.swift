import AppKit
import AgentiaCore

/// Fills View ▸ Theme, checkmarking whichever is active.
///
/// Built when the menu opens rather than at launch, so a theme changed from
/// Settings is reflected without either surface having to notify the other.
final class ThemeMenu: NSObject, NSMenuDelegate {

    private weak var controller: DocumentWindowController?

    init(controller: DocumentWindowController) {
        self.controller = controller
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let controller, !controller.availableThemes.isEmpty else {
            let empty = NSMenuItem(title: "No Themes Installed", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for theme in controller.availableThemes {
            let item = NSMenuItem(
                title: theme.name,
                action: #selector(DocumentWindowController.selectThemeFromMenu(_:)),
                keyEquivalent: "")
            item.target = controller
            item.representedObject = theme.id
            item.state = theme.id == controller.currentThemeID ? .on : .off
            menu.addItem(item)
        }
    }
}

/// The Settings window: theme and text size.
///
/// Six themes have shipped in the bundle since the beginning with no way to
/// choose one — `selectTheme(id:)` had no caller — so the app has effectively
/// been a one-theme reader. This is the surface that makes them real.
///
/// Deliberately small. A document reader has two display decisions worth
/// exposing (which typography, how big), and everything else it might offer is
/// better decided by the document or by the system.
final class SettingsWindowController: NSWindowController {

    private let themes: [Theme]
    private let onChange: (String, Double) -> Void

    private var themeList: NSPopUpButton!
    private var sizeSlider: NSSlider!
    private var sizeLabel: NSTextField!
    private var sample: NSTextField!
    private var mathCheck: NSButton!

    init(themes: [Theme], onChange: @escaping (String, Double) -> Void) {
        self.themes = themes
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = makeContent()
        window.center()
        syncFromPreferences()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func makeContent() -> NSView {
        let container = NSView()

        themeList = NSPopUpButton(frame: .zero, pullsDown: false)
        // The manifest's display name, not the id: "Manuscript", not
        // "manuscript". The id is a filename, and the reader never sees it.
        themeList.addItems(withTitles: themes.map(\.name))
        themeList.target = self
        themeList.action = #selector(themeChanged)

        sizeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1,
                              target: self, action: #selector(sizeChanged))
        // Snapped to the same steps ⌘+ and ⌘− use, so the two controls cannot
        // disagree about what sizes exist.
        sizeSlider.numberOfTickMarks = Preferences.fontScaleSteps.count
        sizeSlider.allowsTickMarkValuesOnly = true

        sizeLabel = NSTextField(labelWithString: "100%")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right

        // Shows the effect in words rather than in a number, since the number
        // is meaningless without something to compare it against.
        sample = NSTextField(labelWithString: "The quick brown fox")
        sample.textColor = .labelColor

        mathCheck = NSButton(checkboxWithTitle: "Render math ($$…$$, \\[…\\])",
                             target: self, action: #selector(mathChanged))

        let grid = NSGridView(views: [
            [label("Theme"), themeList],
            [label("Text size"), sizeRow()],
            [NSGridCell.emptyContentView, sample],
            [NSGridCell.emptyContentView, mathCheck],
        ])
        grid.rowSpacing = 18
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                           constant: -28),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 32),
            themeList.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        return container
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func sizeRow() -> NSView {
        let row = NSStackView(views: [sizeSlider, sizeLabel])
        row.orientation = .horizontal
        row.spacing = 10
        sizeSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        sizeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return row
    }

    // MARK: - State

    /// Re-read on every show, so the window cannot drift out of step with a
    /// change made from the View menu while it was closed.
    func syncFromPreferences() {
        if let index = themes.firstIndex(where: { $0.id == Preferences.themeID }) {
            themeList.selectItem(at: index)
        }
        let scale = Preferences.fontScale
        let step = Preferences.fontScaleSteps.enumerated()
            .min { abs($0.element - scale) < abs($1.element - scale) }?.offset ?? 3
        sizeSlider.doubleValue = Double(step) / Double(Preferences.fontScaleSteps.count - 1)
        mathCheck.state = Preferences.renderMath ? .on : .off
        updateSample()
    }

    private var selectedScale: Double {
        let steps = Preferences.fontScaleSteps
        let index = Int((sizeSlider.doubleValue * Double(steps.count - 1)).rounded())
        return steps[min(max(index, 0), steps.count - 1)]
    }

    private func updateSample() {
        let scale = selectedScale
        sizeLabel.stringValue = "\(Int((scale * 100).rounded()))%"
        // 17px is base.css's --size-body, the size the scale multiplies.
        sample.font = .systemFont(ofSize: 17 * scale)
    }

    @objc private func themeChanged() {
        // `indices.contains`, not `< count`: NSPopUpButton returns -1 when
        // nothing is selected, and -1 passes an upper-bound-only check and then
        // traps on the subscript.
        let index = themeList.indexOfSelectedItem
        guard themes.indices.contains(index) else { return }
        apply(themeID: themes[index].id, scale: selectedScale)
    }

    @objc private func sizeChanged() {
        updateSample()
        apply(themeID: Preferences.themeID, scale: selectedScale)
    }

    @objc private func mathChanged() {
        // Routed through apply so the document re-renders with the flag read
        // fresh at assembly time — no extra notification path needed.
        Preferences.renderMath = mathCheck.state == .on
        apply(themeID: Preferences.themeID, scale: selectedScale)
    }

    private func apply(themeID: String, scale: Double) {
        Preferences.themeID = themeID
        Preferences.fontScale = scale
        onChange(themeID, scale)
    }
}
