# Design rules

How Bloem Admin looks, reads and behaves where the platform lets it reach outside its window. The code is the source
of truth: colours, type, spacing and shapes live in `BloemAdmin/Theme/` and `BloemAdmin/Shared/BloemFont.swift`.
`LookGuardTests`, `WidgetLookTests` and `PushSourceGuardTests` read this file and fail the build when the icon, font,
copy, widget or push rules below drift from the code.

The character is steady, exact and a little warm: a control room at night, graphite surfaces and one orange light. Each
screen's one live figure or chart carries the richness, and everything around it stays quiet.

## Colour

Both a dark and a light scheme ship. The app follows the system setting by default; Settings can override it with System,
Light or Dark.

| Token | Dark | Light | Use |
|---|---|---|---|
| canvas | #141417 | #F6F6F8 | page |
| sidebar | #0F0F12 | #EEEEF2 | menu |
| card | #1C1C20 | #FFFFFF | rows, panels, cards |
| raised | #28282E | #E9E9EE | filled fields, chips, dialogs, pressed |
| selected | #202023 | #DDDDE1 | current page, chosen row |
| hairline | #E8E8EC at 8% | #1A1A1F at 10% | dividers, card edges |
| text | #E8E8EC | #1A1A1F | primary text |
| muted | #A4A4AE | #5A5A65 | secondary text |
| outline | #787882 | #85858F | field and control outlines |
| accent | #FA6400 | #A04000 | the one accent, as text or as a fill |
| onAccent | #141417 | #FFFFFF | text on an accent fill |
| tally | #FA6400 | #E85D00 | the live dot only |
| ok | #57CB60 | #1A6A2B | |
| warning | #EAB532 | #7F4E00 | |
| danger | #F46666 | #B42626 | |
| onDanger | #141417 | #FFFFFF | |

- **Accent** is for the primary action, the current selection and the one figure that matters. Nothing else.
- **Tally dot:** the orange dot means something is live right now or needs attention. It is never decoration.
- **Charts** use this order: #5F74EE, #169E88, #BF7F22, #C2578F, #3F97CF. A single-series chart uses the accent for the
  series that matters and neutral steps for the rest.
- **Depth:** on dark it comes from surface steps and hairlines, with no shadows. On light, shadows are small, soft and
  neutral. No gradients, glows or tinted surfaces.
- **Contrast:** every text colour reaches 4.5:1 on every surface of its scheme, and outlines reach 3:1.

## Type

- **Font:** Plus Jakarta Sans (SIL OFL 1.1), bundled as one variable font and registered through Info.plist
  `UIAppFonts`. Views use the named styles of `BloemFont` (`.bloemText(...)`), never `.font(...)` and never a system font.
- **Weights:** 400 for reading, 500 for labels and row titles, 600 for headings.
- **Scale (size / line height):** display 45/52, 36/44, 32/40; headline 28/36, 24/32, 22/28; title large 20/28, title
  medium 16/24, title small 14/20; body 16/24, 14/20, 12/16; label 14/20, 12/16, 11/16. Dynamic Type still scales them.
- **Numbers** use tabular figures.
- **Treatments:** sentence case everywhere. No all-caps tracked labels, no italic for emphasis, no negative tracking on
  small text.

## Spacing and shape

- **Grid:** everything sits on a 4 point grid: 4, 8, 12, 16, 24, 32. Touch targets are at least 44 points.
- **Padding:** compact rows and panels 16, cards 16 to 20, page edges 16 on an iPhone and 24 to 32 on an iPad.
- **Radii:** controls (buttons, fields, chips, rows) 10; cards 12; large surfaces and sheets 16; inner marks 4. A nested
  radius is the outer radius minus the padding. Not everything is a pill.
- **Equal things are equal:** rows in one list share a height and gap, and cards in one row share a padding.

## Icons

- **Set:** Lucide (ISC), the subset the app uses, shipped as SVG in asset catalogs with Preserve Vector Data and drawn as
  template images named `lucide.<name>`. No SF Symbols.
- **Size:** 18 in rows and menus, 20 in top bars, 16 inline, with a 1.5 stroke.
- **Colour:** an icon takes its text role's colour, usually muted. It never gets a colour of its own.
- **Names for the concepts the app uses:**

| Concept | Lucide icon |
|---|---|
| Dashboard | layout-dashboard |
| Now playing, live | radio |
| Servers | server |
| Users, people | users |
| One user | user |
| Organizations | building-2 |
| Libraries | library |
| Requests | inbox |
| Playback history | history |
| Logs | scroll-text |
| Audit | shield-check |
| Settings | settings |
| Scheduled tasks | calendar-clock |
| Nodes | cpu |
| Backups | archive |
| Plugins | puzzle |
| API keys | key-round |
| Alerts | bell |
| Search | search |
| Add | plus |
| Refresh, retry | rotate-cw |
| More | ellipsis |
| Back, disclosure | chevron-left, chevron-right |
| Sign out | log-out |
| Lock | lock |
| Warning, success, error | triangle-alert, circle-check, circle-x |
| External link, copy, share | external-link, copy, share |

