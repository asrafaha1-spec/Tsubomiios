import SwiftUI

/// The landscape cover carousel: a centred, endlessly looping row where the
/// focused cover is full size and its neighbours are scaled down and dimmed.
///
/// Looping works the way the UIKit version's did — the games are repeated many
/// times and indices map back with modulo — but there is no seam handling: the
/// row simply is a few hundred covers long and starts in the middle. See
/// `CarouselLayout.items(for:)`.
///
/// Two implementations sit behind this type. iOS 17 and later use the scroll
/// position / view-aligned snapping APIs (`ModernCoverCarousel`). iOS 16 has no
/// way to read or drive a scroll position declaratively, so
/// `LegacyCoverCarousel` measures each cover's distance from the viewport
/// centre itself and snaps to the nearest cover when scrolling settles.
@MainActor
struct CoverCarousel<Menu: View>: View {
    let games: [GameEntry]
    /// Firmware missing — every cover is held back at reduced opacity.
    let dimmed: Bool
    /// Pad focus. Two-way: scrolling by touch moves the pad's focus so the two
    /// never disagree, and D-pad input scrolls the row.
    @Binding var padFocusedTitleID: String?
    /// D-pad stepping from LibraryState: a running net-steps total.
    let stepAccumulator: Int
    let onLaunch: (GameEntry) -> Void
    @ViewBuilder let menu: (GameEntry) -> Menu

    var body: some View {
        if #available(iOS 17.0, *) {
            ModernCoverCarousel(
                games: games,
                dimmed: dimmed,
                padFocusedTitleID: $padFocusedTitleID,
                stepAccumulator: stepAccumulator,
                onLaunch: onLaunch,
                menu: menu
            )
        } else {
            LegacyCoverCarousel(
                games: games,
                dimmed: dimmed,
                padFocusedTitleID: $padFocusedTitleID,
                stepAccumulator: stepAccumulator,
                onLaunch: onLaunch,
                menu: menu
            )
        }
    }
}

// MARK: - Shared

/// One cover in the repeated row.
private struct CarouselItem: Identifiable {
    let repeatIndex: Int
    let game: GameEntry
    var id: String { "\(repeatIndex)-\(game.titleID)" }
}

private enum CarouselLayout {
    static let spacing: CGFloat = 18

    /// The repeated item list and the repeat the row starts in.
    ///
    /// The row simply *is* this long; there is no seam-jumping. Starting in the
    /// middle of a few hundred covers is indistinguishable from infinite in
    /// practice. Capped by total item count so a large library does not become
    /// tens of thousands of entries.
    static func items(for games: [GameEntry]) -> (items: [CarouselItem], middleRepeat: Int) {
        guard games.count > 1 else {
            return (games.map { CarouselItem(repeatIndex: 0, game: $0) }, 0)
        }
        var target = max(3, min(101, 600 / games.count))
        if target.isMultiple(of: 2) { target += 1 }
        let built = (0..<target).flatMap { repeatIndex in
            games.map { CarouselItem(repeatIndex: repeatIndex, game: $0) }
        }
        return (built, target / 2)
    }

    static func titleID(from id: String) -> String? {
        guard let separator = id.firstIndex(of: "-") else { return nil }
        return String(id[id.index(after: separator)...])
    }

    /// Bigger than before (0.34 → 0.42 of the width, and less vertical
    /// reserve): the covers are the whole point of this view, so they should
    /// dominate it.
    static func coverSide(in size: CGSize, wide: Bool) -> CGFloat {
        let availableHeight = max(140, size.height - 70)
        if wide {
            return max(180, min(availableHeight * (16.0 / 9.0), size.width * 0.56))
        }
        return max(140, min(availableHeight, size.width * 0.46))
    }
}

