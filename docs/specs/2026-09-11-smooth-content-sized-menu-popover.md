# Smooth Content-Sized Menu Popover

**Goal:** Make Beanvan's menu bar popover open at the natural height of the active view and animate smoothly between the shorter main view and taller settings view on macOS Tahoe.

**Approach:** Replace the SwiftUI-managed `MenuBarExtra` window with a public AppKit `NSStatusItem` and `NSPopover`, while continuing to render the status icon and popover contents in SwiftUI. A small `NSHostingController` subclass will forward changes to its `preferredContentSize` to the owned popover, and `NSPopover` will perform the native animated resize through its `contentSize` behavior. This is more reliable than manipulating the private window created by `MenuBarExtra` and is the public mechanism that explicitly supports animated size changes.

## Background

The current `320x475` root frame prevents Tahoe from initially collapsing the main view's unconstrained vertical `ScrollView` to a few pixels. It also forces the shorter main view to occupy the settings view's height.

A pure SwiftUI prototype confirmed that combining `fixedSize(horizontal: false, vertical: true)` with `.windowResizability(.contentSize)` makes a window-style `MenuBarExtra` grow and shrink correctly on Tahoe. However, the host window changes directly between the old and new heights. SwiftUI animates the content transition, but not the host window geometry.

AppKit's [`NSPopover.contentSize`](https://developer.apple.com/documentation/appkit/nspopover/contentsize) is designed for this case. Apple documents that changing the content size while a popover is shown animates the popover when `animates` is enabled. `NSHostingController.sizingOptions` with `.preferredContentSize` keeps the AppKit container informed of the SwiftUI hierarchy's ideal size.

## Design

### Popover ownership

- A main-actor menu bar popover controller will own one `NSStatusItem`, one persistent `NSPopover`, and the SwiftUI hosting controllers needed for their content.
- The status item button will toggle the popover. The popover will use transient behavior so clicking outside closes it.
- The popover will be anchored to the status item button, allowing AppKit to position it correctly on the active display.
- The controller will be retained by `AppDelegate` for the application lifetime.
- The existing SwiftUI `MenuBarExtra` scene and the `MenuBarExtraPresenter` window-hierarchy search will be removed. Notification selection will call the owned controller's `show()` method directly.

### SwiftUI reuse

- `CoffeePopover` remains the popover content and retains its existing state, transitions, settings persistence, and actions.
- `MenuBarTruckIcon` remains the status item content so steam, proposal, bounce, skip-today, and accessibility behavior are preserved.
- The SwiftUI status icon will be hosted inside the status item button without intercepting the button's pointer events.
- Startup failure content remains available in the popover when application dependencies cannot be created.

### Size propagation and animation

- The popover width remains fixed at 320 points. The fixed 475-point root height is removed.
- Every hosted root, including startup failure content, receives the same 320-point width. Preferred widths reported by child views are ignored when updating the popover.
- The main view's vertical `ScrollView` uses `fixedSize(horizontal: false, vertical: true)` so it reports its content height instead of its near-zero minimum height.
- The popover hosting controller uses `sizingOptions = [.preferredContentSize]`. A subclass observes assignments to `preferredContentSize` and invokes a main-actor size-change callback when the height changes.
- The controller normalizes every callback to `NSSize(width: 320, height: preferredHeight)` and assigns it to `NSPopover.contentSize`. Duplicate sizes are ignored.
- Before the first presentation, the controller calls `sizeThatFits(in: CGSize(width: 320, height: .infinity))`, normalizes the returned width to 320, and assigns the result to `NSPopover.contentSize`. This prevents an initial default-size flash.
- The popover uses `animates = true`. Assigning a new normalized `contentSize` while the popover is shown asks AppKit to animate the popover window between the old and new heights. When the popover is closed, the size is updated without a visible transition so the next opening starts at the correct height.
- The existing SwiftUI transition remains responsible only for moving and fading the contents. AppKit is responsible for the outer popover geometry.
- No `GeometryReader`, hard-coded per-screen height, timer-driven interpolation, private API, or search through `NSApp.windows` will control sizing.

### Lifecycle behavior

- Opening the status item shows the existing hosted root view rather than recreating application services.
- Closing and reopening preserves the same behavior and state lifetime as the current menu bar scene.
- Selecting a proposal notification activates the app and asks the controller to show the popover.
- Application termination releases the controller alongside the existing scheduler, proposal store, and peer manager shutdown.

## Verification

An automated test will prove that assigning a new `preferredContentSize` to the hosting-controller subclass invokes its size-change callback and that the controller-facing size is normalized to a 320-point width. Existing menu bar icon state tests remain. The fixed `CGSize(width: 320, height: 475)` assertion is replaced with a fixed-width policy check. The full `swift test` suite and debug application build must pass.

Manual verification on macOS Tahoe must confirm:

1. The first opening is 320 points wide and only as tall as the main content, with every control in the current main view reachable.
2. Opening settings smoothly grows the outer popover to the settings content height.
3. Returning to the main view smoothly shrinks the outer popover without transparent space.
4. The bounded maximum state of one displayed proposal and three schedule entries produces an appropriate content height without clipping.
5. Clicking outside closes the popover, clicking the status item toggles it, and selecting a proposal notification opens it.
6. Steam, proposal badge, bounce, skip-today opacity, accessibility labeling, and multi-display anchoring continue to work.

This is a single-PR change within the Beanvan executable module. It does not require a separate refactor or staged delivery.

## Out of Scope

- Making the popover manually resizable by the user.
- Changing the main view, settings fields, status icon design, or application behavior unrelated to presentation.
- Reimplementing AppKit's popover animation with custom frame interpolation.
- Supporting undocumented access to SwiftUI's internal `MenuBarExtra` host window.
- Generalizing the layout for future content whose natural height exceeds the active display. Beanvan's current variable content is bounded and must fit during manual verification.

## Success Criteria

- The main view opens at its natural content height on Tahoe rather than a few pixels or the settings height.
- The popover grows and shrinks smoothly as its active SwiftUI content changes.
- No transparent retained outline appears after returning from settings.
- Width remains fixed at 320 points.
- Existing status item, notification, settings, and application lifecycle behavior remains intact.
- All automated tests and the packaged debug build pass.
