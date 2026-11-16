# Admin widgets, enhanced

Every Bloem Admin widget in every family, dark and light, drawn from `WidgetSamples` (invented names and numbers; nothing here is a real
server). The widgets are the app's page with the cards of the app's own lists on it; `with-app/` puts each one beside the app page it stands for.

| Folder | What is in it |
|---|---|
| `<widget>-<family>-<dark or light>.png` | Server status, Now playing, Requests, Libraries and Nodes, at small, medium, large, extra large (iPad), circular, rectangular and inline |
| `with-app/` | The app's page on the left, then the widget at medium, large and small, and the three lock screen shapes. `-extra-large` is the iPad widget beside the page |
| `states/` | Loading, signed out, can't reach (with the last data and its time), not available on this server, nothing to show, stale, action failed, and a server that is down |
| `streams/` | Now playing with no stream, one stream and seven (`streams-0`, `-1`, `-7`): the count in the header, and at seven the page buttons; `streams-7-page-2` is the second page, and `streams-7-lock-details-off` the counts-only view |
| `large-text/` | The medium and large widgets at the accessibility text size: fewer cards, none cut off |
| `lock-screen/` | The lock screen shapes with "Show details on the lock screen" off and on |
| `live-activity-lock-screen-*.png` | The scan and backup Live Activity |

Sizes are an iPhone 15's (small 170 x 170, medium 364 x 170, large 364 x 382 points) and an 11-inch iPad's extra large (726 x 378). Moving
timers are drawn by the system, not by a view, so the images show the still values of one moment (the sample streams are read at 1:12:10 and so on).
Numbers follow the locale of the Mac that rendered them.

To make them again: create `/tmp/bloem-widget-shots` on the Mac running the simulator, run `BloemAdminTests/WidgetRenderTests` with
`xcodebuild test`, copy the folder back, and run `python3 -I scripts/compose-widget-shots.py <renders> docs/screenshots/bloem-look/after <this folder>`.
