import Testing
import WindowSwitchCore

@MainActor struct ShortcutKeyReleaseTests {
    @Test func tabReleasedBeforeModifierNeedsNoWait() {
        let press = ShortcutKeyRelease(isHeld: true)
        press.release()
        #expect(!press.shouldWait(elapsed: 0))
    }

    @Test func modifierReleasedBeforeTabWaitsForItsOwnKeyUp() {
        let press = ShortcutKeyRelease(isHeld: true)
        #expect(press.shouldWait(elapsed: 0.01))
        press.release()
        #expect(!press.shouldWait(elapsed: 0.02))
    }

    @Test func nextPressDoesNotResetTheSubmittedPress() {
        let submitted = ShortcutKeyRelease(isHeld: true)
        submitted.release()
        let next = ShortcutKeyRelease(isHeld: true)
        #expect(!submitted.shouldWait(elapsed: 0.01))
        #expect(next.shouldWait(elapsed: 0.01))
        next.cancel()
        #expect(!submitted.isCancelled)
        #expect(!next.shouldWait(elapsed: 0.01))
    }

    @Test func cancellationStopsOnlyTheUnsubmittedGesture() {
        let abandoned = ShortcutKeyRelease(isHeld: true)
        abandoned.cancel()
        let next = ShortcutKeyRelease(isHeld: true)
        #expect(abandoned.isCancelled)
        #expect(!abandoned.shouldWait(elapsed: 0))
        #expect(next.shouldWait(elapsed: 0))
    }

    @Test func missingKeyUpHasABoundedWaitAndProgrammaticStartsCanBeReleased() {
        let press = ShortcutKeyRelease(isHeld: true)
        #expect(press.shouldWait(elapsed: 0.249))
        #expect(!press.shouldWait(elapsed: 0.25))
        let programmatic = ShortcutKeyRelease(isHeld: false, eventDriven: false)
        #expect(!programmatic.shouldWait(elapsed: 0))
    }
}
