// The review model against the reference's answers (Tests/Golden/copy-paste-review.json, made by
// tools/parity/golden/copy-paste-review.ts): buildReviewRows, summarizeReview, formatReviewSummary,
// allConflictsChoicesFor, currentAllConflictsChoice and effectiveChoice over the analysis goldens' reports
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

@Suite struct CopyPasteReviewGoldenTests {
    struct Variant: Codable {
        var policy: CopyPastePolicy
        var overrides: [String: CopyPasteChoice]
        var showNewItems: Bool
    }

    struct Input: Codable {
        var report: ReviewReport
        var now: Double
        var variants: [Variant]
    }

    struct Row: Codable {
        var id: String
        var depth: Int
        var kind: String
        var name: String
        var relativePath: String
        var choice: CopyPasteChoice?
        var choices: [CopyPasteChoice]
        var keepBothName: String?
        var detail: String
        var tone: ReviewTone
        var replaceBlockedReason: String?
    }

    struct Output: Codable {
        var rows: [Row]
        var summary: ReviewSummary
        var allConflictsChoices: [AllConflictsChoice]
        var current: AllConflictsChoice?
        var effective: [String: CopyPasteChoice]
        var formatted: String
        var formattedMove: String
    }

    /// The golden's dates are Los Angeles wall times, written as en-US writes them.
    private let dates = ReviewDateText(
        locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Los_Angeles") ?? .current)

    private func conflicts(_ nodes: [ReviewNode]) -> [ReviewNode] {
        nodes.flatMap { ($0.conflictClass == nil ? [] : [$0]) + conflicts($0.children) }
    }

    // B-CLIP-092
    @Test func matchesTheReference() throws {
        let cases: [GoldenCase<Input, [Output]>] = try Golden.load(suite: "copy-paste-review")
        #expect(!cases.isEmpty)
        Golden.expectMatches(cases) { input in
            input.variants.map { variant in
                let report = input.report
                let rows = CopyPasteReview.rows(
                    report, policy: variant.policy, overrides: variant.overrides, showNewItems: variant.showNewItems,
                    now: input.now, dates: dates)
                let summary = CopyPasteReview.summarize(report, policy: variant.policy, overrides: variant.overrides)
                var effective: [String: CopyPasteChoice] = [:]
                for node in conflicts(report.nodes) {
                    effective[node.id] = CopyPasteReview.effectiveChoice(node, variant.policy, variant.overrides)
                }
                return Output(
                    rows: rows.map {
                        Row(
                            id: $0.id, depth: $0.depth, kind: $0.kind.rawValue, name: $0.name,
                            relativePath: $0.relativePath, choice: $0.choice, choices: $0.choices,
                            keepBothName: $0.keepBothName, detail: $0.detail, tone: $0.tone,
                            replaceBlockedReason: $0.replaceBlockedReason)
                    }, summary: summary, allConflictsChoices: CopyPasteReview.allConflictsChoices(report),
                    current: CopyPasteReview.currentAllConflictsChoice(report, variant.policy, variant.overrides),
                    effective: effective, formatted: CopyPasteReview.formatSummary(summary),
                    formattedMove: CopyPasteReview.formatSummary(summary, verb: "Move"))
            }
        }
    }
}
