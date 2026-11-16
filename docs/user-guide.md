---
title: Bloem Admin for iOS and iPadOS — User Guide
description: Every screen, tab, sheet and control in the Bloem Admin app for iPhone and iPad, in the order a new administrator meets them, with what each one does and what it asks the server to do.
summary: Unlocking the app, the top bar, menu, page search and sideways swipe, adding and managing servers, the All servers view, and each page — Now playing, Dashboard (number tiles, server health, now playing, trend charts, top lists), Playback history, Logs, Libraries (scans, mount checks, metadata refresh), Requests, Scheduled tasks, Users (with Invitations and sessions & devices), Settings, Audit — plus iPhone vs iPad layout, refreshing, confirmations, haptics and what the error states mean.
tags:
  - end-user
  - admin
  - ios
  - ipados
  - getting-started
audience:
  - end-user
last_reviewed: 2026-11-13
related:
  - admin-guide.md
---

# Bloem Admin for iOS and iPadOS — User Guide

> [!CAUTION]
> **Offered without support.** Bloem Admin is provided as-is, with no support of any kind. Issues are turned off, questions go unanswered, and pull requests are not accepted: they are closed without review. You are free to fork it under the AGPL v3.

You run a [Silo](https://siloserver.org) server (or someone you work with does) and you want to look after it from your
iPhone or iPad: see who is streaming, approve a request, end a session, invite a user, change a
setting, restart the server. That is what Bloem Admin is for. This guide walks through every screen
in the order you will meet them. Words in **bold** are the exact labels you see in the app.

Nothing here requires you to understand how the app is built. If you are the person installing or
building it, see the [Admin Guide](admin-guide.md).

---

## 1. First launch

### 1.1 The lock screen

Bloem Admin holds administrator access to your media servers, so it locks itself. Every time you
open it — and every time you come back to it after switching away, opening Control Centre or the
app switcher — you see the app's mark and:

> **Bloem Admin is locked**
> *Unlock with Face ID, Touch ID or your passcode.*
> **[Unlock]**

The Face ID / Touch ID prompt appears on its own (the system sheet says *Unlock Bloem Admin*). If it fails or you dismiss it, tap **Unlock** to try again; the prompt
offers your device passcode as a fallback.

If your device has no passcode and no Face ID or Touch ID enrolled, the app **stays locked**. The
lock screen then reads *Turn on a passcode, Face ID or Touch ID in Settings to use Bloem Admin.*
and the button says **Try again**. Set a passcode in
Settings, come back, and tap **Try again**.

While the app is locked — including the moment you open the app switcher — the lock screen covers
everything, so no server data shows in the switcher preview. Anything you were in the middle of (a
half-filled form, an open sheet) is still there after you unlock. On an iPad with two Bloem Admin
windows open, each window locks and unlocks on its own.

### 1.2 The top bar, menu, search and swipe

The app has no tab bar. Every screen has one top bar, like the web admin's on a phone. On the pages of
All servers or of a server, from left to right it has a **menu** button (*Open menu*), the title of the
current page, a **search** button (*Search admin sections*) and the **server dropdown**.

- **Menu** opens the menu from the left edge, over the page. Choosing a page opens it and closes the
  menu; a tap outside the menu, or a swipe to the left on it, closes it without choosing. The menu opens
  only from this button: a sideways swipe on a page changes the page instead (below).
- **Search** opens a full-screen page search, as the web admin's search does. Type a few letters: it
  lists the pages of what you are looking at (All servers, a server or an organization) whose name, description or search
  words contain them, under the menu's group names. A group's own name (*Monitor*, *Manage*) lists all
  its pages. Tap a page to open it; the search closes. The keyboard's search key opens the first match.
  The arrow at the top left closes the search without choosing. With no match it says *No matching pages*.
- **Server dropdown** is named after what you are looking at (*All servers*, or a server's name). Open it
  to switch between **All servers** and any saved server. A server or All servers always opens on
  **Now playing**. Choosing the one you are already in changes nothing. (Organizations are listed under
  their server once the app supports them.)
- On an iPad in regular width the menu is a permanent **sidebar** on the
  left, titled with what you are looking at, so there is no menu button. In a narrow window, such as
  Slide Over, it is the menu button again. Search and the dropdown stay in the top bar.
- The screens that come before a server's pages have the same bar with their own title and the
  dropdown, but no menu or search, as there is nothing to navigate yet: **Checking access**, **Sign in**
  (signing in again), **No access** and **Can't reach server**.
- Opening something inside a page (a user, a stream, a request) shows the system back button in the same
  bar; go back to return to the page.

**Swipe.** A sideways swipe on a page moves to the next page (swipe left) or the previous one (swipe
right), in the menu's order. It stops at the first and last page: there is no wrap-around. Anything on a
page that scrolls sideways takes the swipe first. Nothing changes while a dialog, confirmation or sheet
is open, or while the menu or search is open.

Each page has its own icon in the menu and in search, close to the web admin's: for example
**Now playing** (live waves), **Dashboard** (a grid), **Playback history** (history), **Logs** (a page of text),
**Libraries** (books on a shelf), **Requests** (a paper plane), **Scheduled tasks** (a calendar with a clock), **Nodes** (a server rack),
**Backups** (a drive with a clock), **Plugins** (a puzzle piece), **Users** (two people),
**Organizations** (a building), **Settings** (sliders) and **Audit** (a shield with a check).

The menu groups pages as the web admin does. Only the pages this app has are listed:

| Group | Pages |
|---|---|
| **Platform** | Only for a Bloem server; a plain Silo server has no Platform group. **Organizations** (for every platform administrator: a Bloem server's own page, and in All servers a section per Bloem server, listed only when at least one saved server is a Bloem server; section 4.10), **Support access** (one server only, for the server Owner on a server with organization support; section 4.11) |
| **Monitor** | **Dashboard**, **Now playing**, **Logs** (one server only), **Audit** |
| **Manage** | **Libraries**, **Requests** (with the count of what needs approval beside it, section 4.5), **Users**, **Playback history**, **Nodes** |
| **Configure** | **Server settings**, **Scheduled tasks**, **Backups**, **API keys** (one server only; section 4.16), **Plugins** |

Below the pages, three app-level rows stay at the bottom of the menu, in this order: **Manage servers**
(section 2.1), **Settings** (a page, not a dialog: **Appearance**, **App lock**, which is always on, the
**Server alerts** and **Notifications** sections, and **About** with the app version) and **Sign out**
(ends this device's sign-in to the open server, or to every saved server on All servers, after asking; the
servers stay in the list). The server switcher in the top bar (**Name ⌄**) is a sheet listing All servers and
each server, the current one marked, with **Add server** as its last row.

Pages carry the web admin's names. Where later sections of this guide still say *Streams*, *Activity*,
*Jobs*, *Server* or *Tenants*, read **Now playing**, **Playback history**, **Scheduled tasks**,
**Server settings** and **Organizations**; a section that says *tab* means a page in the menu. A server opens on
Now playing, which is not the first page in the menu.

**Look.** The app uses the web admin's graphite and one orange: Bloem orange marks the page you are on and
the main button, and a small orange dot means something is live right now (a stream that is playing, the
count of active streams). Status is quiet text: a state that is normal (*Playing*, *Active*) is plain or left
out, and only one that needs a look (*Paused*, *Disabled*, *Suspended*, a failure) carries a dot, in amber, or
in red for a failure only. A transcode is amber, never red. The type is Plus Jakarta Sans and the icons are Lucide, and the text scales with
the system's text size. In **Settings**, **Appearance** is **System**, **Light** or **Dark**; System
follows the device. Increased contrast is honoured in both.

---

### 1.3 Server alerts, links, widgets and shortcuts

**Server alerts.** In **Settings → Server alerts**, turn on **Alert when a server stops answering**. This
is when iOS asks whether Bloem Admin may notify you; nothing is asked before. Then turn on each server you
want to hear about under **Servers to watch**. Everything is off until you turn it on.

The app asks each server's public health route whether it is up, when you open the app and, in the
background, whenever iOS allows it (iOS decides how often, so a check can be hours apart, and none runs
after you force-quit the app). A server that fails two checks in a row gets one notice, "Can't reach
*name*", and another, "*name* is answering again", when it is back. A lock screen shows only the server's
name. **Show details on the lock screen** adds when it stopped answering and why, on this device only. Tapping
a notice opens that server after the app lock. If you refuse the permission, Settings says
notifications are off and offers **Open iOS Settings**. Removing a server stops its checks.

**Widgets.** The widget gallery has five widgets, each named "Bloem Admin: ...": **Server status**, **Now
playing**, **Requests** (with Approve and Decline buttons), **Libraries and scans** and **Nodes and resources**.
Add one from the Home Screen or Lock Screen gallery, then press and hold it to choose one server or all of them.
They read the servers themselves and say "Updated 14:32" when their data is old. Tapping a widget opens the page it
shows. A library scan or a backup that you start in the app also appears as a Live Activity. The lock screen shows
counts only, unless you turn on **Show details on the lock screen**.

**Push notifications.** A Bloem server can push to your phone when something is broken or waiting on you: a request
to approve, a failed scan or backup, an offline node or a failed plugin. Push works **only with a Bloem server and the
official build of the app**. On a Silo server there is no push and no widget wake: you get the server alerts above and
the widgets' periodic refresh. Settings says "Push isn't available on this server" and shows no error. Where push is
on, **App settings → Notifications** has a switch for each kind, per server.

**Control Center (iOS 18).** Add **Now playing** from Control Center, the Lock Screen or the Action button
settings to open the app on Now playing.

**Shortcuts and Siri.** **Open Now playing**, **Open Requests** and **Open Dashboard** are available in
Spotlight, the Shortcuts app and to Siri. Pressing and holding the app icon offers the same three.

Everything that appears outside the app, and how to switch each part off, is listed in
[Alerts, links, widgets and shortcuts](platform-features.md).

## 2. Servers

### 2.1 Manage servers

The app opens on **Now playing** in the scope you last used (**All servers** the first time). With no
saved server, every All servers page says *No Servers* with an **Add Server** button.

**Manage servers** is the first of the three rows at the bottom of the menu. It reads like one of the web admin's settings
pages: the top bar has a back arrow and the title, and the page is a list of grouped rows. A full-width
**Add Server** button stays at the bottom. **Add Server** appears only here and on the empty All servers
pages, never in the top bar or the menu. The page has:

- **All Servers** — view and manage every added server at once (section 3).
- **Saved servers** — one row for each server with its display name, HTTPS address and, below them,
  **Signed out** (orange) when this device has no sign-in for it. Tap a
  row to open that server; a signed-out server asks you to sign in. *No individual servers saved yet.*
  shows when there are none. A server saved with a non-HTTPS address is marked in red and cannot be
  opened; remove it and add its HTTPS address.
- The **•••** menu on each server row: **Rename**, **Forget credentials** (dimmed on a signed-out
  server) and **Remove server** (section 2.4).

If the app could not read or write its saved server list, an alert titled **Saved Data Could Not
Be Updated** shows the reason; the list may be empty until you add servers again.

### 2.2 Adding a server

**Add Server** opens a sheet. Adding a server takes two steps.

**Step one: the address.** Type the server's address in the **Server** field (placeholder
**your-server.example.com**): the address you use in a browser, with the port if it needs one, and
nothing after the host — no `/path`, `?query` or `#`. You can leave out `https://`; the app adds it. An
address that starts with `http://` is refused.

You do not have to tap anything once the address is typed: when you stop typing for a moment and the
address looks finished (it ends in a name such as `.com` or `.org`), the app checks it by itself and moves
on to step two. Typing again cancels a check that is still running. **Continue** (or **Go** on the
keyboard) checks at once; use it for an address the app does not check by itself, such as an IP address
or `localhost`. The app checks that the server is healthy and reads how it lets people sign in. If the
check fails, the reason shows under the field.

**Step two: how to sign in.** The sheet shows the server's name and what it offers: a **Sign in with
<provider>** button for each sign-in provider the server offers to apps (Authentik first, as the one orange button), and **Username** and
**Password** fields if it allows passwords. A provider opens its sign-in page in a system browser sheet;
**Connect** signs in with the password, which is used once and not kept. **Change server** goes back to
step one. Either way, the app confirms the account is an administrator before the server is saved. On
success the sheet closes and the server appears in the list, named as the server names itself (or by its
host name if it does not). **Cancel** closes the sheet.

What can go wrong, shown in red under the fields:

- *Enter the server's HTTPS address.* / *That doesn't look like a valid URL.* — fix the address.
- *The server address must use HTTPS.* — you typed `http://`; only `https://` works.
- *The server address must include a host.* / *The server address must use a port between 1 and
  65535.* / *The server address cannot include a username or password.* / *Enter only the server
  origin, without a path, query, or fragment.* — trim the address down to `https://host` (plus
  `:port` if needed).
- *This server is not compatible with Bloem Admin.* — the address answered, but not as a current Silo server (its health
  answer has no server identity).
- *That address isn't a Silo server. Check it and try again.* — the address answered with something that is
  not a Silo server's API, usually a web page.
- *Could not reach that server. Check the address, and that it uses https.* — wrong address, server down, no route, an untrusted certificate,
  or a proxy that redirects (the app never follows redirects). If the server is on your local
  network, iOS may also have asked for **Local Network** permission; allow it.
- *This account needs administrator access.* — the account can sign in but is not an administrator (the server is not
  saved in that case).
- *This server needs a newer version of Bloem Admin.* — update the app.
- After a provider sign-in: *This account isn't allowed to sign in to this server.*, *No account on this server uses that
  sign-in. Ask the server's owner for an invitation.*, *An account with that email already exists. Sign in with its
  password instead.*, *That sign-in is linked to a different account.*, *This account is disabled.*, or *The sign-in took
  too long or was interrupted. Try again.*
- Any other text is the server's own message, such as a wrong username or password.

### 2.3 Opening a server: the admin gate

Pick a server in the dropdown, or tap its row in Manage servers. The screen is titled **Checking access**
and shows *Checking access…*, then one of:

- The server's pages (section 4) — you are in, on **Now playing**.
- **Organization mode** (section 4.11) — the account is not the server's administrator but administers
  at least one organization on it. An account that administers a single organization lands in it
  straight away; one that administers several is asked to **Choose an organization**. The top bar and
  the context dropdown stay, so you can still switch servers.
- **Sign in** — *Your session on <server> has expired. Sign in again to continue.* with an
  **Admin login** group (**Username**, **Password**) and **Sign In**. Sign in and the pages appear.
  The app normally renews your sign-in silently, so you mostly see this after **Forget credentials** or after
  your sessions were revoked on the server.
- **No access** (*No Admin Access*) — *This account doesn't have admin access on <server>.* The login
  worked but the account administers nothing on this server: it is neither the server's administrator nor an
  administrator of any organization. If an administrator has just restored the role, tap **Retry** to
  check again. Otherwise open Manage servers, remove the server, add it with an admin account.
- **Can't reach server** with **Incompatible Server Response** — *The server returned an incompatible
  response.* The address answered, but not with a Silo server's API. Tap **Retry** after fixing the address
  or proxy.
- **Can't reach server** with **Connection Lost** and a message — the server could not be reached or
  returned an error. Tap **Retry**.

All four screens have the top bar with their title and the dropdown, so you can move to another server
without going back.

### 2.4 Rename, Forget credentials, Remove Server

All three are in the **•••** menu of a server's row in Manage servers.

- **Rename** opens **Rename Server** with a **Name** field (*Server name*), **Cancel** and **Save**.
  Only the name shown in the app changes; nothing is sent to the server.
- **Forget credentials** asks *Forget credentials for <server>?* — *This removes the locally stored
  access and refresh tokens from this device. It does not revoke server-side sessions.* It forgets your
  sign-in for that server but keeps it in the list (the row then says **Signed out**); next time you open
  it you get **Sign in**. Use it on a shared device or to switch admin accounts.
- **Remove server** asks *Remove <server>?* — *This removes the server and its stored sign-in from this
  device. You can add it again later.* with **Remove server** (red) and **Cancel**. If you were looking
  at that server, the app returns to All servers.

---

## 3. All servers

Choose **All servers** in the dropdown (or **All servers** in Manage servers) to see every server at once.
Thirteen pages are available — **Organizations**, **Now playing**, **Dashboard**, **Audit**, **Playback history**, **Libraries**, **Requests**, **Scheduled
tasks**, **Nodes**, **Users**, **Settings**, **Backups** and **Plugins** — each showing the same information as the single-server
page of that name (section 4), divided into one section per server headed with the server's name.
Servers are contacted in parallel with a
ten-second limit each, so a slow or offline server only affects its own section.

What a section can show:

| Section shows | Meaning | What to do |
|---|---|---|
| The server's rows | Loaded | Use the actions as on the single-server tab |
| *No active streams* / *No playback history* / *No scheduled tasks* / *No nodes* / *No plugins installed* / *No libraries configured* / *No requests* / *No audit entries* | Loaded, nothing to show | — |
| On **Dashboard**, a banner with the server's error and its last numbers underneath | A refresh failed; the section keeps what it last loaded | Pull down or tap **Retry** |
| *Sign in again to <server> to include it in All Servers.* with **Admin login** fields and **Sign In** | Your sign-in on that server expired | Sign in right there; the section reloads |
| An error message with **Retry** | That server did not answer in time or returned an error | Tap **Retry** or pull down; other servers are unaffected |

What is different from single-server mode:

- **Dashboard:** each server gets its own copy of the single-server dashboard (section 4.1) under its
  name, with its own chart windows. A server that needs signing in shows **Sign In** instead of its
  sections; one that failed shows its reason with **Retry**. **Manage streams** and **Manage users** open
  the Now playing and Users pages of All servers.
- **Not available here:** Logs, Organizations, Invitations and
  the **Message Client** action. Open the server on its own for those.
- **Users** still lets you search, open a user (the page names its server and writes only to it), and use **Add User to <server>** per section.
- **Playback history** and **Audit** have their own **Person** filter (Playback history also **Profile** and **All plays**, **Completed** or **Partial**) and **Load more** per section, and a tap on a row opens its details.

---

## 4. Inside a server

Past the gate you get the server's pages in the menu (section 1.2): **Organizations** (on a Bloem server),
**Now playing**, **Dashboard**, **Logs**, **Audit**, **Playback history**, **Libraries**, **Requests**, **Scheduled tasks**,
**Nodes**, **Users**, **Settings**, **Backups**, **API keys** and **Plugins**.

Behaviour shared by every tab:

- **Automatic refresh.** Nothing refreshes on a timer. The app holds one live connection per server, only while it is in
  front, and the server tells it what changed: Scheduled tasks and Backups follow the server's tasks, Libraries its scans
  and jobs, and Streams, a user's Watching now and the Dashboard's Now playing its sessions (see 4.2). Every other screen
  (the rest of the Dashboard, Nodes, Plugins, Activity, Requests, Users, Server) loads when you open it, when the app comes
  back to the front and when you pull down. If a server has no live updates, or the connection keeps failing, the screen on
  view is read at most once a minute, and only until the connection is back. The connection closes 10 seconds after the app
  leaves the front, and nothing refreshes in the background. Audit, Logs and Invitations load when opened, when you change
  a filter and when you pull down.
- **Pull to refresh** on any list.
- **First load.** A spinner shows until the first data arrives, then never again for routine
  refreshes.
- **When a list cannot load.** The tab shows a panel whose title says what happened and whose icon
  matches: *Can't reach the server*, *Signed out*, *No access*, *Server error* with the status (for
  example *Server error 500*), or *Unexpected response*. The server's own message is under the title,
  and **Try again** reads the list again. A failed *action* is different: it is shown in red under the action buttons, and
  the list stays as it was.
- **Confirmations and haptics.** Destructive actions ask first. Deleting a user, terminating a
  session, restarting the server and revoking a session give a short success haptic once
  the server has confirmed.
- **One action at a time.** On a detail page, every action button is greyed out while an action is
  still being sent, so a double tap cannot send it twice.

### 4.1 Dashboard

The dashboard follows the server's web admin dashboard, in the same order. Under **All servers** every
server starts as one row — its name, **Streams**, **Egress** and **Errors · 24h** — and tapping the row opens that
server's whole dashboard under it, laid out the same way; tap again to close it. A server that needs signing in or has
failed shows its message and its button under the row.

1. **Number tiles**: two live figures, **Active streams** (with the orange dot while something is
   streaming) and **Egress now**, two to a row (one to a row at the largest text sizes). The inventory is one
   card under them with four small figures in a row: **Profiles · 24h**, **Movies**, **Shows** and **Storage**. A figure only
   appears once its number is known, so one you do not see has no data yet. **Egress now** is left out when the newest
   egress sample is more than two minutes old, rather than showing an old rate as the current one.
2. **Server health**, a compact strip: **Version**, **Uptime**, **Postgres**, **Redis**, **Nodes**
   (healthy of enabled) and **Errors · 24h** with the warning count. **Redis** reads *Not configured*
   on a single-node server, which is normal. Under the strip, **CPU**, **Memory** and **Network** are three small labelled figures with how old
   the sample is; a stale sample says *Last sample …* in amber. The cells have one flat style in light and dark. When the
   server cannot measure its host the line is simply absent, which is normal.
3. **Now playing**, with **Manage streams**, which opens Now playing. It shows up to four current
   streams, each drawn as in Now playing (section 4.2), and **+N more active streams** for the rest. With nothing playing it says *Nothing playing right now*. A failed
   refresh keeps the last sessions and says they are the last reported data.
4. **Concurrent streams**, **Playback activity**, **Egress**, **Top titles** and **Most active profiles**.
   The first three are charts (see below). **Concurrent streams** is the one main chart and comes first,
   ahead of the web's order. The two top lists cover the last 7 days.
5. **Libraries**, **Users** (most recently active first, up to five; **Manage users** opens the Users
   page) and **Recent activity**.

A section with nothing to say yet is not shown; once a section has failed it stays, with its error, so
the failure is visible. The old list of totals (**Total items**, **Total files**, **Total users**) and
the **Watch providers** block are gone.

**Trend charts.** Playback activity, Egress and Concurrent streams are drawn in the app, in the same
windows as the web: **1h**, **24h** (the start), **7d** and **30d**. One segmented control, under the title
of Concurrent streams, sets the window of all three charts, and under **All servers** each server has its own
choice. The segments say what they show to VoiceOver (*Show the last 7 days*) and the chosen one is marked.

- **Concurrent streams** is the large chart: whole streams over the window, stacked by how each was
  delivered — **Direct play** (blue), **Direct stream** (green) and **Transcode** (amber) — using the counts the
  server reports with each sample. A server that does not report them gets one band for the total.
- **Playback activity** stacks the sessions started in each hour (each day, for a week or a month) by
  play method: **Direct play**, **Direct stream** and **Transcode**. Quiet hours stay in place as empty
  columns. The legend under the chart gives each method's count, and the share of finished sessions that
  completed is shown above it.
- **Egress** is a line in Mbps with the window's **Total** above it. When the window includes download
  traffic, a dashed **Downloads** line is drawn and named in the legend. Wider windows show each
  period's peak minute, so a short spike is not averaged away.
- A line breaks where the server recorded no sample (for example while it was down) instead of dropping to
  zero, because *no sample* and *nobody watching* are different things. Above each line chart a summary
  gives the **Latest**, **Peak** and **Lowest** value of the window; the axis starts at zero and the time
  axis shows hour marks for a day and day marks for a week or a month.
- **Show values** under a chart swaps it for the same information as plain numbers: latest, peak (and when),
  lowest, average, the egress total and a handful of readings spread across the window; for playback, the
  count per method, the total and the busiest hour or day. **Show chart** switches back.
- A chart is one image to VoiceOver, described by its window, latest, peak and lowest (for example *Egress
  over the last 24 hours, in megabits per second. Latest 12 Mbps, peak 40 Mbps, lowest 2.0 Mbps.*). The
  plain-number view is the alternative to it. With **Reduce Motion** on, charts appear at once instead of
  animating when you change the window.
- A window you have not opened yet is read when you tap it, and shows *Loading…* until it arrives; it never
  shows another window's chart in its place. A 1h chart reuses the *Egress now* read.

Each section loads on its own. If one fails, the others stay and that section shows what went wrong,
keeping its last good numbers or chart. The sections load when the Dashboard opens, when the app returns to the front and
on pull to refresh; only Now playing follows the server live. The slower sections (the version, the 24h egress and
concurrent-streams charts, the 7-day top lists, libraries, users, and the 7d and 30d windows) are read at most every five
minutes, and a slow section that failed is tried again on the next load. Nothing refreshes while the app is in the
background. Pull to refresh asks the server to recompute its statistics and re-reads everything.

Not in the app yet: egress split by node, tapping a chart to read a single sample, the web's other
widgets (Server resources, Playback reliability, Watch providers, Nodes, Scanner, Offline downloads,
Scan activity, Recent errors), library scan buttons (scan from **Libraries**), and rearranging or hiding widgets.

### 4.2 Now playing

At the top, a small line says where the list comes from: **Live** while the app follows the server's
live updates, **Connecting** at first, **Reconnecting** with a reason (*Connection lost, reconnecting
and checking sessions*) after a drop, or **Unavailable** with *Live updates unavailable, sessions
refresh every minute* when the server has no live updates. Whenever the live updates are not
running, the list is read again at most once a minute, and a line says that the cards may be old. Streams
start, change and stop on screen as they happen, and the list is read again after each Pause, Resume,
Stop or Terminate you send. Live updates stop when the app is not in front and start again when it
returns. The Dashboard's **Now playing** section shows the same line.

One card per active playback session, drawn as the stream's signal path. The card shows, top to bottom:

- **Title** — for an episode *<series> · S2E3 · <episode name>*, otherwise the title.
- **Who and what** — *<username> · <profile>* (the profile is left out when it repeats the user), then
  the client app and its device (*Silo Android 1.4.2 · Android*).
- **State** — a status line under the viewer: **● Playing** with the small orange dot, or **Paused** with an
  amber dot.
- **Signal path** — three steps read left to right: **Source** (the file's format and container),
  **Playback** (the decision, in the web admin's words: **Direct play**, **Remux**, **Direct stream** (video
  copied or untouched, audio converted) or **Transcode**) and **Client** (the app and its device). Only a
  transcode is lit, in amber, with the format it converts to and what does the work; the others are quiet text.
- **Progress** — a thin bar (grey while playing, amber while paused), *position / length* (*12:34 / 44:12*) and
  the bitrate (*8.2 Mbps*), in tabular figures. The time left is not drawn; VoiceOver still reads it. While a
  stream plays the numbers move forward once a second between updates, and only while the app is in
  front; a paused stream stays put, and every update from the server starts the count again from the
  reported position. With **Reduce Motion** on (Settings → Accessibility → Motion) nothing moves
  between updates. When the server does not report the file's length you see the position only.
- **Video** and **Audio** details — each decision (**Direct**, **Copy**, **Transcode**) with the formats:
  *Video: Transcode · HEVC 4K → H.264 1080p*, *Audio: Transcode · TrueHD 7.1 → AAC 5.1 · English*. A
  direct stream shows just the source format. 2160p is written **4K**. The target channel layout
  appears only when the server reports it.
- **Transcode details** — hardware acceleration (*HW NVENC*, *HW VAAPI*, *HW QSV*, *SW*, *HW/SW
  pending* or *HW/SW unknown*; *Audio Transcode* when only the audio is converted), **HW Tone map** /
  **SW Tone map** when the server confirmed it, and the stream bitrate (*8.2 Mbps*).

Anything the server or player did not report is simply left out.

**Tap a card** to open its details; tap it again to close them. They list what support needs: the
method, video and audio (source and output), the audio track and language, the transcoder, the source
container and how it is delivered (*MKV → HLS · MPEG-TS*), source and stream bitrate, the exact client
version, the playing node (*Transcode: <node>*, *Proxy*, *Server*), local or remote network, **Started**
and **Last update**. **Client IP** appears only on the platform administrator's pages; it is never
shown in an organization context. VoiceOver reads each card as one sentence with the key facts, says
whether its details are shown, and reads the details line by line. Card text follows Dynamic Type: at
the largest sizes the details put each label above its value.

In **All Servers**, each server's section lists the same cards, with the same controls.

Tap **⋯** (*Actions for <username>*) in the card's corner:

| Action | What it does |
|---|---|
| **Pause** / **Resume** | Whichever applies to the session's current state. |
| **Stop playback** | Asks *Stop <title> for <user>?* and says the player is told to stop and can start again — **Stop playback** / **Cancel**. |
| **Send message** | Opens **Message <username>** with **Title (optional)** and **Message**; **Send** is enabled once the message is non-empty. On success the card shows *Message sent*. If the client is not connected right now, the sheet says so in red. |
| **Logs** / **FFmpeg logs** | Single server only. Opens **Logs** for this stream's playback session (FFmpeg logs also filter to the *ffmpeg* component), with the session summary on top (section 4.9). |
| **End stream** (red) | Asks *End <user>'s stream of <title>?* and says the server closes the session now, even if the player does not stop, and it cannot be resumed — **End stream** / **Cancel**. Success gives a haptic. |

While a command runs the card says *Action in progress* and the **⋯** button is dimmed. A command
that fails names the action and the title (*Couldn't pause Dune. Try again.*) in red above the cards until you tap **Dismiss** or run another.

### 4.3 Playback history

Playback history, newest first, for tracing who watched what and when. At the top are three filters
that apply as soon as you change them: **Person** (choose a name from the server's user list; **Everyone**
clears it), **Profile** (appears once a person is chosen, and lists only that person's profiles) and
**All plays**, **Completed** or **Partial**.

Each row shows the title (an episode leads with its series, with *S02E04 · Episode title* under it), then
*<username> · <profile>*, the date and time the play ended in your own time zone, and a line such as
*40m 10s of 1h 30m · Direct play · Partial*: how long it was watched out of the length, how it was
delivered and whether it was completed. When a play was recorded before watch time was measured, the
watch time starts with *About*.

Tap a row for **Play details**: user and profile, when it started and ended, time watched and paused, the
result, how it ended (*Stopped by the viewer*, *Ended by an administrator*, *Client stopped responding*,
*Stopped by the server* or *Replaced by a new session*, when the server knows), the play method, the client
app and platform, the client address (only where the app shows addresses), and the playback session ID.
**Logs** and **FFmpeg logs** open Logs for that playback session (single server only; All servers has no
Logs). **Copy** and **Share** send the details as text.

**Load more** at the bottom fetches the next 50; a spinner replaces it while loading, and a failure
shows under the list. Once you have paged past the first 50, the automatic refresh stops
replacing the list so your pages stay put; pull down to reload from the top.

### 4.4 Scheduled tasks

The server's background tasks. Each row shows the task's name and state (*Idle*, *Running, 42%*,
*Stopping*), a progress bar while it runs, the last result with its duration (*Completed 2 h ago, took
2 min 5 s*, *Failed 7 h ago, took 800 ms*), and *Next run in 12 h* or *Overdue*. A failed last run and an
overdue task are said in words and set in bold, never by colour alone. The list follows the server's task
updates, so the bar moves while a task runs without the page asking again and again.

The **Job history** row at the top opens every background job the server kept (library refreshes and
deletions, restores, exports): the job, its library or source, its state, when it finished, its progress
(*40 of 100 items*) and, for a failed job, *what failed: why*. **Load more** at the end reads the next
page. In All servers each server's section has its own **Job history** row.

Tap a task for its page:

**Description** and **Category**.

**Status** — **State**, a progress bar, **Progress** (the server's progress message while running),
**Last run** and **Next run**.

**Actions** — **Run now**, available only while the task is idle (otherwise it is greyed out and a note
says so), and, only while it runs, **Cancel run** (red), which asks *Cancel <task>? The run may have
already changed server data.* — **Cancel run** / **Keep running**.

**Schedule** — **Runs** says the schedule in words: *Every 3 hours*, *Every day at 02:00*, *Every Sunday
at 03:30*, *When the server starts*, with *, stops after 2 hours* when a longest run is set. **Edit
schedule** opens the editor; a task that only runs when you start it says so instead, and the backup
task says *The backup time is set on the Backups page* because the server overwrites any trigger edited
here.

**Recent runs** — each run's status, duration, start, error and failed steps (*Failed steps: Probe
files*). **Load more** reads older runs.

#### The schedule editor

**Run on server startup** (toggle), **Run on an interval** (toggle), **Run every (minutes)** (a number
field whose placeholder reads *Not set*; editable only while **Run on an interval** is on), and
**Daily and weekly times**: one block for each daily or weekly trigger with **Repeats** (*Every day* or
*Every week*), the **Day** for a weekly one, the **Time**, and **Longest run (minutes)** (empty means no
limit). **Add daily time** and **Add weekly time** add a block; **Remove time** drops one. Times follow
the server's clock, not the device's. Triggers you do not touch are sent back exactly as they were.

**Save** stays greyed out until everything is valid; the reason shows under the field: *Enter an interval
in minutes.*, *Enter a whole number of minutes.*, *The interval must be greater than zero.*, *Enter an
interval of one year or less.*, *Choose a time of day.* or *Enter the longest run in minutes, or leave it
empty for no limit.* If the task's existing interval trigger is one the app cannot safely edit (no
duration, an unusual duration, or several interval triggers), the interval field is locked with a message
telling you to turn **Run on an interval** off to remove it. If the schedule could not be loaded you see
the error and a **Try again** button. If another administrator changed the schedule while you edited, the
sheet says so, keeps what you typed and offers **Review current schedule**, then **Keep my edit and
continue**.

### 4.5 Requests

The queue opens on **Needs approval** when anything waits there, otherwise on **In progress**. A row of
buttons picks the view — **Needs approval**, **In progress**, **Failed** and **Done** — each with its
count. Search by title or TMDB ID, filter by **Movies** or **Series**, or touch and hold a request and
choose **Show only this account's requests**. Each request shows its poster, title, year · type ·
seasons, who asked and when, its state, and where it went: the download server, the quality, its
status, the rule that sent it there, download progress and the server's error. Tap a request for its
details and history.

**Actions** are offered only where the view allows them:

- **Needs approval** — **Approve**, **Decline**.
- **In progress** — **Cancel request**, while nothing has been sent for it yet.
- **Failed** — **Retry**, **Cancel request** (which closes it).
- **Done** — none.

Decline and cancel ask for an optional note first. If the server refuses an action, the reason appears
above the queue.

The queue loads when it opens, when the app returns to the front and when you pull down; the server has no live
signal for new requests. If a refresh fails while requests are on screen, they stay and a line says *Couldn't
refresh · last updated 14:32* with **Try again**. If only the counts cannot be read, the requests still
load.

#### Answering several at once

On **Needs approval**, **Select** starts select mode. Tap requests to select them, or tap **Select all N
shown** (it becomes **Clear**). Pinned under the queue are **Approve N** and **Decline N**. **Decline N**
asks for one optional note that goes to every requester; an approval takes no note. The app sends one
call per request, four at a time, and shows progress (*Approving 3 of 12*). A request the server
refuses — someone else answered it first, say — is named with the server's reason and stays selected so
you can try again; when every request went through, select mode ends. **Done** leaves select mode and
forgets the result. Only the requests loaded on screen can be selected: **Load more** brings in older
ones. In All servers each request is sent to its own server, and the failure line names the server.

#### The count beside Requests

The **Requests** menu item shows how many requests need approval, in the drawer and in the iPad
sidebar, whichever page you are on. It is read from the server when the app opens or returns to the front, when
you pull down on Requests and when you answer requests. In All servers it adds up every server. VoiceOver says *3
requests need approval*.

#### When requests aren't available

The app asks the server whether request administration is running. If it is not, or the queue answers
that the service is unavailable, the page says *Request administration isn't available on this server*
with nothing to retry; the page stops refreshing and the menu shows no count. Pull down to check again.
In All servers that server's section says the same while the other servers carry on.

In **All Servers** each server has its own section. A requester is named from that server's own account
list (read in the background with `GET /api/v2/admin/users`); until the list is read, or when a server
does not answer it, the row says *User <id>*. The details sheet has a **Server** row that names the
server the request belongs to. While a row's action is running its buttons are off and a spinner shows,
so the same action cannot be sent twice.

### 4.6 Users

A searchable list — the search field prompt is **Search by username or email**, and filtering is
instant because it happens on the device. Each row shows the username, the email, and *<Role> ·
Enabled* or *· Disabled* (the server owner is labelled *Owner*). Tap a row to open that user's page.
Two toolbar buttons: **Add User** (+) and **Invitations** (envelope).

The list works the same from a single server and from **All Servers**. In All Servers each server has
its own section, the user page names its server (*Server: <name>*), and everything you change there
is sent to that server only.

#### 4.6.1 Add User

A sheet titled **Add User** with **Username**, **Email**, **Password** and a **Role** picker (**User**
/ **Admin**). **Add** is enabled once the three text fields are filled; **Cancel** closes the sheet.
A server error is shown in red inside the sheet.

#### 4.6.2 The user page

Tap a user. The page is titled with the username. At the top:

- **Pills** — the role, **Active** (green) or **Disabled** (red), **Password sign-in** or **External
  sign-in**, and a **Temporary password** badge while the person still has to choose a new password.
- The email, when they joined and when they were last active (*No recorded activity* until they
  have been).
- **Actions** (each a button at least 44 points tall):
  - **Reset password** — for an account that signs in with a password. The sheet offers what the
    server allows:
    - **Send reset email** — a one-time reset link by email. It is issued once; if the server could not
      confirm delivery the sheet says so and does not offer a second send until you close and reopen
      it. When the server cannot send mail, the sheet says so.
    - **Create link** — a one-time link for you to give the person yourself, when the server has a
      public address. It is shown once, with **Copy link** (a copy kept on this device only, which
      expires after 10 minutes) and **Share link**, and it is forgotten when you tap **Done** or close
      the sheet: it is never stored or logged. A new link replaces any earlier one, and the person
      chooses their own password with it. Not offered for a disabled account.
    - **Set temporary password** — opens the password sheet below.
  - **Set password** — type a new password (at least 8 characters, at most 72 bytes) and leave **Require
    change at next sign-in** on for a temporary one; you share it yourself. It is a button of its own
    for an account that signs in through an external provider (setting a password turns password
    sign-in on for the account; the provider keeps working), and for an account with a password it is
    **Reset password → Set temporary password**, titled *Set a temporary password*, which replaces the
    current password. Offered for every enabled account you may manage.
  - **Disable account** asks *Disable <username>?* — *They can't sign in until you enable the account
    again. Their profiles, history and downloads are kept.* **Enable account** does not ask.
  - **Delete account** (red) asks *Delete <username>?* — *This deletes the account, its profiles and
    its history. This cannot be undone. To keep them, disable the account instead.* Success gives
    a haptic and returns to the list.

  Actions you may not take are not shown. You cannot disable or delete your own account or the
  server owner, and the server owner is the platform administrator: only the owner can change
  another admin, so an organization administrator sees an admin's or the owner's page as view-only,
  with a line saying why (*This is the server owner. Only the owner can change this account.* or
  *Only the server owner can change another admin account. You can view it.*). There is no
  impersonation or "View as".

Below the header, a row of tabs: **Overview**, **Profiles** (only when the server says it can manage
an account's profiles), **Access & limits**, **Sign-in**, **Activity**, **Downloads** (only when the
server says accounts have downloads) and **Preferences**. Tap a tab, or
**swipe sideways anywhere on the page** to step to the next or previous one. A swipe past the first
or last tab does nothing and a swipe never leaves the page: the way out is the **Back to users**
button in the top-left corner.

If another administrator deleted the account while you were looking at the list, the page says
*User not found*.

##### Overview

**Watching now** comes first: what the account is playing right now, each stream with its title, whether
it is *Playing* or *Paused*, the app and device, and how far in (*10:00 of 2:00:00*), or *Not watching right
now*. It reads `GET /api/v2/admin/sessions?user_id=` and follows the server's sessions live while the page is on
screen. Then **Details** (email, role), **Access** (the limits the server applies to this account: libraries, max
streams, transcodes and profiles, downloads and requests), **Profiles** with when each was last
seen, and — when the server reports it — the last 30 days: plays and how many finished, watch time
and when something was last played.

##### Profiles

The account's profiles, each with what it is in words — *Main profile*, *Children's profile*, *PIN set* or
*No PIN* — and when it was last seen. **Add profile** takes a name (up to 64 characters) and an optional
PIN. Each profile offers **Rename**, **Set PIN** or **Change PIN**, **Clear PIN** (after asking) and
**Remove** (after asking; the main profile cannot be removed: delete the account instead). Clearing a PIN
is how a forgotten one, the main profile's included, is reset. A PIN is 1 to 72 bytes; changing or
clearing it signs out anyone using the old one. The tab is read-only (*Only the server owner can change
this account's profiles. You can view them.*) where you may not change the account: only the server owner
changes another admin's or the owner's profiles. Each change is one request, sent once, and the list is
read again afterwards, a failed change included.

##### Access & limits

One form, one **Save changes** button. It edits:

- **Access group** — **No group** or one of the server's groups (with a line of what the group
  allows). Admins are never in a group and see a note instead.
- **Libraries** — **Use the group's libraries** / **Use the server default** (whichever applies to
  the group picked right now, with the libraries it resolves to spelled out) or **Choose for this
  account**, which lets you tick libraries. Choosing none says *This account won't see any library.*
- **Permissions** — **Marker editing**, **Metadata curation** and **Watch Live TV**. When the access
  group does not allow one, its switch is off and locked and the row says which group blocks it;
  if the permission is still set on the account, **Remove from account** clears it.
- **Limits** — **Max streams**, **Max transcodes** and **Max profiles**, each a number with an
  **Inherit** switch (the number shown while inheriting is the one the account gets), and
  **Downloads allowed**, **Requests allowed**, **Transcode allowed** and **Audio transcode allowed**,
  each **Inherit (On)** / **Inherit (Off)**, **Off** or **On**.

**Save changes** sends only what changed, in one request that carries the version of the account the
page last read. Only the server owner changes an admin's access and limits, including their own;
for anyone else's the form is read-only and says so. If you edited something and press **Back to
users**, the app asks *Discard changes?* — **Discard** / **Keep editing**. Your edits also survive
a trip to another tab.

##### Sign-in

How the account signs in (**Password** card), then **Sessions & devices**:

- **Sessions** — every active sign-in: device name (or *Unknown device*), its address, and *this
  session* for the one you are using, when it was last seen (*Last seen 3 hours ago*, a date after 30
  days, or *No activity since signing in*), when it expires (*Expires Dec 3, 2026*, or *Expired …*) and
  when it was created. **Revoke** asks *Revoke this session?*; **Revoke all sessions**
  asks *Revoke ALL sessions?* — *Every device this user is signed in on will be signed out
  immediately. If this user is your own admin account, this will also sign YOU out.* and then says
  how many it ended. Both are hidden for an account you may only view.
- **Devices** — every device the server knows for this user, with its platform and when it was last
  seen (*Not seen yet* if never). Devices are listed only: the server has no way to revoke one.

##### Activity and Downloads

**Activity** shows the user's **Watch history** (**Load more** for older plays) and the **IP
addresses** they signed in from over the last 30 days. **Downloads** shows what they have on their
devices: totals, then each download with its status and size. Both are read-only.

##### Preferences

The settings the person's apps saved, by level. A menu at the top picks the level: **Account-wide**
(when any exist), then for each profile **All devices**, each device the profile uses, each app family
(TV, Mobile, Tablet, Desktop, Web), each library and each series, with how many settings each holds.
A level lists only what it stores, each setting with what it replaces (*Replaces <profile>: …* or
*Replaces app default: …*). Names, wording and types come from the server's settings contract:
a yes/no setting is a switch, a fixed list a menu, a number or text a field with its own **Save**
that checks the range first; anything more complex is shown but marked *View only*. The trash button
removes the setting from that level after asking (*Use <profile>'s value?* or *Go back to the app
default?*); **Add a setting** lists what the level can still hold and starts each at the value it
replaces, so nothing changes until you edit it. If the contract cannot be read, every value is
shown and none can be edited. Each change is one request for one setting on one server.

#### 4.6.3 Edit conflicts

Saving access and limits, setting a password, enabling or disabling an account, and deleting one
all check that the user has not changed since the app read it. If another administrator changed the
same user first, the app shows *This user changed since it was loaded. Review it and try again.*
and reads the account again, so the form now shows what is stored. Nothing is overwritten silently
and the app never retries a conflicting save by itself. The same applies to a setting under
**Server** and to a schedule under **Jobs**.

**Audit** still shows *as <admin id> → <user id>* for requests that another client made while
impersonating.

#### 4.6.4 Invitations

The **Invitations** toolbar button opens a list titled **Invitations** with an **Invite User**
button. Each row shows the email with a status badge (*Pending*, *Accepted*…), *<Role> · Expires
<date>* and the note if one was given. When empty: **No Invitations** — *Invite a new user by email.*

- **Invite User** opens a sheet titled **Invite User**: **Email**, **Role** (**User** / **Admin**),
  **Note (optional)**, with **Cancel** and **Send** (enabled once an email is entered).
- Pending invitations can be swiped left (or long-pressed) for **Resend** and **Revoke**. **Revoke**
  asks *Revoke the invitation to <email>? This cannot be undone.* — **Revoke Invitation** / **Cancel**.
- After **Send** or **Resend**, a sheet titled **Invitation Sent** shows **Email** and **Role**,
  then either *Invitation email sent* (green) or *Invitation email was NOT sent* (orange), and —
  when the server returned one — the **Invite Link** with **Copy Link** and **Share Link**. **Copy
  Link** puts the link on this device's clipboard only (it is not handed to your other Apple devices)
  and the clipboard entry expires after ten minutes; use **Share Link** to send it somewhere. The
  footer reminds you: *This link is shown only once — the server doesn't store it in a retrievable
  form.* If there is no link and the email was not sent: *No link is available and the email wasn't
  sent. Use Resend to try again.* **Done** closes the sheet.

### 4.7 Settings

**Settings** opens the server's own page: a **Server** section, a list of named **Pages**, and **Other
settings**. Settings belong to one server. In *All servers* the page lists each server with its uptime
and *Restart needed* when it waits for one; tap a server to open its Settings.

**Server** shows **Uptime** (for example *3d 4h*) and **Restart**: *Not needed*, or *Needed for Public
URL and Hardware acceleration*, naming the settings that wait for a restart. **Restart server** asks
*Restart this server?* and says what it does: *The server shuts down. It comes back on its own only if
a service manager such as Docker or systemd restarts it; otherwise, start it again yourself. Active
streams will be interrupted.* After the request a line says *Restart requested* (with how many streams
were told), or *A restart is already in progress*.

**Pages** are General, Network access, Sign-in, Playback, Logging, Email, Notifications, Downloads and
Requests. Each setting has a label, the web admin's help text and a control that fits it: a switch, a
number with its unit, a picker or a text field. Settings still at their default value are listed and
can be changed. A setting that only takes effect after a restart says *Applies after a restart*, and one
the server's environment owns is read-only. **Secrets** (the mail password, the Redis address) are never
shown: the row says *Set* or *Not set*, takes a new value, and **Clear** removes it.

Changes are saved together. Once you edit anything, a bar appears under the page with the count,
**Discard** and **Save**; the menu and the swipe between pages stay still until you save or discard.
If another administrator changed the settings meanwhile, the page says *Settings changed on the
server*, keeps your edits, and offers **Keep my changes** (save over the server's values) or **Use the
server's values**. Turning off **Allow password sign-in** is refused until an admin is a break-glass
account; the page says so.

**Search settings** (the field at the top) finds single settings by label, help text, key or the web
admin's search words, as well as pages. **Other settings** lists every stored setting the pages do not
name; tap one to edit it in the one-setting editor.

Tests answer *is it broken?*, each ending in **Passed** or **Failed** with the server's reason:

- **Email**: **Send test email** sends one real message through the saved mail settings.
- **General**: **Check connection** tests the Redis values on screen, saved or not.
- **Notifications**: **Test** sends one sample message to a server channel; a failing channel shows its
  last failure.
- **Sign-in**: **Test connection** asks a single sign-on provider to confirm its saved connection, step
  by step.

**Network access** lists the overlay providers (Tailscale, NetBird) and their hosts with state, the
address clients reach them at, **Connect**, **Disconnect** and **Open the authorization page**.
**Requests** holds *Allow requests*, *Approval*, the default *Request limit* and *Limit window*,
*Request titles added to a watchlist* and *Also request a 4K version of every title*.

The **Logs** page has a **Log level** button that opens the Logging page in a sheet.

> Pages that are not in the app yet (Appearance, Storage, Library, Search, Providers, AI,
> Compatibility, Security) stay on the web admin; their stored settings are under **Other settings**.

### 4.8 Audit

The server's request log, newest first, for finding who changed what. At the top, **Person** (choose a
name; **Everyone** clears it). Each row leads with what was done: the action (*user.update*, or *HTTP
request* when the server records none) and, under it, one line per changed field with its before and after
values (*role: user → admin*), then the target (*user #42*), then the request (*PUT /api/v2/admin/users/42*),
and last the time, the status (*Failed with 500* from 400 up), and *User <id>* or, for a call recorded as
made while impersonating (by another client), *as <admin id> → <user id>*.

Tap a row for **Audit entry**: the changes, the request and its status and duration, the target, request ID,
node, the person, the client address and user agent (only where the app shows addresses), and the session and
playback session. **Copy** and **Share** send it as text. **Load more** fetches the next page. This page loads
when opened, when you change the person and on pull-down, not on a timer.

### 4.9 Logs

The server's own operational log (different from Audit, which records requests). The filters at the top
reload shortly after you change them: **Level** (**All**, **Debug**, **Info**, **Warn**, **Error** or **Warn
and error**), **Search messages**, **Component** (type a name or use the list beside it), **Request ID** and
**Playback session**. Each row shows the level in words (*Error*, *Warning*, *Info*, *Debug*; errors and warnings stand out), the time in your own
time zone, the message, and the component with *· User <id>* and the node when present.

Tap a row for **Log entry**: request ID, node, method, status, duration, path, client address (only where the
app shows addresses), user, session, playback session and the attributes as JSON. **Logs for this playback
session** narrows the page to that session. **Copy** and **Share** send the entry as text.

From **Now playing** (the menu on a stream) and from a **Play details** sheet, **Logs** and **FFmpeg logs** open
this page filtered to that playback session (FFmpeg logs also set the component to *ffmpeg*). A summary sits
on top: the playback session, the application, FFmpeg and audit counts (*or more* when the server has more
than one page of them), when the session was first and last seen, and the nodes involved, with **FFmpeg
lines only** and **Show all logs**. **Load more** fetches the next page.

### 4.10 Organizations (platform administrators)

**Platform → Organizations** lists every organization on the server. Any platform administrator sees it, not only
the server Owner, on a Bloem server. Each row has the
organization's name, its short name, its status in words (**Active**, **Suspended** or **Setting up**) and how many
people, profiles and libraries it has.

- **Find one.** Type in the search field to match a name or short name, and use **Status** to show only active,
  suspended or setting-up organizations. Fifty are listed at a time; **Show more** adds the next fifty. Pull down to
  refresh.
- **Open one.** Its page shows its **Status**, its **Owner** by name, the counts, its **Members** with each one's role
  (**Owner**, **Administrator** or **Member**) and status (**Active**, **Suspended** or **Invited**), and its **Plan**.
  If the owner's name can't be read the page says *Not available*; it never shows an account number as a name.
- **Open as administrator.** Shown only for an organization your own account administers on this server. It enters
  organization mode for that organization, as choosing it in the context menu does. For any other organization there
  is no such button: use **Support Access** (4.11, server Owner only).
- **Suspend organization.** Asks first. The question says how many active members lose access and that nothing is
  deleted. The organization stays suspended until you tap **Reactivate organization**, which asks first and says its
  members can use it again. The change is sent once; if someone else changed the organization in the meantime, the
  page reloads and says *Someone else changed this just now. It has been reloaded; check it and try again.*
- **Plan.** Shows the plan the organization is on and its revision, the limits on the whole organization, when the plan
  was last applied, and the default settings the plan gave its members. To change it, choose a plan under **Plan** and
  tap **Preview changes**. The confirmation names the change (for example *Family, revision 3 → Premium, revision 2*),
  lists each setting that changes in words (*Screens at once goes from 2 screens to 4 screens*), and says it reaches
  members on the default settings while access groups the organization made itself stay as they are. **Apply** puts
  the organization on the plan. If the plan changed after the preview, or the preview is older than ten minutes, the
  app asks you to preview again. Choosing the plan it already has says *Nothing changes*.

Plans are made and revised in the web admin. Libraries in a plan are listed by number (*Library 3*) because the app
can't read a customer's library names.

**In All servers**, **Organizations** shows one section per saved server, each with that server's first fifty
organizations for the search and status you chose. A server that needs a new sign-in offers **Sign In** in its own
section, and a server that can't be reached offers **Retry**; neither hides the others. A server that is not a
Bloem server (a plain Silo server) has no section, and when none of the saved servers is a Bloem server the menu has
no Organizations page at all. Tapping an organization opens its page
for that server, and every change goes only to that server. When a server has more than fifty, **Show all on (server)**
opens that server's own Organizations page.

### 4.11 Organization mode

An **organization** is a customer's own part of a server: its members, profiles, access groups and the
libraries it may use. If you administer one, the app shows only that organization's pages and only that
organization's data. The server's owner sees an organization this way too: one they are a member of from
the context menu, and any other one through **Support Access**, by stating a reason (below).

**Getting in.** Tap the server in the list. An account that administers one organization lands in it
straight away; one that administers several sees **Choose an organization** first, and
**Choose another organization** in the top bar of the menu goes back to that choice. The menu is titled
with the organization's name. If the server turns the organization away, you see why and **Choose another
organization** (below); an organization that was turned away is left out of the choice.

**The pages.** Opened from the server list, the menu is a list on iPhone and iPad alike; each page opens over
it, and **Back** returns to the menu, then to the server list. It holds the web admin's organization menu, plus the
organization's own **Now playing** (second, after Overview) on a server that offers it, and nothing else — no
Dashboard, Scheduled tasks, Settings, Logs or Organizations. It is drawn like the platform menu, with a group heading
and the same rows:

| Page | What it is for |
|---|---|
| **Overview** | Members (and how many are active), profiles, the libraries the organization owns and the ones the server shares with it, its owner by name (read from the organization's own people list; *Not available* if it can't be read, never an account number), and its settings revision |
| **People** | Everyone in the organization — see below |
| **Now playing** | The organization's own live streams: stop one, or put a message on the screen (only on a server with organization support). On a server that supports live updates it changes by itself when a stream starts, pauses or stops; People and Activity do too |
| **Cohorts** | Read only: groups of accounts that share the same settings |
| **Access groups** | Create, edit and delete the groups that decide what each profile can use |
| **Libraries** | What members can reach at most; pause, restore or give back a shared library |
| **Invitations** | Invite someone, with an access group and a note; resend or revoke |
| **Access checks** | Read only: the access checks the server recorded, and why each was allowed or refused |
| **Activity** | Changes made to the organization, newest first |

**Search.** The menu has the same **Search** button as the rest of the app (*Search admin sections*). It
searches the organization's pages only, under the group **Organization**, by name, description and the
web's words (*invite* finds **Invitations**, *audit* finds **Activity & Audit**, *permissions* finds
**Access groups**); **Streams** is listed only on a server that offers it. Tapping a page opens it over
the menu on iPhone, or selects it in the sidebar on iPad.

**People.** Each person shows their name and email, a status (**Active**, **Suspended**, **Invited**), an
*Administrator* and *You* tag where they apply, when they were last active, and each profile with its access
group. Client IP addresses are never shown in organization mode.

- **Search** (pull down on the list) matches name, email or profile. **Membership status** and **Access group**
  narrow the list; **Sort people** orders it by **Name**, **Email** or **Recent activity**; **Active since** keeps
  only people active in the last 24 hours, 7, 30 or 90 days. **Show more** loads the next page.
- The **…** menu on a row (**Actions for <name>**) offers **Details**, **Suspend** or **Reactivate**, and
  **Move <profile> to an access group**. **Suspend** and **Reactivate** each ask first. **Suspend** never appears
  on your own row, and the organization's owner cannot be suspended — the app shows the server's refusal.
- **Details**, or tapping the row, opens the person's own page: their membership and status, last activity, each
  profile with its access group, the changes made to their membership among the newest entries of the
  organization's activity (the server has no per-person activity list, so the page says how many entries it
  looked through), and the same Suspend, Reactivate and move actions. On a server with organization support the
  page also helps the person back in (**Helping someone back in**, below); on an older server it lists what you
  cannot do there instead.
