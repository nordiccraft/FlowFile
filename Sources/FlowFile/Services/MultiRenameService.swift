import Foundation

enum RenameCaseTransform: String, CaseIterable, Identifiable {
    case unchanged = "Uendret"
    case lowercase = "små bokstaver"
    case uppercase = "STORE BOKSTAVER"
    case titleCase = "Stor Forbokstav"
    case capitalizeFirst = "Kun første stor"

    var id: String { rawValue }
}

struct MultiRenameConfig {
    var nameMask: String = "[N]"
    var extensionMask: String = "[E]"
    var searchText: String = ""
    var replaceText: String = ""
    var useRegex: Bool = false
    var caseSensitiveSearch: Bool = false
    var caseTransform: RenameCaseTransform = .unchanged
    var counterStart: Int = 1
    var counterStep: Int = 1
    var counterDigits: Int = 3
}

enum RenamePreviewStatus: Equatable {
    case ready
    case unchanged
    case invalidEmpty
    case duplicateConflict
    case existsOnDisk
}

struct RenamePreviewRow: Identifiable {
    let id: URL
    let sourceItem: FileItem
    let proposedName: String
    var status: RenamePreviewStatus

    var canApply: Bool {
        status == .ready
    }
}

struct RenameUndoRecord {
    /// Pairs of (currentURLAfterRename, originalURLBeforeRename)
    let pairs: [(renamedURL: URL, originalURL: URL)]
    let timestamp: Date
}