/// A cover with its title and play-time line, shared by both carousels.
@MainActor
private struct CarouselCoverLabel: View {
    let game: GameEntry
    let side: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            // Width-fixed, height free: wide covers use one 16:9 frame so
            // switching modes cannot leave a mixture of card sizes.
            GameCover(game: game, allowsWide: true)
                .frame(width: side)
            Text(game.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(game.playedTimeText)  ·  \(game.lastPlayedText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: side)
    }
}

// MARK: - iOS 17+

@available(iOS 17.0, *)
@MainActor
private struct ModernCoverCarousel<Menu: View>: View {
    let games: [GameEntry]
    /// Firmware missing — every cover is held back at reduced opacity.
    let dimmed: Bool
    /// Pad focus. Two-way: scrolling by touch moves the pad's focus so the two
    /// never disagree, and D-pad input scrolls the row.
    @Binding var padFocusedTitleID: String?
    /// D-pad stepping from LibraryState: a running net-steps total. The
    /// carousel steps by the delta since it last read it, so two presses that
    /// coalesce into one observation still move the right number of covers.
    let stepAccumulator: Int
    let onLaunch: (GameEntry) -> Void
    @ViewBuilder let menu: (GameEntry) -> Menu

    /// Identity of the centred item, as "<repeat>-<titleID>".
    @State private var scrolledID: String?
    @State private var hapticTrigger = 0
    /// Last accumulator value applied, so the next change steps by the delta.
    @State private var lastConsumedStep = 0
    @AppStorage(DefaultsKey.wideCoverArt.rawValue) private var wideCoverArt = true

    /// The repeated item list, cached. Rebuilt only when the games change - not
    /// on every body pass. body re-runs on each scroll settle and every haptic
    /// tick, and rebuilding several hundred structs (each with a String id) on
    /// each of those was avoidable churn while browsing.
    @State private var items: [CarouselItem] = []
    @State private var middleRepeat = 0

    /// Games' identity, so the cache rebuilds when the library actually changes.
    private var gamesKey: String { games.map(\.titleID).joined(separator: ",") }

    private func rebuildItems() {
        let built = CarouselLayout.items(for: games)
        items = built.items
        middleRepeat = built.middleRepeat
    }

