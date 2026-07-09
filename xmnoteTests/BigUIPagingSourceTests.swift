import Testing
@testable import xmnote

private struct BigUIPagingCollidingValue: Hashable {
    let id: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(0)
    }
}

struct BigUIPagingSourceTests {
    @Test
    func typeErasedValuesCompareWrappedValuesBeyondHashValue() {
        let first = PageViewStyleConfiguration.Value(BigUIPagingCollidingValue(id: 1))
        let second = PageViewStyleConfiguration.Value(BigUIPagingCollidingValue(id: 2))

        #expect(first != second)
    }

    @Test
    func adjacencyResolverReadsLatestCollectionStateWithoutStaleCache() {
        var ids = [1, 2]
        let resolver = PageViewAdjacencyResolver<Int>(
            next: { value in
                guard let index = ids.firstIndex(of: value) else { return nil }
                let nextIndex = ids.index(after: index)
                return ids.indices.contains(nextIndex) ? ids[nextIndex] : nil
            },
            previous: { value in
                guard let index = ids.firstIndex(of: value), index != ids.startIndex else { return nil }
                return ids[ids.index(before: index)]
            }
        )

        #expect(resolver.next(after: 1) == 2)

        ids = [1, 3]

        #expect(resolver.next(after: 1) == 3)
    }
}
