import Testing
import StatusItemProbeSupport

/// The status menu's lyrics offset row is a custom view, and its label has to
/// start where the menu's titles start. AppKit has no API for that place, and
/// macOS 27 moved it 6 points right in a menu with a state column, away from
/// the 24 points the app had fixed the label at; the fixed 14 points without
/// a state column had been 2 points short since macOS 26.
/// `TitleAlignedMenuItemView` now measures the place in the open menu and
/// falls back to a table per release.
///
/// Each case opens a real menu inside the probe host — the view has to sit in
/// a menu AppKit built — and compares where the row's text and the titles'
/// texts start in the menu's rendered pixels. The fallback cases check the
/// table against the running release. The measured cases must also have
/// measured: a fallback there means the view no longer finds AppKit's titles.
@Suite(.serialized)
struct StatusMenuTitleAlignmentProbes {
    @Test(arguments: MenuTitleAlignmentCase.allCases)
    func theCustomRowsLabelStartsWhereTheTitlesStart(_ menuCase: MenuTitleAlignmentCase) async throws {
        let report = try await StatusItemProbeHostLauncher.run(as: MenuTitleAlignmentReport.self) { reportPath in
            .menuTitleAlignment(menuCase, reportPath: reportPath)
        }
        try #require(report.problem == nil, "The probe could not measure: \(report.problem ?? "")")
        let labelTextStart = try #require(report.labelTextStart, "No text found in the custom row")
        let titleTextStarts = report.titleTextStarts.values.sorted()
        let firstTitleStart = try #require(titleTextStarts.first, "No text found beside any title")
        let lastTitleStart = try #require(titleTextStarts.last)
        try #require(lastTitleStart - firstTitleStart <= 0.5, "The plain titles disagree: \(report.titleTextStarts)")

        #expect(
            abs(labelTextStart - firstTitleStart) <= 0.5,
            "The label's text starts at \(labelTextStart) pt, the titles' at \(firstTitleStart) pt (leading constant \(report.labelLeadingInset), placement \(report.labelPlacement))"
        )
        #expect(report.labelPlacement == (menuCase.measuresMenuTitles ? "measured" : "fallback"))
    }
}
