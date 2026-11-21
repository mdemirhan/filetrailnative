/// Make Alias and Show Original: what they are called and what they say.
public enum MakeAlias {
    public static let commandLabel = "Make Alias"
    public static let showOriginalLabel = "Show Original"

    /// The name of an alias of an item named `name`, as Finder names one: the whole name, its extension included, then
    /// " alias" ("Report.pdf alias"). One taken is numbered after it ("Report.pdf alias 2").
    public static func name(for name: String) -> String { "\(name) alias" }

    /// "Stopped after 2 items were …".
    public static let stoppedDone = "given an alias"
}
