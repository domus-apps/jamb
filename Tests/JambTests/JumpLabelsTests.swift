import Testing

@testable import Jamb

private func allocate(_ count: Int) -> [String] {
    var allocator = JumpLabels.Allocator()
    return (0..<count).compactMap { _ in allocator.next() }
}

@Test func firstLabelsAreHomeRowSingles() {
    #expect(allocate(9) == ["a", "s", "d", "f", "g", "h", "j", "k", "l"])
}

@Test func overflowMovesToTwoLetterPairs() {
    let labels = allocate(12)
    #expect(labels[9] == "qa")
    #expect(labels[10] == "qs")
    #expect(labels.suffix(3).allSatisfy { $0.count == 2 })
}

@Test func allocationIsPrefixFreeAcrossTiers() {
    /* Singles come from a different letter set than pair leads, so no
       label can be a prefix of another — the invariant that makes
       incremental allocation safe. Verify directly over a large run. */
    let labels = allocate(300)
    #expect(Set(labels).count == labels.count)
    for label in labels {
        #expect(!labels.contains { $0 != label && $0.hasPrefix(label) })
    }
}

@Test func allocatorExhaustsAtCapacity() {
    var allocator = JumpLabels.Allocator()
    for _ in 0..<JumpLabels.capacity {
        #expect(allocator.next() != nil)
    }
    #expect(allocator.next() == nil)
}