- **No emoji** anywhere in the interface. Where a category needs colour, use a small status dot.

## App icon

The Bloem Studios tulip on a dark graphite plate (#141417) with a small Lucide `server` badge. The masters are in
[design/app-icons/](design/app-icons/README.md). The iOS icon set has a default, a dark and a tinted variant.

## Patterns

- **Shell:** a top bar with the page title and the server switcher, a menu in sentence-case groups, and the foot of the
  menu holding Settings and Sign out. A sidebar of 240 to 280 points on an iPad. No bottom bars.
- **Buttons:** primary is an accent fill with onAccent text, one per screen. Secondary is a `raised` fill. Destructive
  actions use danger text, and a confirmation names the thing being changed. Labels are verbs in sentence case.
- **Lists and cards:** cards have hairline edges. Counts and meta are muted text, not pills. Status is a small dot plus a
  word.
- **States:** an empty state says what goes there and offers the one action that fills it. An error says what went wrong
  and how to fix it, with a Try again action, and never apologizes. Loading uses a quiet progress indicator, never a
  shimmer on headings.
- **App lock:** when the lock is on, the system prompt (Face ID, Touch ID or the passcode) opens by itself as the lock
  screen appears. The Unlock button stays behind it as the fallback. If the prompt is cancelled or fails it does not
  reopen in a loop; the button retries, and the next return to the app opens it again.
- **Motion:** one standard easing curve. Short durations: 150 to 200 ms for feedback, 250 ms for entering. No loops
  except live indicators, no bounce.

## Copy

- Sentence case. No exclamation marks. No trailing period on titles, labels, buttons or captions; only paragraphs keep
  theirs. No greeting headlines.
- The same words everywhere: Sign in, Sign out, Add server, Remove, Save changes, Try again, Cancel, Done, Search, Now
  playing, Playback history, Scheduled tasks.
- **The app is "Bloem Admin".** It never names itself "Silo". "Silo" appears only where it names the server product the
  app administers, as in "Silo server" and "Add a Silo server".
- A change states what it compares to, for example "+12% vs last week".
- The Bloem extras (organizations, platform administration, support access, push notifications) switch on only when the
  server is a Bloem server, detected with `GET /api/bloem/v2/capabilities`. On a plain Silo server they are simply absent,
  with no error and no empty page.

## Push notifications

A notification goes out only when something is **broken**, **waiting on the person**, or **about money**. Routine
activity never notifies. This app has no money kinds.

**Push works only with a Bloem server, in the official build.** A Bloem server sends through the Bloem push relay, which
holds the Apple credentials; the relay never sees notification content. The push credentials belong to the official
build, so a build you make yourself, under another team and bundle identifier, does not receive push. A Silo server has no push for this app: its own relay
cannot reach it. On a Silo server the app keeps its own local server-down and server-up checks and every other kind is
unavailable. Settings says so plainly, with no error.

- **Modes:** the relay sends a generic alert, and a notification service extension fetches the real title and body from
  the app's own server and replaces the generic text. If the fetch fails, the generic text stays.
- **Settings → Notifications** lists every kind with its own switch, per server. All kinds are on by default. A switch
  tells the server, which then stops sending that kind to this phone.
- **Permission** is asked after the first successful sign-in to a server that can push, never at launch.
- **Lock screen** follows the per-device "Show details on the lock screen" setting, off by default. Off, a notification
  shows only the lock-screen text below.
- **Buttons** (Approve and Decline) need the phone unlocked. A failed action posts "Couldn't approve, open the app".
  Nothing destructive is ever offered.
- **Grouping:** by server and kind. A repeated event updates one notification. Down and up for one server replace each
  other.
- **Token lifecycle:** the phone registers on sign-in and when the push token changes, and unregisters on sign-out and when
  a server is removed.

The kind IDs are stable keys: payloads, switches and analytics use them. On the lock screen only the "Lock screen" text
shows unless details are allowed.

| Kind ID | When | Title / body (details on) | Lock screen | Tap opens | Buttons |
|---|---|---|---|---|---|
| `admin.server_down` | a server stops answering (the app's own check) | "Can't reach {server}" / "Last seen {time}" | "A server can't be reached" | that server | none |
| `admin.server_up` | it answers again (the app's own check) | "{server} is back" / "Down for {duration}" | "A server is back" | that server | none |
| `admin.request_waiting` | a media request is waiting for approval | "{user} requested {title}" / "{n} waiting" | "New request waiting" | the request | Approve, Decline |
| `admin.scan_failed` | a library scan failed, or its storage is unreachable | "Scan failed: {library}" / reason | "A library scan failed" | that library | none |
| `admin.backup_failed` | a backup failed | "Backup failed on {server}" / reason | "A backup failed" | Backups | none |
| `admin.node_offline` | a node went offline | "{node} is offline" / since {time} | "A node is offline" | Nodes | none |
| `admin.plugin_failed` | a plugin failed or needs attention | "{plugin} needs attention" / reason | "A plugin needs attention" | that plugin | none |

The first two are made by the app on the phone, because a server that is down cannot push. They work against every
server. The others need a Bloem server with push turned on.

## Widgets

Five widgets, two controls and a Live Activity. They are the app's pages in small: the same cards, the same states and the
same words.

| Widget | Families | Content | Button |
|---|---|---|---|
| Server status | small, medium, large, circular, rectangular, inline | Up or down per saved server, with the live stream count and the requests waiting | Refresh |
| Now playing | small, medium, large, extra large, circular, rectangular, inline | The streams playing now as session cards: title, who, how it plays, progress, bitrate | Refresh |
| Requests | small, medium, large, circular | The pending count, and the newest requests with title, who and age | Approve, Decline |
| Libraries and scans | medium, large | Each library's last scan and warnings; a running scan's progress | Refresh |
| Nodes and resources | medium, large | Per node: state, CPU, memory and disk | Refresh |

- **Controls (iOS 18):** Now playing opens that page; Requests waiting shows the count and opens Requests.
- **Live Activity:** a library scan or a backup started from the app, with progress where the server reports it.
- **Look:** the `card` surface on `canvas`, the text roles text and muted, one accent for the one figure that matters, the
  tally dot for live or needs-you, Lucide icons and Plus Jakarta Sans, which the extension bundles. Dark and light follow
  the system or the app's Appearance setting. Every gallery name and description starts with "Bloem Admin".
- **Configuration:** each widget lets you pick a server; the default is all servers.
- **States:** loading (a quiet placeholder), signed out ("Sign in to see now playing"), server unreachable ("Can't reach
  {server}" with the last data and its time), empty ("Nothing playing"), not available on this server (said plainly), and
  counts only on the lock screen, StandBy and Always On.
- **Data:** widgets fetch for themselves with the app's own sign-in, shared through a keychain access group and the App
  Group. The timeline reloads about every 15 minutes, and about every 5 while something is active. Data older than its
  window says "Updated 14:32"; nothing is shown as current when it is not. Widgets never open a socket.
- **Wakes:** a Bloem server can wake the app with a silent push when something a widget shows has changed, so the widget
  reloads sooner. A Silo server cannot, so there widgets keep only their periodic refresh.
- **Privacy:** the lock screen, StandBy and Always On show counts and statuses only, with no names or titles, unless "Show
  details on the lock screen" is on (off by default, set per device). On an unlocked phone the home-screen widgets show
  full detail; the phone's own unlock is the gate, and the app lock only guards opening the app.
- **Taps:** a widget opens the exact page through the app's `bloemadmin://` links. A request, library or plugin card opens
  its own item.
- **Buttons:** only quick, reversible things: Refresh, and Approve or Decline a request, which need an unlocked phone. A
  failure shows "Couldn't approve, open the app". Nothing destructive is ever offered from a widget.

## Live updates

The app cuts polling wherever the server offers a WebSocket. The socket says only **what changed**: a channel, an item id
and a revision. The app then re-reads the item through the REST API, which stays the single source of truth, so a lost or
late signal never leaves wrong data on screen.

- **Silo and Bloem servers:** the events socket (`/api/v2/events/ws`), opened with a single-use ticket. Now playing, library
  scans, scheduled tasks, jobs and the request badge follow its channels instead of a timer.
- **Bloem servers only:** the organization socket (`/api/bloem/v2/organization/live/ws`, protocol `bloem-live.v1`), opened
  with a ticket minted by the organization's context pass. Its channels are `org.streams`, `org.people` and
  `org.activity`, and a server advertises it with the feature token `organization_live_v1`. Without it the organization
  pages poll.
- **Foreground only:** connect when the app is on screen, disconnect 10 seconds after it leaves. Push covers the time in
  the background.
- **Reconnect:** exponential backoff with full jitter, 1 s up to 60 s, with a new ticket each time. Reconnect at once when the
  app returns to the foreground or the network changes. A frame is expected at least every 25 seconds; after 60 seconds of
  silence the socket is treated as dead.
- **Fallback:** only after three failed attempts in a row, poll the visible screen at most once every 60 seconds, and stop
  as soon as the socket is back. Never poll in the background.
- **Screens with no channel** (dashboard trend charts and the like) refresh when opened and on pull to refresh.
