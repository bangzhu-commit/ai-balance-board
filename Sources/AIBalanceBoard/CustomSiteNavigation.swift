import SwiftUI
import BalanceCore

struct CustomSiteEditorRequest: Identifiable {
    let id = UUID()
    let record: CustomSiteRecord?
    var seedName = ""
    var kind: CustomConnectionKind = .aiTool
}

struct CustomSiteFocus: Equatable {
    // A new request also relocates a connection whose configuration was edited again.
    let requestID = UUID()
    let siteID: UUID
}

struct CustomSiteFocusPreferenceKey: PreferenceKey {
    static var defaultValue: CustomSiteFocus? { nil }
    static func reduce(value: inout CustomSiteFocus?, nextValue: () -> CustomSiteFocus?) {
        if let next = nextValue() { value = next }
    }
}

@MainActor
final class CustomSitesState: ObservableObject {
    @Published var editor: CustomSiteEditorRequest?
    @Published var expandedSiteID: UUID?
    private var savedSiteID: UUID?

    func editorSaved(_ id: UUID) { savedSiteID = id }

    func editorDismissed() -> UUID? {
        guard let id = savedSiteID else { return nil }
        savedSiteID = nil
        expandedSiteID = id
        return id
    }
}

@MainActor
final class SetupNavigation: ObservableObject {
    @Published var step: Int
    @Published private(set) var customSiteFocus: CustomSiteFocus?

    init(step: Int) { self.step = step }

    func continueWithCustomSite(_ id: UUID) {
        step = 1
        customSiteFocus = CustomSiteFocus(siteID: id)
    }
}
