# Alerts, links, widgets and shortcuts

Bloem Admin reaches outside its own window in seven ways: server alerts, links into the app, Home Screen and
Lock Screen widgets, Control Center controls, a Live Activity, App Shortcuts, and Home Screen quick actions. This page says
what each one does, what it needs, what it shows or stores outside the app, and how to turn it off. The same
points are summed up in [Everything that is new](#everything-that-is-new) and [Turning it all off](#turning-it-all-off).

Server alerts are local notifications made by the app itself after it checks each server's public health
route, and they work against every server. [Push notifications](#push-notifications) are a separate thing, and they
need a Bloem server and the official build of the app. **On a Silo server, push notifications and widget wakes are
not available.** A Silo server's own push relay cannot reach this app, so there you get the server alerts and the
widgets' periodic refresh, and nothing else. A server run by Bloem sends push through the Bloem push relay, and only the
official build, signed by the maintainers, can receive it: the push credentials belong to that build, so an app you
build yourself under your own team does not get push, even from a Bloem server.

## Server alerts

**What it does.** The app asks every saved server `GET /api/v1/health` and tells you when one stops
answering. A server is reported after two failed checks in a row, and reported again when it answers. One
failed check never alerts, and a check the phone could not make (no network, airplane mode) counts for
nothing. Failures less than a minute apart count once.

**What counts as down.** No answer, a timeout, a failed secure connection, or an HTTP 5xx. Any other answer
(even a refusal from a proxy in front of the server) means something is listening, so the server counts as up.

**When it runs.**

- When the app comes to the foreground.
- In the background, as an iOS background app refresh task (`com.bloemstudios.admin.health-check`). The app
  asks for one about every 15 minutes, but iOS decides when, and how often, it really runs: often hours apart,
  never in Low Power Mode, never when Background App Refresh is off for the app, and not after you force-quit
  the app until you open it again. Settings says so in one line.
- Only while alerts are on and at least one saved server has its own switch on. Removing a server removes its
  settings and its state at the next check, and when no saved server has alerts on the background task is
  cancelled.

**Permission.** The app asks iOS for permission to notify at one moment: when you turn on "Alert when a
server stops answering" in Settings, the first time. It never asks at launch, on opening Settings, or
during a background check. If you refuse, the switch stays off and Settings says notifications are off
for Bloem Admin in iOS Settings, with a button that opens them. If you later take the permission back in iOS
Settings, the switch shows off and no alert is made.

**Switches (Settings, Server alerts).** All are off until you turn them on.

| Switch | Meaning |
|---|---|
| Alert when a server stops answering | The master switch. Turning it on is when iOS asks for permission. |
| Servers to watch (one per saved server) | Whether this server alerts. Every saved server is still checked while alerts are on, so widgets stay fresh, but only the servers switched on notify you. |
| Show details on the lock screen | Per device. Off by default. |

**What a notification says.** By default only the server's name and a generic line:

- "Can't reach {server name}", with "Open Bloem Admin to check the server"
- "{server name} is answering again", with "Open Bloem Admin to see it"

With "Show details on the lock screen" on, the line also says when it stopped answering and why, for example
"No answer since 14:05 (timed out)". A notification never contains a title, a user name, an email address,
an IP address or a server address, with details on or off. Tapping one opens that server, after the app lock.
A new notice for a server replaces its earlier one.

**Sign-in.** None. The check sends one GET with no credentials, cookies or body and never reads a stored
token; the code that runs in the background has no access to the sign-in store, and a test keeps it that way.

## Links into the app

The app has its own URL scheme, `bloemadmin://`. It is not the OAuth redirect scheme (`org.siloserver.silo`,
used only inside a sign-in session), so the two cannot be mistaken for each other. There are no universal
links.

| Link | Opens |
|---|---|
| `bloemadmin://all` | All servers, Now playing |
| `bloemadmin://all/{page}` | All servers, that page |
| `bloemadmin://server/{serverId}` | That server, Now playing |
| `bloemadmin://server/{serverId}/{page}` | That server, that page |

`{page}` is a menu page id: `live.streams` (Now playing), `overview.dashboard` (Dashboard) and
`work.requests` (Requests) are the ones the app's own surfaces use; any other platform page id from the menu
also works (`work.jobs`, `people.users`, `system.audit`, …). The Android app uses the same ids.

Rules:

- A link only moves the app to a page. It never changes anything on a server.
- It goes through the app lock first: a link that arrives while the app is locked waits and is applied after
  you unlock. The admin gate still decides whether the account may see the page.
- A server id the app does not have saved changes nothing. A page that is not in the menu opens Now playing.
- Anything that is not exactly one of the forms above is refused: another scheme, extra path segments, a
  query, a fragment, a port, sign-in details, or an id with anything beyond letters, digits, dots,
  underscores and dashes.

Notifications, widgets, the control, App Shortcuts and quick actions all use these links.

## Widgets

Five widgets, all following the rules and the look in [design.md](design.md) (Plus Jakarta Sans, Lucide icons, the card
surface, one accent).
A widget is the app's page (`canvas`) with the cards of the app's own lists on it: a Now playing card is the
Now playing page's session card in small. Long-press a widget to choose one saved server, or leave it empty for
all servers. They follow the system's dark or light setting, or the app's own Appearance choice.

Every widget's header starts with the app's tag: the tulip mark with the admin app's server badge and "Bloem Admin" (the name under the app's
icon) in muted text, so widgets of the three Bloem apps cannot be confused; a small widget shows the mark only. In the widget gallery every
widget and control is named "Bloem Admin: ..." and its description starts the same way.

Every widget comes in every family that makes sense: small, medium, large, extra large on an iPad (two columns),
and the lock screen's circular, rectangular and inline shapes. iOS does not resize a widget freely, so each
family has its own layout, and inside one the number of cards follows the height and the detail in a card follows
the width.

| Widget | What it shows | Buttons |
|---|---|---|
| Server status | Whether each saved server answers, with the live stream count and the requests waiting. The tally dot sits by the stream count while a stream is live, and by the status when a server is down. Small: the stream count. Medium: a card of the figures and a card per server. Large and extra large: a card per server and the totals. | Refresh |
| Now playing | The streams as the app's session cards: the title, "user · profile", the playback method with its dot (Direct play, Remux, Direct stream, Transcode), how far with "1:12:10 / 2:46:00" and the bitrate, and Playing or Paused. Small: the count and the top stream. Medium: two compact cards. Large: three roomy cards and the totals. Extra large: the whole card, with the Source to Playback to Client path and the transcode detail, in two columns. The header always says how many streams are live ("3 streams", "1 stream", "No streams"). WidgetKit cannot scroll, so when there are more streams than fit, medium and larger sizes page: "1/3" with Up and Down in the header (the page is kept in the App Group and goes back to the first after 5 minutes). | Refresh, Up and Down (page) |
| Requests | Small: the number waiting and the newest request. Medium to extra large: request cards with title, who and age. | Approve and Decline on each card |
| Libraries and scans | A card per library, those needing a look first: its last scan or a running scan's progress, and its warning. | Refresh |
| Nodes and resources | A card per node: its state and CPU, memory and disk as three small bars. | Refresh |

Tapping a widget opens the page it shows (Now playing, Requests, Libraries or Nodes) for that server, or all
servers, through the app's links, so the app lock applies. Each row opens its own server's page. A link names
a page for a stream or a node, because the app has no focus for one of those yet; a request card and a library card
open that request or that library (`bloemadmin://server/{id}/work.requests/{requestId}`), and the app scrolls to it.

**Live data.** The widgets read the servers themselves, with the app's own sign-in (see below), and keep
the last good data. Their timeline asks for a refresh in about 15 minutes, as iOS allows, or in about 5 while a
stream plays or a scan runs. Now playing also has an entry at the moment each stream should end, so its bars and
times move, and an ended stream comes off the card, with no request in between (the system moves
`ProgressView(timerInterval:)` and `Text(timerInterval:)` by itself). They reload sooner when the app saves new
data, when a setting they honour changes, when someone taps Refresh, while the app is open and its live socket
reports a change (at most once every 10 seconds per widget), and when the server's silent wake names what they
show. Every one of those goes through `WidgetReload`, the one place a reload is asked for. Data older than 20
minutes stops moving and says "Updated 14:32" in muted text; nothing old is shown as current. Server status keeps
its public health check, which needs no sign-in, so it works with no one signed in.

**States**, for every widget at every size: loading (a quiet placeholder, no shimmer); signed out ("Sign in to
see requests", which opens the app); server unreachable ("Can't reach Home", with the last data and its time);
not available on this server ("Requests aren't available on this server", for example on a plain Silo server
with no request administration); empty ("Nothing playing").

**Privacy.**

- The app's own lock does not reduce what a home-screen widget shows. On an unlocked phone the home screen
  shows full detail and the buttons work. The phone's unlock is the gate; the app lock only guards opening the
  app.
- The lock screen, StandBy and Always On show counts and statuses only: no user name, title or requester,
  unless "Show details on the lock screen" is on (Settings, Server alerts; this device only; off by
  default). Detail text is also marked `privacySensitive()`. The app mirrors the setting, and the Appearance
  choice, to `widget-settings.json` in the App Group; if that file is missing the widgets stay private.
- A server name is not a detail: it is shown on the lock screen, as in an alert.

**Buttons.** Refresh, Approve and Decline are App Intents with
`authenticationPolicy = .requiresAuthentication`, so the phone has to be unlocked to run them. Refresh reloads
every Silo widget. After a success
the request leaves the widget; after a failure the widget says "Couldn't approve, open the app" (or
"Couldn't decline, open the app") until the request is gone from a fresh list or ten minutes have passed.
Nothing destructive is ever offered from a widget: no delete, suspend, drain or sign out.

### How the widgets read the sign-in

This changes an earlier rule: the Server status widget used to read no sign-in at all. The background server
alert check and the snapshot still never touch one (a test keeps that), but the data widgets now do, with
The maintainer's approval (2026-11-15).

- **The mirror.** Next to its own credential store the app keeps a copy of each server's tokens in a *shared
  keychain access group*, `<team prefix>com.bloemstudios.admin.shared`, under its own service name
  (`com.bloemstudios.admin.widget-credentials.v1`). The app's own item is untouched. The mirror has the
  app's protection: readable only while the phone is unlocked, never leaving this device. On a locked phone a
  widget cannot read it, so it keeps its last data and does not say anything is wrong; it refreshes the next
  time iOS runs it on an unlocked phone.
- **What goes in it.** The access token and the refresh token, the time and who wrote it (app or widget). The
  app writes it when it signs in, refreshes or comes to the foreground (which also fills it for servers
  that were signed in before this update), and removes it on sign out or when a server is removed.
- **Refresh tokens rotate.** The server makes each refresh token single-use. So when a widget is told 401, it
  takes a lock in the App Group (`credential-refresh.lock`), looks at the mirror again (the app may have
  refreshed already), and only then refreshes, writing the rotated pair back before it lets go. The app takes
  the same lock for its own silent refresh and first takes back whatever a widget rotated, so neither spends a
  token the other already used. If the refresh fails the widget says "Sign in to see ..." and changes nothing.
- **What the widget sends.** `GET` requests to the admin routes it shows (sessions, request counts and the
  newest waiting requests, users for the requester's name, libraries, scan runs, library refresh jobs, node
  summaries) and, on a tap, `POST` approve or decline for one request. HTTPS only, no redirects, no cookies.
- **Where the data rests.** `widget-data.json` in the App Group: the last good result for each widget and
  server (this can hold user names and titles), protected until the first unlock, with no token in it. It is
  cleared of servers that are no longer saved.

If the keychain group is not enabled for the build (see Entitlements), the mirror cannot be written, and the
widgets say "Sign in to see ..." for everything except Server status, which keeps working.

## Push notifications

A Bloem server that lists the feature token `admin_push_v1` in `GET /api/bloem/v2/capabilities` pushes to this
phone only when something is broken or waiting on you. Routine activity never notifies. The kinds, and what each
says on the lock screen:

| Kind | When | Lock screen | A tap opens | Buttons |
|---|---|---|---|---|
| `admin.server_down` | a saved server stops answering (this app's own check) | A server can't be reached | that server | none |
| `admin.server_up` | it answers again (this app's own check) | A server is back | that server | none |
| `admin.request_waiting` | a request is waiting for approval | New request waiting | that request | Approve, Decline |
| `admin.scan_failed` | a library scan failed, or its storage can't be reached | A library scan failed | that library | none |
| `admin.backup_failed` | a backup failed | A backup failed | Backups | none |
| `admin.node_offline` | a node has been offline for two minutes | A node is offline | Nodes | none |
| `admin.plugin_failed` | a plugin failed | A plugin needs attention | that plugin | none |

The first two are made by the app on the phone, because a server that is down cannot push; they work on every
server. The others need a Bloem server with push on.

**How a push reaches the screen.** The server sends through the Bloem push relay, which holds the Apple credentials. The relay sends a generic alert (`mutable-content`) and a delivery id of the
form `{device id}.{delivery}`, and never sees any text. iOS hands that push to the notification service
extension (`com.bloemstudios.admin.NotificationService`) before it shows it. The extension picks the saved
server from the device id, reads `GET /api/bloem/v2/admin/push/content/{delivery id}` with that device's display
token, and replaces the generic text with the real title and body. It waits at most eight seconds; if the server
does not answer, or does not know the notification, the generic text stays ("New notification", "Open the app to
see it"). The app icon's number is the relay's count and the extension does not touch it.

**Privacy.** With "Show details on the lock screen" off (the default) a notification carries only the server's
lock-screen text from the table, with no name, title, count or server name anywhere in it, including its
hidden `userInfo`, which holds identifiers only. With it on, the title, body and server name show. The setting
reaches the extension through `push-settings.json` in the App Group; a missing or unreadable file means off. The
extension holds no sign-in: it reads one keychain item per server in the shared group (the display token, readable
after the first unlock because the extension runs while the phone is locked) and that one file. The display
token opens only that device's own notification text and its retire call.

**Buttons.** Approve and Decline need the phone unlocked (`.authenticationRequired`) and do not open the app.
They call the same route the widgets do, with the same sign-in mirror. A request someone else already answered
counts as done. If the call fails, the notification is replaced by "Couldn't approve, open the app" (or
"Couldn't decline, open the app"), which opens the request. Nothing destructive is ever offered.

**Grouping.** Notifications group by server and kind (`{server id}.{kind}`); the relay's collapse id makes a
repeating event update one notification. "A server can't be reached" and "A server is back" for one server share
a thread and each replaces the other.

**Registering.** The phone registers with each saved Bloem server that offers push, once the app has a token
from iOS and notifications are allowed: `POST /api/bloem/v2/admin/push/devices` with an installation id the
app generated, the APNs token, `apns_environment` (`sandbox` for Debug builds, `production` for Release) and the
topic `com.bloemstudios.admin`. It registers again when the APNs token changes, when another account signs in
to that server, after a sign-in, and when the last registration is a week old. It does not register when
nothing changed, because a registration replaces the display token. Each registration is stored with the server
and the account it came from.

Signing out of a server or removing it retires the device with its display token (`POST .../devices/{id}/retire`),
which needs no sign-in, and waits at most five seconds. If the server does not answer, the record stays marked
as being retired (the extension no longer uses it), and the app tries again at its next sign-in or foreground,
five times at most.

**When the server does not offer push.** A plain Silo server answers the capabilities route with 404; Silo's own
relay cannot reach this app, so nothing is sent to it and Settings says "Push isn't available on this server.
Only the server-down checks apply", with no error. A Bloem server that does not list `admin_push_v1`, or answers
the registration 404 or 503 (the routes are not deployed yet, or push delivery is off), is shown as "Push isn't
available on this server yet", also with no error. That server is asked again at the next sign-in, and at a
foreground once ten minutes have passed since it was last asked.

**Permission.** Asked once, when the first page (Now playing) has loaded its data and a signed-in server can push,
never straight after a sign-in, never at launch and never when a plain Silo server is added. Settings → Notifications also has an "Allow notifications" button for a phone
that has not been asked. If iOS has refused, Settings says "Notifications are off for this app in iOS Settings"
and how to turn them on, with a button that opens iOS Settings.

**Switches (Settings → Notifications).** One per kind per saved server, all on by default. A switch is kept on the
phone first and then sent (`PATCH .../devices/{id}/kinds`), after which the server stops sending that kind to this
phone, including notifications already queued. If the server cannot be told, the next registration sends every
switch again. "Server can't be reached" is the "Servers to watch" switch of Server alerts, and "Server is back" is its
own switch; both stay on the phone. A plain Silo server lists only those two.

**Widget wakes.** Widgets never open sockets. To keep them close to live in the background, a Bloem server that
has been told this phone has a widget placed sends a silent push (the relay's `background_wake`: `content-available`
at priority 5, no alert, no sound, no badge) when something a widget shows changed: a stream starts, stops or
pauses; a request arrives; a scan starts, ends or fails; a node goes offline or comes back. It carries no content,
only a delivery id of the form `{device id}.widgets-{channels}-{unix seconds}` (for example
`dev.widgets-nodes-requests-1763254800`), where the channels are the sorted whole names `libraries`, `nodes`,
`requests` and `sessions`. The server coalesces changes for 30 seconds, sends one wake per device every 10 minutes at
most, and none within 2 minutes after an alert push.

- **What the phone tells the server.** `widgets_placed` and `widget_channels` in the push registration, and
  `PUT /api/bloem/v2/admin/push/devices/{device id}/widgets` (`{"widgets_placed": true, "channels": [...]}`)
  whenever the answer changes. The answer is read from WidgetKit's `getCurrentConfigurations` at app start and at
  every return to the foreground (iOS gives an app no notice when a widget is added or removed, so the next
  foreground is when a change is noticed), and only when some saved server can push. The Server status widget
  follows `sessions` and `requests` (it shows the stream count and the requests waiting), Now playing follows
  `sessions`, Requests follows `requests`, Libraries follows `libraries` and Nodes follows `nodes`. When WidgetKit
  cannot answer, nothing is sent and the server's record is left alone. A server whose registration answer has no
  `widgets_placed` does not send wakes and is never told.
- **What the phone does with a wake.** `UIBackgroundModes` includes `remote-notification`, so iOS hands the silent push
  to `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. The app reloads the timelines
  (`WidgetCenter.reloadTimelines(ofKind:)`) of the widgets that show the changed channels, then answers `.newData`.
  The widgets read through their own REST client, as they always do. A push for a device this phone has no live
  registration for (signed out, being retired, not ours) is ignored. iOS may throttle background pushes, and that is
  fine: the periodic refresh stays.
- **An alert push** also reaches that method, and reloads every widget: its kind is in the server's content, not in
  the push, and the server skips a wake right after an alert because the alert is meant to have refreshed them.
- **A wake never shows anything and never starts a socket.** It has no alert and no `mutable-content`, so the
  notification service extension is never asked to show it; the code that handles it cannot post a notification or
  open a connection (a test reads its source to keep it so).
- **Plain Silo servers** cannot reach the app, so there the widgets keep only their periodic refresh. Wakes need a
  registration, and a registration needs notification permission and an APNs token, so a phone that refused
  notifications gets none.

**Not checked in a simulator.** A real push through the production relay, the extension replacing text on a locked
phone, the extension's keychain read before and after the first unlock, the Approve and Decline buttons
from a locked screen, and a real silent push waking the app to reload a widget need a signed device build; a simulator test run builds with ad hoc signing. The unit tests cover
the wire id, the content cleaning, the privacy rule, the extension's whole decision (with a fake server, a slow
server, an unknown device and a locked keychain), the registration lifecycle, the settings, the links and the
buttons.

## Control Center controls

Two controls (iOS 18 and later; on iOS 17 they are not offered):

- **Now playing** opens Bloem Admin on Now playing across all servers. It shows nothing about any server.
- **Requests waiting** shows how many requests wait across all servers, from the widgets' last read (or the
  open app's count), and a tap opens Requests. It is a count only, so it is safe on the Lock Screen.

Add them from Control Center, the Lock Screen controls, or the Action button settings.

## Live Activity

A library scan or a backup that you start from the app appears as a Live Activity on the Lock Screen and in
the Dynamic Island: what is running, the server's name, and the progress when the server reports it (a backup
reports it; a library scan run does not, so a scan shows a moving bar). Tapping opens Libraries or Backups on
that server. It follows only jobs started in the app, not scans started by autoscan or the web.

There is no push update, so it is kept current from the reads the Libraries and Backups pages already make
while the app is open. If you leave the app, iOS marks the activity out of date after ten minutes and it goes
when the job's last state has been shown. The library's name is shown only where "Show details on the lock
screen" allows it. Turn it off in iOS Settings, Bloem Admin, Live Activities.

## App Shortcuts and Siri

Three App Shortcuts need no setup and appear in Spotlight, the Shortcuts app and to Siri: **Open Now
playing**, **Open Requests** and **Open Dashboard** (for example "Open Requests in Bloem Admin"). Each
opens the page across all servers. The same actions in the Shortcuts app take an optional Server, which opens
that server's page instead. They only open the app; they change nothing.

## Home Screen quick actions

Long-press the app icon for Now playing, Requests and Dashboard (all servers).

## Everything that is new

**Permissions**

| Permission | When it is asked | Why |
|---|---|---|
| Notifications (alert, sound, badge) | When you first turn on "Alert when a server stops answering" in Settings, when you tap "Allow notifications" in Settings → Notifications, or once after the first page has loaded data from a server that can push | Server alerts and push. Never at launch. iOS asks once for all three. |

No location, contacts, photos, camera or tracking permission is added. The app's privacy manifest is
unchanged: no tracking, no collected data.

**Background work**

| What | Identifier | Declared in |
|---|---|---|
| Background app refresh task, about every 15 minutes at the earliest, run when iOS chooses | `com.bloemstudios.admin.health-check` | `project.yml`: `BGTaskSchedulerPermittedIdentifiers`; `UIBackgroundModes: fetch` |
| A silent push from a Bloem server that wakes the app to reload widgets (nothing is shown) | none | `project.yml`: `UIBackgroundModes: remote-notification` |

**Targets and signing**

| Target | Bundle id | Notes |
|---|---|---|
| BloemAdmin (app) | `com.bloemstudios.admin` | App Group and shared keychain group entitlements, a dependency on the widget extension, Live Activities. |
| BloemAdminWidgets (app extension) | `com.bloemstudios.admin.widgets` | The five widgets, the two controls and the Live Activity. App Group and shared keychain group entitlements. |
| BloemAdminNotificationService (app extension) | `com.bloemstudios.admin.NotificationService` | Replaces a pushed notification's generic text. App Group and shared keychain group entitlements; no `aps-environment` (an extension rides its app's topic). |

**Entitlements to enable on the App IDs before a device or TestFlight build is signed** (the official App IDs belong to the maintainers; a build of your own needs the same under your team and your own identifiers):

| Entitlement | Value | App ID | Why |
|---|---|---|---|
| App Groups (existing) | `group.com.bloemstudios.admin` | `com.bloemstudios.admin` and `com.bloemstudios.admin.widgets` | The snapshot, the widgets' data and settings, the refresh lock. |
| **Keychain Sharing (new)** | `<team prefix>com.bloemstudios.admin.shared` | `com.bloemstudios.admin` and `com.bloemstudios.admin.widgets` | The mirror of each server's sign-in. `keychain-access-groups` in both entitlements files; the team prefix comes from `$(AppIdentifierPrefix)`. |
| **Push Notifications (new)** | `aps-environment` = `development` in Debug, `production` in Release (`APS_ENVIRONMENT`) | `com.bloemstudios.admin` | Push from a Bloem server. Only the official build can use it. |
| **App Groups and Keychain Sharing for the extension (new)** | the same group and keychain group as above | `com.bloemstudios.admin.NotificationService` | The settings file and the registration items the extension reads. |
| **Live Activities (new)** | `NSSupportsLiveActivities` in the app's Info.plist | `com.bloemstudios.admin` | The scan and backup Live Activity. This is an Info.plist key and needs no capability in the developer account, but the widget extension must be built into the app (it is). |

The Live Activity is updated by the app, not by push. Push uses the relay's APNs key; the app holds no Apple credential.

**Info.plist keys added to the app:** `CFBundleURLTypes` (`bloemadmin`), `UIBackgroundModes` (`fetch`),
`BGTaskSchedulerPermittedIdentifiers`, `UIApplicationShortcutItems` (the three quick actions),
`NSSupportsLiveActivities`, `BloemKeychainGroupPrefix` (`$(AppIdentifierPrefix)`, read at run time to name the
shared keychain group; also in both extensions' Info.plists) and `BloemAPSEnvironment` (`$(APS_ENVIRONMENT)`,
which APNs the build's token belongs to). `UIBackgroundModes` gains `remote-notification`, for widget wakes (the notification extension does the work
for alert pushes, but a silent push has no extension).

**Data shown outside the app**

- Server names, whether a server answers, active stream count and requests waiting: on widgets, controls and
  the Live Activity, including the Lock Screen.
- On the Home Screen (the phone being unlocked): who is watching what, the newest requests with who asked and
  how long ago, library and node names. On the Lock Screen, StandBy and Always On these appear only when "Show
  details on the lock screen" is on.
- A server's name in a notification, plus (only with the details switch on) when and why it stopped answering.
- A pushed notification's title and body (a requester's name, a title, a library, node or plugin name) only
  with the details switch on; otherwise its lock-screen text alone.
- Never: an email address, an IP address, a server address or a token.

**Data stored outside the app's own sandbox.** In the App Group container: `admin-snapshot.json` (the server
list and counts, no token), `widget-data.json` (the widgets' last data, which can hold names and titles),
`widget-settings.json` (the two settings the widgets honour), `push-settings.json` (the details setting, for the
notification extension) and `credential-refresh.lock` (empty). In the shared keychain group: the sign-in mirror
described above, and one push registration per server (service `com.bloemstudios.admin.push-registrations.v1`:
the device id, the display token, the server's address and name, readable after the first unlock).
Inside the app: the alert switches and per-server alert state in UserDefaults
(`bloem.admin.alerts.*`), and the push choices (`bloem.admin.push.*`: the kinds switched off per server, each
server's last status, whether permission was asked, the installation id and the last APNs token), readable
after the first unlock.

## Turning it all off

| To stop | Do this |
|---|---|
| Alerts and the background check | Settings, Server alerts: turn off "Alert when a server stops answering". The background task is cancelled and delivered notices are removed. Or turn off Background App Refresh for Bloem Admin in iOS Settings, or Notifications. |
| One server's alerts | Settings, Server alerts, Servers to watch: turn that server off. |
| Widget wakes | They stop when no widget is placed (remove the widgets), when push is switched off for the app in iOS Settings, or when the server is signed out of or removed. |
| One kind of push for one server | Settings, Notifications: turn that kind off for that server. The server stops sending it. |
| All push | iOS Settings, Bloem Admin, Notifications. Or sign out of the server, or remove it: the device is retired on the server. |
| Details on the lock screen | Settings, Server alerts: turn off "Show details on the lock screen". |
| Widgets | Remove the widget from the Home Screen or Lock Screen. The app keeps writing the snapshot file until the app is deleted or the server list is empty; with no widget, nothing reads it. |
| Widgets reading a server | Sign out of that server in the app, or remove it: the mirror is deleted and the widgets stop reading it. |
| Names on the lock screen | Settings, Server alerts: turn off "Show details on the lock screen" (the default). |
| The controls | Remove them from Control Center, the Lock Screen or the Action button. |
| The Live Activity | iOS Settings, Bloem Admin, Live Activities. |
| App Shortcuts and Siri | Settings, Siri, Bloem Admin (Shortcuts and Spotlight suggestions). |
| Quick actions | Not switchable; they only open a page. |
| Links | Not switchable; a link only opens a page, behind the app lock. |
| Everything | Delete the app. The snapshot file, the alert settings and the saved servers go with it. |

## Testing and what could not be checked in a simulator

- Unit tests cover the decision logic (two failures, flap suppression, recovery), check scheduling,
  permission gating, link parsing, the snapshot and what a widget shows. The widget tests cover every state of
  every data widget, the privacy rule (no names on the lock screen with details off), the deep links, the
  Approve and Decline intents, the token refresh and its lock, the keychain mirror, and the Live Activity's
  rules. A render test draws every widget at every size, dark and light
  (`docs/screenshots/bloem-widgets/`). UI tests cover Settings with a
  fake permission (no system prompt appears) and links.
- The build script's ad hoc signing (`CODE_SIGN_IDENTITY=-`, no team) builds, signs and embeds the widget
  extension, and the App Group container resolves in the simulator, so the snapshot file is shared there. A
  device or TestFlight build still needs the App Group enabled on both App IDs in the Apple Developer account.
- Real background refresh, a real notification on a lock screen, widget refresh budgets, the Control Center
  controls, the Live Activity and Dynamic Island, Siri phrases and Home Screen quick actions need a device.
  They were not driven in the simulator.
- The shared keychain group needs the Keychain Sharing capability on a signed build. An unsigned simulator
  build has no team prefix and may refuse the mirror; the tests use a fake keychain. Whether a widget really
  reads the app's sign-in, and a rotated refresh token is taken back by the app, needs a signed device build.
