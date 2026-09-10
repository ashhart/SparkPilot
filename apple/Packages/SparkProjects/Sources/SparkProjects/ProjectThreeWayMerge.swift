import Foundation

/// Merge two edits against the revision both started from, which the editor already holds (§42.8).
public enum ProjectThreeWayMerge {
    public struct Result: Equatable, Sendable {
        public let text: String
        /// Regions both sides rewrote. A save is only safe on its own when this is zero.
        public let conflictCount: Int
        public var isClean: Bool { conflictCount == 0 }
    }

    enum Section: Equatable {
        case settled([String])
        case contested(mine: [String], base: [String], theirs: [String])
    }

    public static func merge(base: String, mine: String, theirs: String) -> Result {
        let sections = sections(
            base: lines(base),
            mine: lines(mine),
            theirs: lines(theirs)
        )
        var merged: [String] = []
        var contested = 0
        for section in sections {
            switch section {
            case .settled(let text):
                merged += text
            case .contested(let mine, _, let theirs):
                contested += 1
                merged.append("<<<<<<< this device")
                merged += mine
                merged.append("=======")
                merged += theirs
                merged.append(">>>>>>> the Spark")
            }
        }
        return Result(text: merged.joined(separator: "\n"), conflictCount: contested)
    }

    /// Split on newlines only; a trailing newline stays as a trailing empty line so it round-trips.
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func sections(base: [String], mine: [String], theirs: [String]) -> [Section] {
        let mineMatch = alignment(base: base, other: mine)
        let theirsMatch = alignment(base: base, other: theirs)
        var sections: [Section] = []
        var settled: [String] = []
        var baseIndex = 0
        var mineIndex = 0
        var theirsIndex = 0

        func flush() {
            if !settled.isEmpty {
                sections.append(.settled(settled))
                settled = []
            }
        }

        while baseIndex < base.count || mineIndex < mine.count || theirsIndex < theirs.count {
            if baseIndex < base.count, mineMatch[baseIndex] == mineIndex,
                theirsMatch[baseIndex] == theirsIndex
            {
                settled.append(base[baseIndex])
                baseIndex += 1
                mineIndex += 1
                theirsIndex += 1
                continue
            }
            let next = nextStable(
                base: base,
                mineMatch: mineMatch,
                theirsMatch: theirsMatch,
                from: baseIndex,
                mineIndex: mineIndex,
                theirsIndex: theirsIndex,
                mineCount: mine.count,
                theirsCount: theirs.count
            )
            let baseChunk = Array(base[baseIndex..<next.base])
            let mineChunk = Array(mine[mineIndex..<next.mine])
            let theirsChunk = Array(theirs[theirsIndex..<next.theirs])
            if mineChunk == theirsChunk || theirsChunk == baseChunk {
                settled += mineChunk
            } else if mineChunk == baseChunk {
                settled += theirsChunk
            } else {
                flush()
                sections.append(.contested(mine: mineChunk, base: baseChunk, theirs: theirsChunk))
            }
            baseIndex = next.base
            mineIndex = next.mine
            theirsIndex = next.theirs
        }
        flush()
        return sections
    }

    private static func nextStable(
        base: [String],
        mineMatch: [Int: Int],
        theirsMatch: [Int: Int],
        from baseIndex: Int,
        mineIndex: Int,
        theirsIndex: Int,
        mineCount: Int,
        theirsCount: Int
    ) -> (base: Int, mine: Int, theirs: Int) {
        var candidate = baseIndex
        while candidate < base.count {
            if let inMine = mineMatch[candidate], let inTheirs = theirsMatch[candidate],
                inMine >= mineIndex, inTheirs >= theirsIndex
            {
                return (candidate, inMine, inTheirs)
            }
            candidate += 1
        }
        return (base.count, mineCount, theirsCount)
    }

    /// Map each retained base line onto its line in the other version, in order.
    static func alignment(base: [String], other: [String]) -> [Int: Int] {
        let difference = other.difference(from: base)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var map: [Int: Int] = [:]
        var otherIndex = 0
        for baseIndex in base.indices where !removed.contains(baseIndex) {
            while inserted.contains(otherIndex) { otherIndex += 1 }
            map[baseIndex] = otherIndex
            otherIndex += 1
        }
        return map
    }
}