    var body: some View {
        GeometryReader { proxy in
            // Every item shares one width so toggling wide art cannot leave a
            // mixture of carousel card sizes.
            let coverWidth = CarouselLayout.coverSide(in: proxy.size, wide: wideCoverArt)
            ScrollView(.horizontal) {
                LazyHStack(spacing: CarouselLayout.spacing) {
                    ForEach(items) { item in
                        cover(item.game, side: coverWidth)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            // safeAreaPadding on the scroll view, NOT padding inside its
            // content. Padding applied after scrollTargetLayout() wraps the
            // target layout in a larger container, so the snap positions were
            // measured on that container instead of the covers - advancing one
            // game took most of a screen-width of drag. This insets the content
            // while leaving the scroll targets measured on the covers.
            .safeAreaPadding(.horizontal, max(0, (proxy.size.width - coverWidth) / 2))
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledID, anchor: .center)
            .scrollIndicators(.hidden)
            .compatOnChange(of: gamesKey, initial: true) { _, _ in
                rebuildItems()
                if scrolledID == nil, let first = games.first {
                    scrolledID = "\(middleRepeat)-\(first.titleID)"
                }
            }
        }
        .compatOnChange(of: scrolledID) { oldValue, newValue in
            guard let newValue, let titleID = CarouselLayout.titleID(from: newValue) else { return }
            if oldValue != nil {
                hapticTrigger += 1
                HomeSoundEffects.play(.tick)
            }
            // Touch scrolling drives the pad focus too, so picking the
            // controller back up continues from the visible cover.
            if padFocusedTitleID != titleID {
                padFocusedTitleID = titleID
            }
        }
        // D-pad steps by one cover in the flat, repeated list - crossing a
        // game boundary continues into the next repeat rather than wrapping
        // the game index back to the start, so holding a direction keeps
        // travelling one way. Moving the scroll target directly (not through
        // the focus id) is also what keeps rapid presses in sync: each press
        // advances exactly one detent instead of racing a focus round-trip.
        // Adopt the current total as the baseline on appear so re-entering the
        // carousel does not step by the whole accumulated history, then step
        // by the delta on each subsequent change.
        .onAppear { lastConsumedStep = stepAccumulator }
        .compatOnChange(of: stepAccumulator) { _, new in
            let delta = new - lastConsumedStep
            lastConsumedStep = new
            if delta != 0 { stepCarousel(by: delta) }
        }
        .sensoryFeedback(.selection, trigger: hapticTrigger)
        .opacity(dimmed ? 0.55 : 1)
    }

    private func cover(_ game: GameEntry, side: CGFloat) -> some View {
        CarouselCoverLabel(game: game, side: side)
        // Measured from real geometry, not from scroll phases or the tracked
        // centre id.
        //
        // scrollTransition reported identity for every visible cover whatever
        // threshold was used. Comparing against `scrolledID` then failed in a
        // way that looked identical on device: if that id never matches, every
        // cover gets the dimmed branch, and a uniform dim is indistinguishable
        // from no dim at all, because the effect only reads as contrast.
        //
        // visualEffect hands over a GeometryProxy at render time, so the
        // distance from the viewport centre can be computed directly. No
        // threshold semantics, no dependency on the scroll position binding
        // writing back, and it tracks the drag continuously instead of
        // settling per cover.
        .visualEffect { content, proxy in
            let frame = proxy.frame(in: .scrollView(axis: .horizontal))
            let viewport = proxy.bounds(of: .scrollView(axis: .horizontal)) ?? .zero
            // 0 at the centre, 1 once a full cover away.
            let stride = max(frame.width + 18, 1)
            // Double, not CGFloat: brightness and saturation take Double, and
            // mixing the two makes the arithmetic ambiguous.
            let distance = Double(min(abs(frame.midX - viewport.midX) / stride, 1))
            return content
                .scaleEffect(CGFloat(1 - 0.14 * distance))
                // Held back, not hidden: the neighbours are still browsable
                // covers, so this is a hierarchy cue rather than a disabled
                // state. Brightness rather than opacity, so a cover dims
                // instead of going translucent against the background.
                .brightness(-0.22 * distance)
                .saturation(1 - 0.2 * distance)
        }
        .contentShape(Rectangle())
        .onTapGesture { onLaunch(game) }
        .contextMenu { menu(game) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Advances the centred cover by `direction` items in the flat repeated
    /// list. Because the list is one long sequence of repeats, +1 past the
    /// last game continues into the first game of the next repeat rather than
    /// jumping backwards.
    private func stepCarousel(by direction: Int) {
        guard direction != 0,
              let current = scrolledID,
              let index = items.firstIndex(where: { $0.id == current })
        else { return }
        let next = index + direction
        guard items.indices.contains(next) else { return }
        // scrollPosition is a two-way binding. An interrupted animation can
        // write an intermediate cover back after the next D-pad press, making
        // the visible and actionable games disagree. Focus navigation takes
        // priority over decoration and acknowledges every press immediately.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrolledID = items[next].id
            padFocusedTitleID = items[next].game.titleID
        }
    }
}

// MARK: - iOS 16

private let legacyCarouselSpace = "tsubomi.legacyCarousel"

/// A cover's midpoint in the scroll view's own coordinate space.
private struct CarouselMidXKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Mutable bookkeeping for the iOS 16 carousel that must not itself cause a
/// redraw: when scrolling last moved, whether a finger is down, and the
/// pending snap.
@MainActor
private final class CarouselScrollDriver {
    var isDragging = false
    /// Cover-position reports are ignored until this time. Set whenever the
    /// carousel scrolls itself, so the covers that sweep past the centre on
    /// the way do not get mistaken for the user choosing them.
    var suppressUntil = Date.distantPast
    private var pending: Task<Void, Never>?

    var isSuppressed: Bool { Date() < suppressUntil }

    func suppress(for seconds: TimeInterval) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    /// Runs `action` once movement has been quiet for `seconds`.
    func settle(after seconds: Double, _ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

/// One cover in the iOS 16 carousel. It measures its own distance from the
/// viewport centre and applies the scale/dim itself, so a scroll redraws only
/// the covers on screen rather than the whole row.
@MainActor
private struct LegacyCarouselCell<Menu: View>: View {
    let item: CarouselItem
    let side: CGFloat
    let viewportWidth: CGFloat
    let onNearCenter: (String) -> Void
    let onMotion: () -> Void
    let onLaunch: (GameEntry) -> Void
    @ViewBuilder let menu: (GameEntry) -> Menu

    /// 0 at the centre, 1 once a full cover away.
    @State private var distance = 1.0

    var body: some View {
        CarouselCoverLabel(game: item.game, side: side)
            .scaleEffect(CGFloat(1 - 0.14 * distance))
            // Held back, not hidden: brightness rather than opacity, so a
            // cover dims instead of going translucent against the background.
            .brightness(-0.22 * distance)
            .saturation(1 - 0.2 * distance)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CarouselMidXKey.self,
                        value: proxy.frame(in: .named(legacyCarouselSpace)).midX
                    )
                }
            }
            .onPreferenceChange(CarouselMidXKey.self) { midX in
                guard midX.isFinite else { return }
                let stride = max(side + CarouselLayout.spacing, 1)
                let measured = Double(min(abs(midX - viewportWidth / 2) / stride, 1))
                if abs(measured - distance) > 0.002 { distance = measured }
                if measured < 0.5 {
                    // Deferred a turn: this runs inside a layout pass, and the
                    // callback publishes LibraryState's pad focus. Publishing
                    // during a view update is not allowed.
                    let id = item.id
                    DispatchQueue.main.async { onNearCenter(id) }
                }
                onMotion()
            }
            .contentShape(Rectangle())
            .onTapGesture { onLaunch(item.game) }
            .contextMenu { menu(item.game) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}

/// The iOS 16 carousel.
///
/// iOS 16 cannot read or set a scroll position declaratively, so this works
/// from what it can observe: every cover reports its distance from the
/// viewport centre, the nearest one is "centred", and once scrolling goes
/// quiet the row animates that cover exactly into the middle. D-pad steps jump
/// straight to the neighbouring cover with `ScrollViewReader`.
@MainActor
private struct LegacyCoverCarousel<Menu: View>: View {
    let games: [GameEntry]
    let dimmed: Bool
    @Binding var padFocusedTitleID: String?
    let stepAccumulator: Int
    let onLaunch: (GameEntry) -> Void
    @ViewBuilder let menu: (GameEntry) -> Menu

    @State private var items: [CarouselItem] = []
    @State private var middleRepeat = 0
    /// Identity of the centred item, as "<repeat>-<titleID>".
    @State private var centeredID: String?
    @State private var hapticTrigger = 0
    @State private var lastConsumedStep = 0
    @State private var driver = CarouselScrollDriver()
    @AppStorage(DefaultsKey.wideCoverArt.rawValue) private var wideCoverArt = true

    private var gamesKey: String { games.map(\.titleID).joined(separator: ",") }

    var body: some View {
        GeometryReader { proxy in
            let side = CarouselLayout.coverSide(in: proxy.size, wide: wideCoverArt)
            let inset = max(0, (proxy.size.width - side) / 2)
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CarouselLayout.spacing) {
                        ForEach(items) { item in
                            LegacyCarouselCell(
                                item: item,
                                side: side,
                                viewportWidth: proxy.size.width,
                                onNearCenter: { nearCenter($0) },
                                onMotion: { motion(scroller) },
                                onLaunch: onLaunch,
                                menu: menu
                            )
                            .id(item.id)
                        }
                    }
                    // Plain padding is fine here: there are no scroll targets
                    // to keep measured on the covers, only explicit scrollTo.
                    .padding(.horizontal, inset)
                }
                .coordinateSpace(name: legacyCarouselSpace)
                // A held finger must not be fought by the snap.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in driver.isDragging = true }
                        .onEnded { _ in
                            driver.isDragging = false
                            scheduleSnap(scroller)
                        }
                )
                .compatOnChange(of: gamesKey, initial: true) { _, _ in
                    rebuildItems()
                    jumpToCentered(scroller)
                }
                .compatOnChange(of: proxy.size.width) { _, _ in
                    jumpToCentered(scroller)
                }
                .onAppear { lastConsumedStep = stepAccumulator }
                .compatOnChange(of: stepAccumulator) { _, new in
                    let delta = new - lastConsumedStep
                    lastConsumedStep = new
                    if delta != 0 { step(by: delta, scroller) }
                }
            }
        }
        .compatSelectionHaptic(trigger: hapticTrigger)
        .opacity(dimmed ? 0.55 : 1)
    }