- **Select people** lets you change several people at once, as the web's bulk bar does. Tick people, or tap
  **Select all N** to take everyone the current filters match. A bar at the bottom shows how many are selected and
  offers **Move to access group**, **Reactivate** and **Suspend**. On a narrow phone, or with large text, the
  actions wrap onto further lines; the list scrolls above the bar and no row is ever covered. Each action asks
  first, naming the organization, the filters in words (*matching "sam", in Family, active in the last 7 days*)
  and, for **Select all**, how many more match but are left out. Afterwards a result card says how many were
  changed, skipped or failed, and for each skipped or failed person why, in the web's words (*already had these
  settings*, *is the organization owner and can't be changed here*, *skipped so you keep your own admin access*, …).
  - **Select all N** hands the change to the server as one job. The card follows it until it finishes.
  - People you **ticked** are changed by the app one after another, each with its own change. If one cannot be
    changed the rest carry on; if the organization is taken away from you partway, it stops.
  - Nothing is ever sent twice. If the server says someone changed first, that person is reported, not retried.

**Helping someone back in.** On a server with organization support (it advertises `organization_support_v1`), a
person's page offers what the server says it can do, and nothing it cannot:

- **Password.** **Email a reset link** sends a link to the person's own address (it works for 24 hours).
  **Create a reset link to hand over** shows a link once, with **Copy link** (a local pasteboard entry that expires
  after ten minutes) and **Share Link**; it works once, for 4 hours, and the person also gets an email saying a reset
  was issued. **Done** forgets the link: the app never stores it and cannot show it again. Either way you never type
  or see a password, and a new link replaces any earlier one. Each asks first. If the email may not have gone out, the
  page says so; the link still works, and sending another replaces it.
