/// Explicit menu destinations, independent of the last selected display or sidebar section.
public struct SettingsNavigation: Equatable, Sendable {
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case displays, arrange, scenes, appPresets, health, about
        public var id: String { rawValue }
    }
    public enum DisplayFocus: String, Hashable, Sendable {
        case resolution, colour
    }
    public var section: Section = .displays
    public private(set) var displayID: String?
    public private(set) var displayFocus: DisplayFocus?
    public private(set) var revision: UInt64 = 0

    public init() {}

    public mutating func open(_ section: Section) {
        self.section = section
        displayFocus = nil
        revision &+= 1
    }

    public mutating func openDisplay(_ id: String, focus: DisplayFocus) {
        section = .displays
        displayID = id
        displayFocus = focus
        revision &+= 1
    }
}
