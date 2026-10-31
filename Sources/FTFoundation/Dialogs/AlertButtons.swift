// Port of the button order and default of apps/desktop/src/renderer/components/{Alert,CopyPasteDialog,
// UndoQuestionAlert,EjectVolumeAlert}.tsx and the push button variants of components/PushButton.tsx
import Foundation

/// How a push button is drawn (`PushButtonVariant`): plain, filled with the accent as the one Return presses, or with
/// red text when it destroys something (it is then never the default).
public enum PushButtonVariant: String, Equatable, Sendable {
    case plain
    case `default`
    case destructive
}

/// One button of an alert: its title, how it is drawn, and the answer it gives.
public struct AlertButtonSpec<Answer: Equatable & Sendable>: Equatable, Sendable {
    public var title: String
    public var variant: PushButtonVariant
    public var answer: Answer

    public init(_ title: String, _ variant: PushButtonVariant = .plain, answer: Answer) {
        self.title = title
        self.variant = variant
        self.answer = answer
    }
}

/// The answer to a question asked before an action: go ahead, or not.
public enum ConfirmAnswer: Equatable, Sendable {
    case confirm, cancel
}

public enum AlertButtons {
    /// Three or more buttons are stacked, each as wide as the panel; two split the width.
    public static func isStacked(count: Int) -> Bool { count >= 3 }

    /// The button Return presses: the one drawn as the default (rightmost in a row, the top one when stacked).
    public static func defaultIndex<Answer>(_ buttons: [AlertButtonSpec<Answer>]) -> Int? {
        buttons.firstIndex { $0.variant == .default }
    }

    /// `CopyPasteDialog`'s confirmation (and `UndoQuestionAlert`'s, whose go-ahead is never red): the primary action
    /// and Cancel. A confirmation that can't be undone, or a question best answered no, makes Cancel the default, so a
    /// stray Return can't confirm it. The default is always the button on the right.
    public static func confirmation(
        _ label: String, destructive: Bool, cancelIsDefault: Bool
    ) -> [AlertButtonSpec<ConfirmAnswer>] {
        if cancelIsDefault {
            return [
                AlertButtonSpec(label, destructive ? .destructive : .plain, answer: .confirm),
                AlertButtonSpec("Cancel", .default, answer: .cancel),
            ]
        }
        return [
            AlertButtonSpec("Cancel", .plain, answer: .cancel),
            AlertButtonSpec(label, .default, answer: .confirm),
        ]
    }

    /// `ActionNoticeDialog`: one OK.
    public static let notice: [AlertButtonSpec<ConfirmAnswer>] = [AlertButtonSpec("OK", .default, answer: .confirm)]

    /// `TextPromptDialog`: Cancel, and the submit button as the default.
    public static func prompt(submitLabel: String) -> [AlertButtonSpec<ConfirmAnswer>] {
        [AlertButtonSpec("Cancel", .plain, answer: .cancel), AlertButtonSpec(submitLabel, .default, answer: .confirm)]
    }
}
