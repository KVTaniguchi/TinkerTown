import Foundation

public struct PlanningChecklistItem: Sendable, Equatable {
    public let title: String
    public let completed: Bool
}

/// Manages the human-facing project plan document and checklist.
/// The plan lives at `<repo>/plan/PROJECT_PLAN.md` and is treated as
/// a Mayor-owned, human-readable file that can be opened in any editor.
public struct PlanningService {
    private let fs: FileSysteming
    private let paths: AppPaths

    public init(fs: FileSysteming = LocalFileSystem(), paths: AppPaths) {
        self.fs = fs
        self.paths = paths
    }

    /// Default location for the project plan.
    public var planFile: URL {
        let planDir = paths.root.appendingPathComponent("plan", isDirectory: true)
        return planDir.appendingPathComponent("PROJECT_PLAN.md")
    }

    /// Result of importing or parsing a project plan (e.g. for PDR derivation).
    public struct PlanImportResult: Sendable {
        public let planFileURL: URL
        public let derivedTitle: String
        public let derivedSummary: String
    }

    /// Imports project plan content: writes it to `plan/PROJECT_PLAN.md` and returns
    /// the file URL plus derived title/summary for use when creating or updating the PDR.
    /// Use this when the user pastes or uploads a plan so the mirror can use it without
    /// requiring a separate PDR JSON edit.
    public func importPlanContent(_ content: String) throws -> PlanImportResult {
        try fs.createDirectory(planFile.deletingLastPathComponent())
        let data = Data(content.utf8)
        try fs.write(data, to: planFile)
        let (title, summary) = Self.parsePlanMetadata(content)
        return PlanImportResult(planFileURL: planFile, derivedTitle: title, derivedSummary: summary)
    }

    /// Parses plan markdown for title (from first # heading) and summary (Overview section).
    public static func parsePlanMetadata(_ content: String) -> (title: String, summary: String) {
        var title = "My project"
        var summary = ""

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        // Title: first line that looks like "# Project Plan – X" or "# X"
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let rest = String(trimmed.dropFirst(2))
                if rest.lowercased().hasPrefix("project plan – ") {
                    title = String(rest.dropFirst("project plan – ".count)).trimmingCharacters(in: .whitespaces)
                } else {
                    title = rest
                }
                break
            }
            if !trimmed.isEmpty { break }
            i += 1
        }

        // Summary: "## Overview" section until next ## or end
        if let overviewIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## overview" }) {
            var overviewLines: [String] = []
            for j in (overviewIdx + 1) ..< lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("## ") { break }
                overviewLines.append(lines[j])
            }
            summary = overviewLines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
        }

        if summary.isEmpty {
            summary = "See plan/PROJECT_PLAN.md for scope, checklist, and backlog."
        }
        return (title, summary)
    }

    /// Ensure a default plan exists. If the file is missing, this will create
    /// a minimal Markdown template seeded with the provided project title.
    /// Returns the URL of the plan file.
    @discardableResult
    public func ensureDefaultPlanExists(title: String) throws -> URL {
        if !fs.fileExists(planFile) {
            try fs.createDirectory(planFile.deletingLastPathComponent())
            let contents = defaultTemplate(title: title)
            if let data = contents.data(using: .utf8) {
                try fs.write(data, to: planFile)
            }
        }
        return planFile
    }

    /// Load the current checklist items from the plan file, if it exists.
    /// The sidebar checklist is read-only from this file; it is not auto-updated
    /// when tasks complete. Use `markChecklistItemsComplete(titles:)` to tick items.
    /// Lines starting with `- [ ]` or `- [x]` are treated as checklist entries.
    /// To be forgiving of human-authored plans, we also accept bare checklist
    /// lines that are missing the leading dash (e.g. `[ ] Task` or `[x] Task`).
    public func loadChecklistItems() -> [PlanningChecklistItem] {
        guard fs.fileExists(planFile),
              let data = try? fs.read(planFile),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var items: [PlanningChecklistItem] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Canonical Markdown checklist items.
            if trimmed.hasPrefix("- [ ] ") {
                let title = String(trimmed.dropFirst("- [ ] ".count))
                items.append(PlanningChecklistItem(title: title, completed: false))
                continue
            }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let title = String(trimmed.dropFirst("- [x] ".count))
                items.append(PlanningChecklistItem(title: title, completed: true))
                continue
            }

            // Forgiving mode: accept bare `[ ] Task` / `[x] Task` lines that are
            // missing the leading dash so human-authored plans still work.
            if trimmed.hasPrefix("[ ] ") {
                let title = String(trimmed.dropFirst("[ ] ".count))
                items.append(PlanningChecklistItem(title: title, completed: false))
                continue
            }
            if trimmed.hasPrefix("[x] ") || trimmed.hasPrefix("[X] ") {
                let title = String(trimmed.dropFirst("[x] ".count))
                items.append(PlanningChecklistItem(title: title, completed: true))
                continue
            }
        }
        return items
    }

    /// Marks checklist items in the plan file as complete when the line's title
    /// equals (or contains) one of the given titles. Matching is case-sensitive.
    /// Use after a run completes with merged tasks whose titles align to plan items.
    public func markChecklistItemsComplete(titles: [String]) throws {
        guard fs.fileExists(planFile),
              let data = try? fs.read(planFile),
              let text = String(data: data, encoding: .utf8) else { return }
        let titleSet = Set(titles)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ] ") {
                let itemTitle = String(trimmed.dropFirst("- [ ] ".count))
                if titleSet.contains(itemTitle) || titleSet.contains(where: { itemTitle.contains($0) }) || titleSet.contains(where: { $0.contains(itemTitle) }) {
                    lines[i] = line.replacingOccurrences(of: "- [ ] ", with: "- [x] ")
                }
            } else if trimmed.hasPrefix("[ ] ") {
                let itemTitle = String(trimmed.dropFirst("[ ] ".count))
                if titleSet.contains(itemTitle) || titleSet.contains(where: { itemTitle.contains($0) }) || titleSet.contains(where: { $0.contains(itemTitle) }) {
                    lines[i] = line.replacingOccurrences(of: "[ ] ", with: "[x] ")
                }
            }
        }
        let newText = lines.joined(separator: "\n")
        if newText != text, let out = newText.data(using: .utf8) {
            try fs.write(out, to: planFile)
        }
    }

    private func defaultTemplate(title: String) -> String {
        """
        # Project Plan – \(title)

        ## Overview
        Briefly restate the project scope and goals here. This should be derived from the Product Design Requirement.

        ## Active Checklist (Mayor-owned)
        - [ ] First concrete task derived from the product requirements

        ## Backlog (Mayor-owned)
        - [ ] Future task or idea to consider

        ## Decisions Log (Mayor-owned)
        - 2026-03-10: Document major decisions and tradeoffs here.

        ## Risks / Unknowns (Mayor-owned)
        - Describe known risks or open questions.

        """
    }
}