- **Signed in** lists the person's live sign-ins by device, platform and profile, with when each was last seen (never
  an address). **Sign out of this session** ends one; **Sign out everywhere** (asks first) ends them all, so every app
  asks them to sign in again. Their personal API keys keep working.
- **Devices** lists the devices their profiles used. **Sign out of this device** (asks first) ends that device's
  sessions and forgets it with its settings; their other devices stay signed in, and a stream already playing is not
  stopped.
- **Profiles.** **Add profile** asks for a name and, optionally, an access group (otherwise it joins the group their
  other profiles inherit). Each profile's **Change** menu offers **Rename…**, **Clear PIN** (when it has one; they
  choose a new PIN themselves) and **Remove profile…** (not for the household's main profile; its watch history and
  collections are deleted, which cannot be undone). You never set a PIN or age limits. *Main profile* and *PIN set*
  are shown on the profile.

**Who you can help.** Administrators help ordinary members. The organization's **owner** can also help its other
administrators, and only the platform operator helps the owner. Nobody helps themselves here: on your own page the
app says to change your password and sign out in the app. When the server refuses, the page says why, for example
*This person is an administrator. Only the organization's owner can help another administrator.* or *This person is
the organization's owner. Only the platform operator can help the owner.* Other refusals say that the membership is not
active, that the person signs in through another provider, that the server cannot send email (create a link instead),
that another profile already has that name, or how long to wait after too many support actions in a short time.

