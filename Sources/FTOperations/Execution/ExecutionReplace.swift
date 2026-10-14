// Port of the call to executeReplace (packages/core/src/fs/copyPasteExecution.ts); the Replace itself is P3-04's
import Foundation

/// What a Replace refuses with until it is ported.
let replaceNotYetAvailableMessage = "Replacing an item is not yet available."

/// Replace, without ever leaving the person with neither item: the new item is first written (or, for a move on
/// the same volume, moved) to a hidden name next to the existing one, then the existing item goes to the Trash
/// and the new one takes its name. `destination` is what is there now, `source` the item being pasted as the
/// check just before saw it.
func executeReplace(
    _ context: ExecutionContext, _ currentNode: ResolvedCopyPasteNode, _ destination: NodeFingerprint,
    _ source: NodeFingerprint
) throws -> ExecuteNodeResult {
    throw OperationError(replaceNotYetAvailableMessage)
}