    private func rebuildItems() {
        let built = CarouselLayout.items(for: games)
        items = built.items
        middleRepeat = built.middleRepeat
        // Keep the current cover if it survived the rebuild; otherwise start
        // on the first game in the middle repeat.
        if let centeredID, built.items.contains(where: { $0.id == centeredID }) { return }
        if let first = games.first {
            centeredID = "\(built.middleRepeat)-\(first.titleID)"
        } else {
            centeredID = nil
        }
    }

    /// Puts the centred cover back in the middle without animation, after the
    /// list or the viewport changed. Deferred a beat so the lazy row has laid
    /// out the target.
    private func jumpToCentered(_ scroller: ScrollViewProxy) {
        guard let id = centeredID else { return }
        driver.suppress(for: 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            scroller.scrollTo(id, anchor: .center)
        }
    }

    /// A cover reported itself within half a stride of the centre.
    private func nearCenter(_ id: String) {
        guard !driver.isSuppressed, id != centeredID,
              let titleID = CarouselLayout.titleID(from: id) else { return }
        let hadCenter = centeredID != nil
        centeredID = id
        if hadCenter {
            hapticTrigger += 1
            HomeSoundEffects.play(.tick)
        }
        // Touch scrolling drives the pad focus too, so picking the controller
        // back up continues from the visible cover.
        if padFocusedTitleID != titleID {
            padFocusedTitleID = titleID
        }
    }