**Streams.** The organization's own streams: who is watching, what, on which device and app, and whether it plays
directly or is converted, with a progress bar that moves while it plays. Tap a stream for its details. Addresses,
server names and routing belong to the server and are never shown. The **…** menu offers **Message** (an optional
title and the text, shown on the player) and **Stop** (asks first; playback stops at once). The server decides whose
streams you may stop: not your own, and not a server operator's. The page asks the server again every ten seconds
while it is open.

**Support Access (the server Owner only).** On a server with organization support, the server Owner's menu (under
**Platform**) has **Support Access**: every active organization the Owner does not belong to. Tap one, say why you are
opening it (10 to 500 characters), and **Open**. The reason, and every change made while it is open, is shown to that
organization's administrators in **Activity** as *Platform support*. Access lasts four hours at most. While it
is open, a banner above the organization's pages says **Support access** and how long is left; on the organization's
menu it has **End access** (asks first). Reopening the same organization during those four hours needs no new reason.
Once the access has ended, the pages close with *Support access to this organization has ended.*

**Access groups.** **New group** asks for a name and opens the group so you can set it up. A group has a name and
description; whether it is the **default for new users** (you can make a group the default, not unmake it); the
libraries it reaches (**every library the organization can use**, or **only the libraries I choose**); the best
picture quality (**Any quality**, **Up to 1080p**, **Up to 4K**); downloads, converted downloads and media requests;
how many screens and conversions at once (0 means no limit); video and audio conversion; and permissions (all, or
a chosen few). **Save changes** writes the whole group. **Delete group** asks first and says where its profiles go:
to the default group. The default group cannot be deleted. A group the server manages through a plan can only be
changed there; the server says so and the app shows its words.

