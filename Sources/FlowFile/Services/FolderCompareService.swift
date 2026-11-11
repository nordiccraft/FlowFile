import Foundation

enum FileDiffStatus: Equatable {
    case onlyHere
    case newerHere
    case olderHere
    case sizeDiffers
    case identical

    var badgeText: String {
        switch self {
        case .onlyHere: return tr("NY", "NEW")
        case .newerHere: return tr("NYERE", "NEWER")
        case .olderHere: return tr("ELDRE", "OLDER")
        case .sizeDiffers: return tr("ULIK", "DIFF")
        case .identical: return tr("LIK", "SAME")
        }
    }
}

struct FolderCompareResult {
    let leftStatuses: [URL: FileDiffStatus]
    let rightStatuses: [URL: FileDiffStatus]
    let differencesCount: Int
}

enum FolderCompareService {
    static func compare(leftItems: [FileItem], rightItems: [FileItem]) -> FolderCompareResult {
        var rightByName: [String: FileItem] = [:]
        for item in rightItems {
            rightByName[item.name] = item
        }

        var leftByName: [String: FileItem] = [:]
        for item in leftItems {
            leftByName[item.name] = item
        }

        var leftStatuses: [URL: FileDiffStatus] = [:]
        var rightStatuses: [URL: FileDiffStatus] = [:]
        var diffCount = 0

        for lItem in leftItems {
            guard let rItem = rightByName[lItem.name] else {
                leftStatuses[lItem.url] = .onlyHere
                diffCount += 1
                continue
            }

            if lItem.isNavigableFolder && rItem.isNavigableFolder {
                leftStatuses[lItem.url] = .identical
                continue
            }

            let status = comparePair(primary: lItem, counterpart: rItem)
            leftStatuses[lItem.url] = status
            if status != .identical {
                diffCount += 1
            }
        }

        for rItem in rightItems {
            guard let lItem = leftByName[rItem.name] else {
                rightStatuses[rItem.url] = .onlyHere
                diffCount += 1
                continue
            }

            if rItem.isNavigableFolder && lItem.isNavigableFolder {
                rightStatuses[rItem.url] = .identical
                continue
            }

            let status = comparePair(primary: rItem, counterpart: lItem)
            rightStatuses[rItem.url] = status
        }

        return FolderCompareResult(
            leftStatuses: leftStatuses,
            rightStatuses: rightStatuses,
            differencesCount: diffCount
        )
    }

    private static func comparePair(primary: FileItem, counterpart: FileItem) -> FileDiffStatus {
        let pTime = primary.modificationDate?.timeIntervalSince1970 ?? 0
        let cTime = counterpart.modificationDate?.timeIntervalSince1970 ?? 0
        let timeDelta = pTime - cTime

        if primary.size == counterpart.size && abs(timeDelta) <= 2.0 {
            return .identical
        }
        if timeDelta > 2.0 {
            return .newerHere
        }
        if timeDelta < -2.0 {
            return .olderHere
        }
        return .sizeDiffers
    }
}
