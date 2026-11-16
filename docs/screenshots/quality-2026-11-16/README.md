# Quality audit, 2026-11-16: the app after the fixes

Screens of the iOS app after the quality audit, over the
fixture data only: nothing here is a real server, store or customer.

Every screen is shown in dark and light, in several settings:

| Name part | Setting |
| --- | --- |
| `phone` | iPhone, upright, default text size |
| `phone-ax` | iPhone, upright, Accessibility 3 text size (a very large one) |
| `phone-land` | iPhone held sideways (the Dynamic Island on the left), default text size |
| `phone-land-ax` | iPhone held sideways, Accessibility 3 |
| `ipad`, `ipad-land`, `ipad-ax` | iPad upright, sideways, and upright at Accessibility 3 |

Files are named `<screen>-<setting>-<dark|light>.png`. A name ending in `-full` is a window taller than the screen, so a
scrolling page is in one image; `-failed` is the screen when the server does not answer as expected. The images are two fifths of
full size and palette-reduced to keep the repository small.

**What is here:** the shell pages on an iPhone (first launch, menu, server context menu, Manage servers, Add server with the keyboard up, All servers with an unreachable and a signed-out server). The other pages and the iPad are what `scripts/quality-shots.sh` makes; they were not run for the final code.

## Making them again

`scripts/quality-shots.sh` runs `BloemAdminUITests/QualityTourUITests` (a real launch of each fixture page, rotated and at
the system's large text size) through the shared Mac test script and copies the PNGs back:

    scripts/quality-shots.sh after /some/folder
    IOS_IPAD=1 scripts/quality-shots.sh after /some/folder

Every page comes from a `--ui-testing-*` fixture (see `LookTourUITests`); no server is contacted.
