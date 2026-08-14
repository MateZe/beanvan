# Beanvan

![Beanvan animation](docs/beanvan-animation.gif)

## Manual peer discovery test

Launch each instance in a separate Terminal window:

```sh
make run-a PHRASE=coffee-team
make run-b PHRASE=coffee-team
swift run Beanvan --name "Beanvan C" --port 0 --phrase different-team
```

Open each truck menu-bar popover and check the live presence row near the top:

- A and B should list each other within about two seconds.
- C should list no peers, and C should not appear in A or B.
- Quit B from its menu. It should disappear from A.
- Run `make run-b PHRASE=coffee-team` again. A and B should list each other again.

The popover also provides the real schedule editor. Add a time on A or change its
time or weekdays. B should update within about two seconds and show the latest
attribution below the schedule. Display name and team phrase changes are applied
from **Settings**. Applying either setting restarts Bonjour discovery and advertising,
so the presence list briefly clears and then repopulates with matching peers.

Omit `PHRASE` or pass an empty value to test the shared default phrase:

```sh
make run-a
make run-b
```

## Manual coffee proposal test

Launch three instances with the same phrase and leave the quorum at its default of 3. In A, choose **Propose coffee now**. B and C should quietly show A's proposal card and a teal dot on the menu-bar truck without showing the overlay.

Choose **I'm in** on B. Every instance should show `2/3`, with no overlay yet. Choose **I'm in** on C. The overlay should now run once on A, B, and C because all three are participants. A client that did not accept would not run it.

For expiry, raise the quorum above the team size and create another proposal after the cooldown. The proposal and filled icon should disappear silently after five minutes.

## Automatic overlay suppression

Immediately before a scheduled or quorum-triggered overlay, Beanvan locally
suppresses the animation while the screen is locked, the displays are asleep, or
an enabled interruption preference matches the frontmost app. The full-screen
and known meeting-app checks are enabled by default in Settings. Suppression is
local only and does not change what happens on teammates' Macs. Preview remains
available as an explicit action.

Focus / Do Not Disturb is not checked. macOS does not provide a reliable public,
permission-free API for reading its current state, and Beanvan does not use
private APIs or request Screen Recording, Accessibility, or Input Monitoring.

To test full-screen suppression, schedule a fire a minute or two ahead, enter
macOS full-screen in the frontmost app, and leave that app frontmost through the
scheduled time. A merely maximized window still leaves the menu-bar area free
and intentionally does not count as full-screen.

To test meeting suppression, open Zoom Workplace, Microsoft Teams, Webex, or
Around and leave that native app frontmost through a scheduled fire. No real
call is necessary because the heuristic only checks that a known meeting app is
both running and frontmost. Browser-based calls and calls whose native app is in
the background do not match this heuristic.
