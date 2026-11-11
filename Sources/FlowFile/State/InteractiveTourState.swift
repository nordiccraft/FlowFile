import Foundation
import Observation
import SwiftUI

enum TourTargetID: String, Hashable {
    case copyPathButton
    case sidebar
    case dualPaneButton
    case compareButton
    case exitCompareBanner
    case dropShelfPanel
    case shareButton
}

struct TourAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [TourTargetID: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [TourTargetID: Anchor<CGRect>], nextValue: () -> [TourTargetID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func tourTarget(_ id: TourTargetID) -> some View {
        anchorPreference(key: TourAnchorPreferenceKey.self, value: .bounds) { [id: $0] }
    }
}

enum TourStep: Int, CaseIterable, Identifiable {
    case welcomeSetup = 0
    case copyPath = 1
    case sidebarAndCloud = 2
    case dualPaneToggle = 3
    case folderCompareStart = 4
    case folderCompareExit = 5
    case dropShelfPractice = 6
    case smartShareFinish = 7

    var id: Int { rawValue }

    var targetID: TourTargetID? {
        switch self {
        case .welcomeSetup: return nil
        case .copyPath: return .copyPathButton
        case .sidebarAndCloud: return .sidebar
        case .dualPaneToggle: return .dualPaneButton
        case .folderCompareStart: return .compareButton
        case .folderCompareExit: return .exitCompareBanner
        case .dropShelfPractice: return .dropShelfPanel
        case .smartShareFinish: return .shareButton
        }
    }
}

struct DemoShelfFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let sourceFolder: String
    let sizeLabel: String
    let sfSymbol: String
}

@Observable
final class InteractiveTourState {
    var isActive: Bool = false
    var currentStep: TourStep = .welcomeSetup

    // Step completion feedback flags
    var didClickCopyPath: Bool = false
    var demoShelfLoaded: Bool = false
    var demoTransferProgress: Double = 0.0
    var demoTransferRunning: Bool = false
    var demoTransferCompleted: Bool = false
    var didPreviewShareHub: Bool = false

    let availableDemoFiles: [DemoShelfFile] = [
        DemoShelfFile(name: "Budsjett_2026.xlsx", sourceFolder: "Dokumenter/Økonomi", sizeLabel: "1,4 MB", sfSymbol: "tablecells.fill"),
        DemoShelfFile(name: "Kontrakt_Utkast.pdf", sourceFolder: "OneDrive/Kunder", sizeLabel: "840 KB", sfSymbol: "doc.richtext.fill"),
        DemoShelfFile(name: "Prosjektbilde.jpg", sourceFolder: "Nedlastinger", sizeLabel: "3,2 MB", sfSymbol: "photo.fill")
    ]

    var demoBasketFiles: [DemoShelfFile] = []

    var isSandboxActive: Bool {
        isActive
    }

    var isDropShelfDemoActive: Bool {
        isActive && currentStep == .dropShelfPractice
    }

    func resetDemoState() {
        didClickCopyPath = false
        demoShelfLoaded = false
        demoTransferProgress = 0.0
        demoTransferRunning = false
        demoTransferCompleted = false
        didPreviewShareHub = false
        demoBasketFiles = []
    }

    func loadDemoFilesIntoBasket() {
        demoBasketFiles = availableDemoFiles
        demoShelfLoaded = true
        demoTransferCompleted = false
        demoTransferProgress = 0.0
    }

    func runSimulatedTransfer() {
        guard !demoTransferRunning else { return }
        if demoBasketFiles.isEmpty {
            demoBasketFiles = availableDemoFiles
        }
        demoTransferRunning = true
        demoTransferCompleted = false
        demoTransferProgress = 0.08

        Task { @MainActor [weak self] in
            for step in 1...8 {
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard let self, self.isActive else { return }
                self.demoTransferProgress = Double(step) / 8.0
            }
            self?.demoTransferRunning = false
            self?.demoTransferCompleted = true
            self?.demoBasketFiles = []
        }
    }
}