**Libraries & Entitlements.** The top card counts what members can use *right now*: the libraries the organization
owns plus the shared ones that are active — the most any member can see. Each person's plan, access group and profile
can narrow it further. A shared library offers **Pause** (members cannot use it until you **Restore** it) and
**Give back** (members lose it for good; only the server's administrator can share it again; no files are deleted).
Each asks first. The organization's own libraries have no actions here.

**Policy Cohorts** show each cohort's origin (*From plan family, revision 1*, *Changed from another cohort*,
*Organization default*), how many accounts are in it, and its settings as labelled rows — libraries by name, whether
video plays, screens and conversions at once, downloads, best picture quality, media requests and extra permissions.
Expand a cohort for its details (how it was made, revision, the cohort it started from, who made it and when, and
its settings fingerprint). Archived cohorts are listed apart, for the record.

**Policy Decisions** list each access check as *<what>: allowed* or *<what>: refused*, with the reason in plain
words, when it happened and for whom. Tap one to see why: the account and profile, the libraries they could use, what
they asked for (sensitive values show as *Sensitive value hidden*) and the rules that were checked.

**Invitations.** **Invite someone** takes an email address, an access group (or the organization's default) and an
optional note. **No email is sent**: you get a **one-time link** to pass on, shown once with **Copy link** (a local
pasteboard entry that expires after ten minutes) and **Share Link**. It works once and expires after seven days. **Done**
removes it from the app and it cannot be shown again. A pending invitation offers **Resend with a fresh link** (the
old link stops working) and **Revoke** (asks first). An address that already has an account is refused by the server
with its words, and an invitation whose result could not be confirmed is never sent a second time: check the list first.

**Activity** lists the changes made to the organization — its name and status, its members, their plans, bulk
changes, and on a server with organization support the help administrators gave (reset links, sign-outs, profile
edits, stopped streams, and refused attempts) — newest first, with who made each and **Show older**. A change made by
the server operator under support access reads *By Platform support*, and the opening shows its reason. Members' own
sign-ins and playback are not listed.

**When the server turns you away.** The app tells the reasons apart, and each one leaves the pages and offers a way back:

| What you see | Meaning |
|---|---|
| *This organization is suspended. Contact the server owner.* | The organization is suspended |
| *You no longer administer this organization.* | Your role is no longer administrator, your membership ended, or you lost platform authority |
| *You don't have access to this organization.* | The server does not show this organization to your account at all |
| *Support access to this organization has ended. To keep helping, open it again with a new reason.* | The server Owner's support access was ended, or its four hours are over |

If *Someone else changed this just now. It has been reloaded; check it and try again.* appears, the page has been
reloaded with what the server holds now and your change was **not** applied; look, and ask again.

**What organization mode cannot do.** On a server without organization support there is no password reset, no way to
sign a member out, no profile editing and no streams; the pages show nothing of them. On any server, organization
administrators cannot set a PIN, change age limits, run policy previews or "change plan" jobs, manage storage sources or
request integrations. Those remain with the server's administrator or the web admin.

### 4.12 Libraries

The server's media libraries, one card each, then **Recent scans**. In All servers every server has its own
section; each action on a card goes to that card's server.

**A card** shows the library's name, then its type, how many folders it scans (*1 path*, *2 paths*), and
*Enabled* or *Disabled*, then *Last scanned 2 h ago* or *Never scanned*.

**Scan warning.** When the server has raised one, the card says so in words, with the server's own message
and how long ago: *The scan found no media files* (an empty root: cleanup was paused so nothing is deleted
by mistake) or *A library folder cannot be reached* (a dead root: the files are hidden, and nothing is deleted
until the folder is back). The warning goes away when **Check the mount** finds the storage healthy.

**Scan** starts a scan of the library. The server only answers that it accepted the scan, so the card then
shows what the server's scan runs say: *Scan: Queued*, *Scan: Running*, and afterwards *Last scan: Completed*,
*Last scan: Failed* (with the reason the server gave) or *Last scan: Stopped*, with the counts under it. The page
reads the server when it opens and again each time the server says a scan or refresh changed, and only while the
app is open. **Scan** is off when the server says it cannot run scans.

**Stop** is on while a scan is queued or running. It asks *Stop scans of <library>?* — **Stop scans** /
**Keep scanning** — and, once the server has done it, says how many scans it stopped.

**Check the mount** asks the server to reach every folder of the library and answers in words: *The mount is
reachable*, *The mount cannot be reached* or *The mount is reachable but looks empty* (the folder is there but
every file the library knows of is missing: the sign of a lost mount). Folders with a problem are listed with the
server's reason.

**Refresh metadata** has two choices. **Refresh missing metadata** fetches items never refreshed, missing an
overview or artwork, or that failed a refresh. **Refresh all metadata** fetches every item again, can take hours on
a large library, and asks first: *Refresh all metadata for <library>?* While it runs the card shows *Metadata
refresh: Running* with *40 of 200 items* and **Cancel refresh**; afterwards *Last metadata refresh: Completed, 197
refreshed, 3 failed*. The server runs one refresh per library at a time and says so if you start a second.

**Recent scans** lists the latest 20 scan runs of the server, including those started by a schedule, autoscan or a
file change: the library, the result, where it came from (*Manual*, *Scheduled*, *Autoscan*, *File change*), when,
how long it took, and *New*, *Updated*, *Missing* and *Errors*. If the server cannot list its scan runs, the
libraries still show and this card says why.

Organization mode has no scan page: an organization's libraries are on its own **Libraries** page
(section 4.11), which carries entitlements, not scans.

---

### 4.13 Nodes

The server's stream nodes (Automation group; one server, or a section per server in All servers). Each
node is a card: its **name** and **state** in words (*Healthy*, *Unhealthy*, *Disabled*, *Draining*,
*Drained*), whether it is a transcode or proxy node and its group, a drain line when it is draining (*Draining, 3 jobs still
running* with what happens next), then the load from its last resource sample — **CPU**, **Memory**,
**Disk** (*nearly full* from 85%) and **Network** — or *No resource sample yet* / *The last resource
sample is out of date*; **Capacity** (*2 of 4 transcodes*, or *no limit*), **Egress**, and *Checked 3 min
ago*.

Actions, each after a confirmation except **Check now**:

- **Drain** (an enabled transcode node) — new work goes to other nodes while sessions already on it keep
  playing. **Resume** takes new work again.
- **Disable** / **Enable** — takes the node out of, or back into, use. The write is guarded by the node's
  configuration version; a node without one cannot be changed here, and a node changed elsewhere asks you
  to reload.
- **Check now** — probes the node's health.

The Dashboard's **Nodes** cell opens this page. Adding, editing or deleting a node stays on the web.

### 4.14 Backups

The server's backups (Settings group). The top shows **Last successful backup 2 h ago**, **Next backup in
16 h** (the server's own answer; *Next backup time is not known yet* when it has none, *Nightly backups
are off* when they are off), a running backup's progress and message, a last run that failed or was
interrupted with its error, and the server's warnings.

- **Back up now** starts a manual backup. It is greyed out with the reason underneath while a backup,
  delete, upload or restore holds the lock, the destination cannot be reached, or the encryption key is
  not confirmed.
- **Edit schedule** opens **Backup schedule**: **Nightly backups** (toggle), **Backup time** and **Copies
  kept** (1 to 60). Save writes each changed setting (`backup.enabled`, `backup.time`, `backup.keep`) with
  the settings version read when the sheet opened; if the settings changed meanwhile, the sheet says so
  and **Reload current values** takes the server's.
- **Saved backups** show kind (*Nightly*, *Manual*, *Before restore*, *Before upgrade*), status (*Complete*,
  *Complete with warnings*, *Unreadable*…), age and size. **Delete** asks first and is not offered while
  the backup lock is held.

Restoring a backup, uploading one, downloading files and setting up an S3 destination stay on the web
admin; the page says so in one line.

### 4.15 Plugins

The installed plugins (Settings group). A **Show** menu filters **All**, **Needs attention**, **Update
available** and **Off**, each with its count; search matches a plugin's name, id and summary. Problems
come first. A plugin **needs attention** when its process failed, a resident plugin is restarting, a
required setting has no saved value (*Needs setup — Missing: API key*), its last update was refused, or its
release signature is invalid; a plugin that is off never does.

Each card shows the name, version, status in words (*Running*, *Active*, *Failed*, *Restarting (3)*,
*Stopped*, *Off*), its error or what is missing, and update information (*Update to 1.1.0 available*,
*Updates paused*). Actions, each confirmed: **Restart** (a resident, enabled plugin that is not starting),
**Turn off** / **Turn on**, and **Update to <version>** (not offered for a plugin installed without a
repository, or while updates are paused). The catalogue, installs and plugin settings stay on the web.

---

### 4.16 API keys

**API keys** (menu group **Settings**, one server only) lists every API key on the server, newest first,
50 at a time with **Load more**. Each key shows its label, its owner (*Owner: alice*), what it may do
(*Full access*, or *2 scopes: library.read, stats.read*), when it was last used (*Never used*, *Last used
yesterday*, or a date after 30 days), an *Elevated rate limit* line where that applies, and the key's
short, non-secret prefix. The page never shows a key's secret.

**Revoke** asks *Revoke <label>?* — *<label> stops working at once, and anything using it is refused from
now on. This can't be undone.* — with **Revoke key** / **Keep key**. The app first reads the key's current
version and sends it with the delete, so a key that changed since the list was read is not revoked blind:
you are told *This key changed since the list was loaded. Check it and try again.* and the list is read
again. A key someone else already revoked counts as revoked. Creating keys and changing a key's rate tier
stay on the web admin, where a new key's secret can be shown once. If the server runs no API key
administration, the page says *API key administration isn't available on this server*, with nothing to
retry.

---

## 5. Quick reference: where things are

| I want to… | Go to |
|---|---|
| See who is watching right now | **Now playing** (or **Dashboard → Now playing**; **Active streams** shows the count) |
| End someone's playback | **Now playing → (session) ⋯ → Terminate** |
| Put a message on a viewer's screen | **Now playing → (session) ⋯ → Message** |
| Approve a request | **Requests → (request) → Approve** |
| Approve or decline many requests at once | **Requests → Needs approval → Select → Select all → Approve N** or **Decline N** |
| See how many requests wait without opening Requests | The count beside **Requests** in the menu |
| Scan one library | **Libraries → (library) → Scan** |
| See whether a scan found the files | **Libraries → Recent scans** |
| Check that the server can reach a library's storage | **Libraries → (library) → Check the mount** |
| Fetch missing posters and descriptions for a library | **Libraries → (library) → Refresh metadata → Refresh missing metadata** |
| Run a scan now | **Scheduled tasks → (task) → Run now** |
| Change how often a task runs, or move it to another time of day | **Scheduled tasks → (task) → Edit schedule → Save** |
| See whether last night's task ran and how it ended | **Scheduled tasks → (task) → Recent runs** |
| See what a restore or library refresh did | **Scheduled tasks → Job history** |
| Take a transcode node out of use for maintenance | **Nodes → (node) → Drain** |
| Back up before a risky change | **Backups → Back up now** |
| Move the nightly backup | **Backups → Edit schedule → Backup time** |
| Restart a crashed plugin | **Plugins → Needs attention → (plugin) → Restart** |
| Invite someone by email | **Users → Invitations → Invite User** |
| Create an account directly | **Users → Add User** |
| Sign a lost phone out of an account | **Users → (user) → Sign-in → Revoke** |
| Tell a lost phone from the TV in use | **Users → (user) → Sign-in** (last seen and expiry on each session and device) |
| See what someone is watching right now | **Users → (user) → Overview → Watching now** |
| Give a locked-out person a way back in | **Users → (user) → Reset password → Create link** (or **Set temporary password**) |
| Clear a forgotten profile PIN | **Users → (user) → Profiles → Clear PIN** |
| Revoke a leaked API key | **API keys → (key) → Revoke** |
| Help a member of your organization who forgot their password | **People → (person) → Password → Email a reset link** or **Create a reset link to hand over** |
| Sign a member of your organization out of a lost device | **People → (person) → Devices → Sign out of this device** |
| Clear a forgotten profile PIN in your organization | **People → (person) → (profile) Change → Clear PIN** |
| Stop a stream in your organization | **Streams → (stream) ⋯ → Stop** |
| Open a customer's organization to help its administrator (server Owner) | **Platform → Support Access → (organization) → reason → Open** |
| Look up a customer organization, its owner and its members | **Platform → Organizations → (organization)** |
| Block an organization's members until further notice | **Platform → Organizations → (organization) → Suspend organization** |
| Put an organization on another plan | **Platform → Organizations → (organization) → Plan → Preview changes → Apply** |
| Limit a user to two streams | **Users → (user) → Access & limits → Max streams** |
| Change a server setting | **Server → Settings → tap the row → Save** |
| Restart the server | **Server → Restart Server** |
| Find out why something failed | **Logs** (level **Warn and error**) and **Audit** (status codes) |
| Watch several servers at once | **Dropdown → All servers** |
| Forget a server | **Menu → Manage servers → ••• → Remove Server** |
| Sign out of a server | **Menu → Manage servers → ••• → Forget credentials** |
| Jump to a page by what it does | **Search** in the top bar |
| Add a server | **Menu → Manage servers → Add Server** |

---

## 6. When something is not working

| What you see | What it means | What to try |
|---|---|---|
| *The server address must use HTTPS.* | You typed `http://` | Use `https://`; the app cannot use plain HTTP |
| *Could not reach that server.* on Connect | Wrong address, untrusted certificate, a redirecting proxy, no route, or Local Network permission denied | Open the address in Safari on the device; allow Local Network in Settings; fix; retry |
| The server's own error on Connect, and the server is not saved | The account is not an administrator | Use an administrator account |
| *That address isn't a Silo server. Check it and try again.* | The address is not the server's base URL | Remove any path from the address |
| **No Admin Access** | The account lost its administrator role after it was added | Tap **Retry** if the role was just restored; otherwise remove the server and add it with an admin account |
| **Incompatible Server Response** | The address answers, but not with a Silo server's API | Fix the address or proxy, then **Retry** |
| **Sign in** every time | Sessions revoked on the server or a short token lifetime | Sign in; if it keeps happening ask whoever runs the server to check sessions |
| *Can't reach the server*, *No access* or *Server error 500* on a tab | The list request failed, timed out or was refused | Tap **Try again** or pull to refresh; check the server in a browser |
| Red text under action buttons | The server refused the action | Read the message; it is the server's own reason |
| *Sign in again to <server>…* in All Servers | That server's sign-in expired | Sign in inline |
| **Organizations** page missing | The page appears only for a Bloem server (a server that answers `/api/bloem/v2/capabilities`); a plain Silo server has none | Nothing to fix |
| A tile, chart or list is missing from the Dashboard | That section has no data yet, or (Egress now) its newest sample is over two minutes old | Wait for the next refresh; the metrics sampler writes one sample a minute while the server runs |
| A Dashboard section shows an orange error under its last numbers | Its latest refresh failed | Pull down; the other sections are unaffected |
| *This server needs a newer version of Bloem Admin.* | The server no longer accepts this app version | Update the app |
| **Server Health** missing | The server cannot measure its host | Nothing to fix |
| *Turn on a passcode, Face ID or Touch ID…* and **Try again** | No passcode and no Face ID / Touch ID on the device | Set a passcode in Settings; the app will not open without one |
| Face ID asked again after Control Centre | The app re-locks whenever it becomes inactive | Expected |

---

## Glossary

- **Admin gate** — the check made when you open a server, that your account can administer it.
- **All servers** — the scope that shows every server's data in sections.
- **Auth session** — one sign-in of a user on one device (Users → Sessions).
- **Direct play / Transcode** — the file is sent unchanged / converted on the fly for the client.
- **ETag** — the version tag the app reads with a user, setting or schedule so a save can tell whether someone else changed it first.
- **Invitation** — an emailed link that lets someone create their own account.
- **Playback session** — one viewer playing one thing on one client (Streams).
- **Request** — a viewer asking for media the library does not have.
- **Tenant** — a billing/provisioning group on a multi-tenant server (the **Organizations** page); it is hidden in this version.
- **Trigger** — a rule that starts a task: an interval, a time every day or week, or server startup.
- **Drain** — stop sending new work to a transcode node while its sessions finish.

## Source References

- `BloemAdmin/App/LockScreenView.swift`, `AppLockState.swift`, `BloemAdminApp.swift` — lock screen, fail-closed behaviour, shield window
- `BloemAdmin/Networking/ServerEndpointValidator.swift`, `ProductionSession.swift` — address rules and messages, redirect refusal
- `BloemAdmin/Realtime/*.swift` — the events socket behind Now playing: frames, ticket and handshake, the shared connection and its once-a-minute fallback, reconnect backoff
- `BloemAdmin/Users/UserEditor.swift`, `ServerConfig/SettingEditor.swift`, `Jobs/ScheduleEditor.swift` — edit conflicts
- `BloemAdmin/Jobs/AdminTask.swift` — schedule validation messages, one-action-at-a-time gate
- `BloemAdmin/Shell/*` — destinations and groups, top bar, menu, page search, swipe, context dropdown
- `BloemAdmin/App/AppRootView.swift`, `AppSettingsView.swift` — scope, Manage servers and Settings routing
- `BloemAdmin/Servers/ManageServersView.swift`, `AddServerView.swift`, `AdminGateView.swift`, `SingleServerPages.swift`, `AllServersView.swift` — Manage servers, add-server sheet, gate, a server's pages, All servers
- `BloemAdmin/Streams/AggregateStreamsView.swift` and sibling `Aggregate*View.swift` — All Servers sections and the inline sign-in row
- `BloemAdmin/Dashboard/DashboardView.swift`, `AggregateDashboardView.swift`, `DashboardSectionsView.swift`, `DashboardTrendViews.swift` — the dashboard, its sections and charts
- `BloemAdmin/Dashboard/DashboardInsights.swift`, `DashboardSeries.swift`, `DashboardTrends.swift` — section order, tile rules, series building and chart text
- `BloemAdmin/Streams/StreamsListView.swift`, `StreamRowView.swift` (the card, reusable as the dashboard's Now playing preview), `StreamControls.swift`, `StreamFacts.swift`, `StreamPresentation.swift`, `StreamProgressTicker.swift`
- `BloemAdmin/Activity/ActivityListView.swift`, `HistoryRowView.swift`, `HistoryDetailSheet.swift`, `HistoryFilter.swift`, `PlaybackHistoryPresentation.swift`
- `BloemAdmin/Jobs/JobsListView.swift`, `JobDetailView.swift`, `TaskViews.swift`, `TaskRowPresentation.swift`, `HistoryPager.swift`, `AdminJob.swift`, `ScheduleEditorSheet.swift`, `TimedTriggerDraft.swift` — Scheduled tasks, task history, Job history, the schedule editor
- `BloemAdmin/Nodes/*`, `BloemAdmin/Backups/*`, `BloemAdmin/Plugins/*`, `BloemAdmin/Shell/SectionModel.swift`, `SectionPageViews.swift` — Nodes, Backups and Plugins pages and their All servers sections
- `BloemAdmin/Requests/RequestsListView.swift`, `RequestDetailView.swift`
- `BloemAdmin/Users/UsersListView.swift`, `UserDetailView.swift`, `UserAccessTab.swift`, `UserPreferencesTab.swift`
- `BloemAdmin/Invitations/InvitationsListView.swift`
- `BloemAdmin/ServerConfig/ServerConfigView.swift`
- `BloemAdmin/Audit/AuditListView.swift`, `AuditDetailSheet.swift`, `AuditEntryPresentation.swift`, `AuditFilter.swift`
- `BloemAdmin/Logs/LogsListView.swift`, `LogDetailSheet.swift`, `LogFilter.swift`, `LogEntryPresentation.swift`, `PlaybackSessionSummary.swift`, `PlaybackSessionSummaryView.swift`
- `BloemAdmin/Users/UserPickerOptions.swift`, `UserFilterControls.swift` — the person and profile pickers; `BloemAdmin/Shell/IncidentDetailViews.swift` — the detail sheets' shared fields, Copy and Share
- `BloemAdmin/Tenants/TenantsListView.swift`
- `BloemAdmin/Organization/OrganizationHost.swift`, `OrganizationPeopleView.swift`, `OrganizationPersonView.swift`, `OrganizationGroupsView.swift`, `OrganizationLibrariesView.swift`, `OrganizationInvitationsView.swift`, `OrganizationOverviewViews.swift` — organization mode (4.11)
- `BloemAdmin/Localizable.xcstrings` — the string catalog for the labels above