enum MultiRenameService {
    private static let dateTokenFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static let timeTokenFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HHmmss"
        return df
    }()

    static func generatePreview(items: [FileItem], config: MultiRenameConfig) -> [RenamePreviewRow] {
        guard !items.isEmpty else { return [] }
        let directory = items[0].url.deletingLastPathComponent()
        let selectedSourceSet = Set(items.map { $0.url.standardizedFileURL })

        var rows: [RenamePreviewRow] = []
        rows.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let counterValue = config.counterStart + (index * config.counterStep)
            let counterStr = String(format: "%0\(max(1, config.counterDigits))d", counterValue)

            let modDate = item.modificationDate ?? Date()
            let dateStr = dateTokenFormatter.string(from: modDate)
            let timeStr = timeTokenFormatter.string(from: modDate)
            let parentName = item.url.deletingLastPathComponent().lastPathComponent

            let expandedStem = expandMask(
                config.nameMask,
                stem: item.stemName,
                ext: item.rawFileExtension,
                counter: counterStr,
                date: dateStr,
                time: timeStr,
                parent: parentName
            )

            let expandedExt = expandMask(
                config.extensionMask,
                stem: item.stemName,
                ext: item.rawFileExtension,
                counter: counterStr,
                date: dateStr,
                time: timeStr,
                parent: parentName
            ).trimmingCharacters(in: CharacterSet(charactersIn: "."))

            var combined: String
            if item.isNavigableFolder || expandedExt.isEmpty {
                combined = expandedStem
            } else {
                combined = "\(expandedStem).\(expandedExt)"
            }

            // Search & Replace
            if !config.searchText.isEmpty {
                if config.useRegex {
                    var options: NSRegularExpression.Options = []
                    if !config.caseSensitiveSearch {
                        options.insert(.caseInsensitive)
                    }
                    if let regex = try? NSRegularExpression(pattern: config.searchText, options: options) {
                        let nsRange = NSRange(combined.startIndex..<combined.endIndex, in: combined)
                        combined = regex.stringByReplacingMatches(
                            in: combined,
                            options: [],
                            range: nsRange,
                            withTemplate: config.replaceText
                        )
                    }
                } else {
                    let compareOpts: String.CompareOptions = config.caseSensitiveSearch ? [] : [.caseInsensitive]
                    combined = combined.replacingOccurrences(
                        of: config.searchText,
                        with: config.replaceText,
                        options: compareOpts
                    )
                }
            }

            // Case transform (applied to stem while keeping extension case unless folder)
            combined = applyCaseTransform(combined, transform: config.caseTransform, isFolder: item.isNavigableFolder)
            combined = combined.replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let initialStatus: RenamePreviewStatus
            if combined.isEmpty {
                initialStatus = .invalidEmpty
            } else if combined == item.name {
                initialStatus = .unchanged
            } else {
                initialStatus = .ready
            }

            rows.append(RenamePreviewRow(
                id: item.url,
                sourceItem: item,
                proposedName: combined,
                status: initialStatus
            ))
        }

        // Check duplicate proposed names within the batch
        var counts: [String: Int] = [:]
        for row in rows where !row.proposedName.isEmpty {
            counts[row.proposedName.lowercased(), default: 0] += 1
        }

        for i in rows.indices {
            let proposed = rows[i].proposedName
            guard !proposed.isEmpty else { continue }
            if (counts[proposed.lowercased()] ?? 0) > 1 {
                rows[i].status = .duplicateConflict
                continue
            }
            if rows[i].status == .ready {
                let targetURL = directory.appendingPathComponent(proposed).standardizedFileURL
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    let isSelectedItem = selectedSourceSet.contains(targetURL)
                        || items.contains(where: { FileSystemService.referToSameFile($0.url, targetURL) })
                    if !isSelectedItem {
                        rows[i].status = .existsOnDisk
                    }
                }
            }
        }

        return rows
    }

    /// Executes a safe two-phase rename via temporary filenames with full transactional rollback on failure.
    static func executeBatchRename(
        rows: [RenamePreviewRow],
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> RenameUndoRecord {
        let actionable = rows.filter { $0.status == .ready }
        guard !actionable.isEmpty else {
            return RenameUndoRecord(pairs: [], timestamp: Date())
        }

        // Reject if any row in the batch has a conflict
        if rows.contains(where: { $0.status == .duplicateConflict || $0.status == .existsOnDisk || $0.status == .invalidEmpty }) {
            throw FileSystemError.targetAlreadyExists("Løs navnekollisjoner i listen før du starter masse-omdøping.")
        }

        var staged: [(tempURL: URL, finalURL: URL, originalURL: URL)] = []
        let batchToken = UUID().uuidString.prefix(8)

        // Phase 1: Move to temporary names
        do {
            for (idx, row) in actionable.enumerated() {
                let dir = row.sourceItem.url.deletingLastPathComponent()
                let tempURL = dir.appendingPathComponent(".flowfile_renametmp_\(batchToken)_\(idx)")
                let finalURL = dir.appendingPathComponent(row.proposedName)
                try moveItem(row.sourceItem.url, tempURL)
                staged.append((tempURL: tempURL, finalURL: finalURL, originalURL: row.sourceItem.url))
            }
        } catch {
            for entry in staged.reversed() {
                try? FileManager.default.moveItem(at: entry.tempURL, to: entry.originalURL)
            }
            throw error
        }

        // Phase 2: Move from temporary names to final names
        var completedStageIndices: [Int] = []
        do {
            for (idx, entry) in staged.enumerated() {
                try moveItem(entry.tempURL, entry.finalURL)
                completedStageIndices.append(idx)
            }
        } catch {
            // First revert any Phase 2 moves back to their temporary URLs so swapped names never collide during rollback
            for idx in completedStageIndices.reversed() {
                let entry = staged[idx]
                try? FileManager.default.moveItem(at: entry.finalURL, to: entry.tempURL)
            }
            // Then revert all temporary URLs back to their exact original URLs
            for entry in staged.reversed() {
                try? FileManager.default.moveItem(at: entry.tempURL, to: entry.originalURL)
            }
            throw error
        }

        let completedPairs = staged.map { (renamedURL: $0.finalURL, originalURL: $0.originalURL) }
        return RenameUndoRecord(pairs: completedPairs, timestamp: Date())
    }

    static func undoBatchRename(
        _ record: RenameUndoRecord,
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let fm = FileManager.default
        let batchToken = UUID().uuidString.prefix(8)
        var staged: [(tempURL: URL, originalURL: URL, renamedURL: URL)] = []

        do {
            for (idx, pair) in record.pairs.enumerated() where fm.fileExists(atPath: pair.renamedURL.path) {
                let dir = pair.renamedURL.deletingLastPathComponent()
                let tempURL = dir.appendingPathComponent(".flowfile_undotmp_\(batchToken)_\(idx)")
                try moveItem(pair.renamedURL, tempURL)
                staged.append((tempURL: tempURL, originalURL: pair.originalURL, renamedURL: pair.renamedURL))
            }
        } catch {
            for entry in staged.reversed() {
                try? fm.moveItem(at: entry.tempURL, to: entry.renamedURL)
            }
            throw error
        }

        var restoredIndices: [Int] = []
        do {
            for (idx, entry) in staged.enumerated() {
                try moveItem(entry.tempURL, entry.originalURL)
                restoredIndices.append(idx)
            }
        } catch {
            for idx in restoredIndices.reversed() {
                let entry = staged[idx]
                try? fm.moveItem(at: entry.originalURL, to: entry.tempURL)
            }
            for entry in staged.reversed() {
                try? fm.moveItem(at: entry.tempURL, to: entry.renamedURL)
            }
            throw error
        }
    }

    private static func expandMask(
        _ mask: String,
        stem: String,
        ext: String,
        counter: String,
        date: String,
        time: String,
        parent: String
    ) -> String {
        var result = mask
            .replacingOccurrences(of: "[N]", with: stem)
            .replacingOccurrences(of: "[E]", with: ext)
            .replacingOccurrences(of: "[C]", with: counter)
            .replacingOccurrences(of: "[D]", with: date)
            .replacingOccurrences(of: "[T]", with: time)
            .replacingOccurrences(of: "[P]", with: parent)

        // Support Total Commander substring range [Nstart-end] (1-based inclusive)
        if let regex = try? NSRegularExpression(pattern: "\\[N(\\d+)-(\\d+)\\]") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let r1 = Range(match.range(at: 1), in: result),
                      let r2 = Range(match.range(at: 2), in: result),
                      let start1 = Int(result[r1]),
                      let end1 = Int(result[r2]),
                      start1 >= 1, end1 >= start1 else {
                    continue
                }
                let chars = Array(stem)
                let startIdx = min(chars.count, start1 - 1)
                let endIdx = min(chars.count, end1)
                let slice = startIdx < endIdx ? String(chars[startIdx..<endIdx]) : ""
                result.replaceSubrange(fullRange, with: slice)
            }
        }

        return result
    }

    private static func applyCaseTransform(_ name: String, transform: RenameCaseTransform, isFolder: Bool) -> String {
        guard transform != .unchanged else { return name }

        let stem: String
        let extPart: String
        if isFolder {
            stem = name
            extPart = ""
        } else {
            let url = URL(fileURLWithPath: name)
            let ext = url.pathExtension
            if ext.isEmpty {
                stem = name
                extPart = ""
            } else {
                stem = String(name.dropLast(ext.count + 1))
                switch transform {
                case .lowercase:
                    extPart = "." + ext.lowercased()
                case .uppercase:
                    extPart = "." + ext.uppercased()
                default:
                    extPart = "." + ext
                }
            }
        }

        let transformedStem: String
        switch transform {
        case .unchanged:
            transformedStem = stem
        case .lowercase:
            transformedStem = stem.lowercased()
        case .uppercase:
            transformedStem = stem.uppercased()
        case .titleCase:
            transformedStem = stem.localizedCapitalized
        case .capitalizeFirst:
            if let first = stem.first {
                transformedStem = String(first).uppercased() + stem.dropFirst().lowercased()
            } else {
                transformedStem = stem
            }
        }
        return transformedStem + extPart
    }
}
