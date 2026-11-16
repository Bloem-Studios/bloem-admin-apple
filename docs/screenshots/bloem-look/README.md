# Bloem look

Every image is an iPhone screenshot of a page from the app's own `--ui-testing-*` fixtures (an in-process fake
server). Nothing here is a real server or real data. Each page is shown in dark and light, named
`<page>-iphone-<dark|light>.png`; `after/` is the app's current look.
They are half size and palette-reduced to keep the repository small.

To make them again, create `/tmp/bloem-look-shots/phase` on the Mac running the simulator (its content is the
folder name, such as `after`) and run `BloemAdminUITests/LookTourUITests` as part of a normal
`xcodebuild test` run on a Mac. The tour is skipped when that file is missing, and writes to `/tmp/bloem-look-shots/<phase>/`.

| Page | Fixture |
| --- | --- |
| `shell-*`, `manage-servers`, `add-server`, `server-page-unreachable` | `--ui-testing-reset`, `--ui-testing-seed-servers` |
| `app-settings*`, `lock-screen` | `--ui-testing-notifications=undetermined`, `--ui-testing-auth=unavailable` |
| `settings-list*` | `--ui-testing-settings` |
| `dashboard-*` | `--ui-testing-dashboard-fixture` |
| `now-playing-rows*` | `--ui-testing-stream-rows` |
| `requests*`, `users`, `user-*`, `api-keys` | `--ui-testing-user-page` (`--ui-testing-people-shell`, `--ui-testing-user-support`, `--ui-testing-requests-unavailable`) |
| `history*`, `logs`, `audit` | `--ui-testing-incident-pages` |
| `automation-*` | `--ui-testing-automation=<tasks|nodes|backups|plugins>` |
| `libraries*` | `--ui-testing-libraries` |
| `organization-*`, `platform-organizations*` | `--ui-testing-organization[=suspended]`, `--ui-testing-platform-organizations` |
