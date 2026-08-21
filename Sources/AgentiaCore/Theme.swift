import Foundation

/// A reading and print theme, loaded from a folder on disk.
///
/// A theme is data, not code: a manifest plus two stylesheets. Adding one means
/// dropping a folder next to the others, which is also how a user installs
/// their own.
public struct Theme: Sendable, Identifiable, Equatable {

    public struct Fonts: Codable, Sendable, Equatable {
        public let body: String
        public let heading: String
        public let mono: String
    }

    public struct Page: Codable, Sendable, Equatable {
        /// A CSS page size keyword or dimensions, e.g. `"Letter"` or `"A4"`.
        public let size: String
        /// A CSS length, e.g. `"1in"`.
        public let margin: String
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let order: Int
        public let description: String
        public let prefersDarkAppearance: Bool
        public let fonts: Fonts
        /// Families the theme is designed around. Absent families fall back to
        /// system faces, so this is advisory — used to tell the user which
        /// optional fonts would improve the result.
        public let requiredFonts: [String]
        public let page: Page
    }

    public let manifest: Manifest
    /// Screen stylesheet followed by the print stylesheet, in that order.
    public let css: String

    public var id: String { manifest.id }
    public var name: String { manifest.name }

    public init(manifest: Manifest, css: String) {
        self.manifest = manifest
        self.css = css
    }
}

/// Loads themes from a directory of theme folders.
public struct ThemeStore: Sendable {

    public enum Error: Swift.Error, Equatable {
        case directoryUnreadable(URL)
        case themeNotFound(String)
        case manifestInvalid(id: String, underlying: String)
        case noThemesAvailable
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The themes bundled with the app.
    public static func bundled() throws -> ThemeStore {
        guard let url = ResourceBundle.themesDirectory else {
            throw Error.noThemesAvailable
        }
        return ThemeStore(directory: url)
    }

    /// Every readable theme, in manifest `order`.
    ///
    /// A theme whose manifest fails to parse is skipped rather than failing the
    /// whole load: one bad user-installed folder should not cost you the other
    /// five.
    public func loadAll() throws -> [Theme] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw Error.directoryUnreadable(directory)
        }

        var themes: [Theme] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            if let theme = try? load(at: entry) {
                themes.append(theme)
            }
        }

        guard !themes.isEmpty else { throw Error.noThemesAvailable }
        return themes.sorted {
            ($0.manifest.order, $0.id) < ($1.manifest.order, $1.id)
        }
    }

    private func load(at folder: URL) throws -> Theme {
        let id = folder.lastPathComponent

        let manifestURL = folder.appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw Error.themeNotFound(id)
        }

        let manifest: Theme.Manifest
        do {
            manifest = try JSONDecoder().decode(Theme.Manifest.self, from: data)
        } catch {
            throw Error.manifestInvalid(id: id, underlying: String(describing: error))
        }

        // Stylesheets are optional individually — a theme may define only
        // screen rules — but the pair is concatenated in a fixed order so
        // print rules always win where they overlap.
        let screen = (try? String(contentsOf: folder.appendingPathComponent("screen.css"),
                                  encoding: .utf8)) ?? ""
        let print = (try? String(contentsOf: folder.appendingPathComponent("print.css"),
                                 encoding: .utf8)) ?? ""

        return Theme(manifest: manifest, css: screen + "\n" + print)
    }
}
