/// A flag a test sets while a closure that runs on the main actor reads it. Such a closure is sendable, and a local
/// `var` it captures may not be changed after it is made.
@MainActor
public final class MainActorFlag {
    public var isSet: Bool

    public init(_ isSet: Bool = false) {
        self.isSet = isSet
    }
}
