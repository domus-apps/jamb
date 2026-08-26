import Foundation

/// Prefix-free label assignment that can be handed out incrementally, as
/// scan results stream in app by app: single home-row letters first, then
/// two-letter combinations whose lead characters are never used as
/// singles — the tiers can't prefix-collide by construction, so a label
/// handed out early never becomes ambiguous when more arrive later.
enum JumpLabels {
    static let singles = Array("asdfghjkl")
    static let pairLeads = Array("qwertyuiopzxcvbnm")
    static let pairSeconds = Array("asdfghjklqwertyuiopzxcvbnm")

    /// The largest field count a session can label.
    static var capacity: Int { singles.count + pairLeads.count * pairSeconds.count }

    struct Allocator {
        private var index = 0

        mutating func next() -> String? {
            defer { index += 1 }
            if index < JumpLabels.singles.count {
                return String(JumpLabels.singles[index])
            }
            let pair = index - JumpLabels.singles.count
            guard pair < JumpLabels.pairLeads.count * JumpLabels.pairSeconds.count
            else { return nil }
            let lead = JumpLabels.pairLeads[pair / JumpLabels.pairSeconds.count]
            let second = JumpLabels.pairSeconds[pair % JumpLabels.pairSeconds.count]
            return "\(lead)\(second)"
        }
    }
}
