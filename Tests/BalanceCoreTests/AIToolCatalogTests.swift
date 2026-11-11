import Foundation
import BalanceCore

struct AIToolCatalogTests {
    func testCatalogKeepsUserChoicesSeparateFromServiceIdentifiers() {
        let presets = AIToolCatalog.presets
        expectEqual(Set(presets.map(\.id)).count, presets.count)
        expectEqual(presets.map(\.name), ["Codex", "Claude", "WorkBuddy", "千问办公", "豆包办公", "Grok Bot", "Muse", "其他 AI 工具"])
        expectEqual(presets.last?.id, "other")
        // Merely showing a product must not create an enabled provider or route it to
        // another product's credentials. Persisted service IDs remain unchanged.
        expectEqual(presets.compactMap(\.builtinService), [.codex, .grok])
        expectEqual(ServiceID.allCases, [.foxcode, .codex, .grok])
        for preset in presets where preset.builtinService == nil {
            expectNil(ServiceID(rawValue: preset.id))
        }
    }

    func testNativeMappingDoesNotConflateProductNamesAndQuotaSources() {
        let codex = AIToolCatalog.presets.first { $0.id == "codex" }
        let grok = AIToolCatalog.presets.first { $0.id == "grok-bot" }
        let muse = AIToolCatalog.presets.first { $0.id == "muse" }
        expectEqual(codex?.builtinService, .codex)
        expectEqual(grok?.builtinService, .grok)
        expectNil(muse?.builtinService)
        expectTrue(grok?.detail.contains("Cursor") == true)
        expectTrue(muse?.detail.contains("Meta Personal Agent") == true)
    }
}