    /// Any cover moved: (re)start the quiet-period timer for the snap.
    private func motion(_ scroller: ScrollViewProxy) {
        guard !driver.isSuppressed else { return }
        scheduleSnap(scroller)
    }

    private func scheduleSnap(_ scroller: ScrollViewProxy) {
        driver.settle(after: 0.22) {
            guard !driver.isDragging, let id = centeredID else { return }
            driver.suppress(for: 0.45)
            withAnimation(.easeOut(duration: 0.25)) {
                scroller.scrollTo(id, anchor: .center)
            }
        }
    }

    /// Advances the centred cover by `direction` items in the flat repeated
    /// list, continuing into the next repeat rather than wrapping back.
    private func step(by direction: Int, _ scroller: ScrollViewProxy) {
        guard let current = centeredID,
              let index = items.firstIndex(where: { $0.id == current }) else { return }
        let next = index + direction
        guard items.indices.contains(next) else { return }
        let target = items[next]
        centeredID = target.id
        padFocusedTitleID = target.game.titleID
        hapticTrigger += 1
        HomeSoundEffects.play(.tick)
        // Acknowledge every press immediately, as the iOS 17 path does; the
        // suppress window keeps the covers sweeping past from being read as a
        // new choice.
        driver.suppress(for: 0.3)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scroller.scrollTo(target.id, anchor: .center)
        }
    }
}
