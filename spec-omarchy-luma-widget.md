# Spec: Luma widget for Omarchy Quattro

- Proposed plugin id: `studiotwin.luma`
- Kind: `bar-widget` (Quickshell)
- License: MIT
- Status: draft 0.2 (checked against the develop and publish guides on omarchyplugins.com)

## 1. Summary

The widget shows all your future Luma events in the Omarchy bar: the events that you will attend and the events that you host. The widget shows one merged list. When the API key is present, each hosted event also shows its guest count and its capacity. No plugin in the marketplace shows Luma data. All Omarchy meetups use Luma.

## 2. Goals

- Show attended and hosted events in one list.
- Show the next event and the days until it starts.
- Open each event page with one click.
- Show the guest count and the capacity for each hosted event.

## 3. Non-goals for version 0.1

- The widget does not create or edit events.
- The widget does not check in guests.
- The widget does not show past events.

## 4. Data sources

The widget merges two sources into one event list.

### 4.1 Event list: the personal iCal feed (version 0.1)

The base source is your personal Luma iCal feed. Luma gives each user a subscription URL for their schedule. The widget downloads the feed with `curl` and parses the `VEVENT` entries. This source does not use the Luma API and does not need Luma Plus.

Confirm that the feed contains the events that you host. If it does not, merge the event list from the calendar API into the feed list.

> Confirmed on 2026-08-25 against a live personal feed: the feed contains hosted events. Also observed: no `URL` property (the event link is in `DESCRIPTION`), `STATUS:TENTATIVE` on all events, dates in UTC, and `ORGANIZER` always `calendar-invite@lu.ma` (the feed cannot identify the host).

To connect the feed:

1. Open Luma and go to your calendar settings.
2. Find the calendar subscription section.
3. Copy the subscription URL.
4. Write the URL to the secrets file (see section 9).

### 4.2 Host data: the calendar API (version 0.2)

The second source is the Luma public API at `https://public-api.luma.com`. Each request must send the API key in the `x-luma-api-key` header. Luma issues one API key for each calendar. The API needs an active Luma Plus subscription on that calendar. Confirm this cost before you start version 0.2.

When the secrets file contains an API key, the widget identifies your hosted events. The widget matches API events to feed entries with the event URL. Each matched event gets the guest count and the capacity. When the secrets file contains no API key, the widget shows all events without host data.

The API limit is approximately 200 requests each minute for each calendar. The widget stays far below this limit.

Use the calendar endpoints that list events and guests. Confirm the exact paths at `docs.luma.com/reference` before implementation.

**Caution: The Luma API key gives full read and write access to the calendar. Put the key in the secrets file only.**

## 5. Plugin structure

The manifest entry point is `BarWidget.qml`. This file shows the bar item and loads `Panel.qml` with a `Loader`. `BarWidget.qml` must forward the panel lifecycle to the loaded panel: `opened`, `open()`, `close()`, `toggle()`, and `closeForPopoutSwitch()`. Both files must use the same `moduleName`. The panel sets `manageIpc: false`. Do not declare a second `panel` kind for this nested panel.

**Caution: The plugin runs inside the shell process, with your user permissions. The shell process runs continuously and is not sandboxed. Do not start a second Quickshell process. Run `curl` in an asynchronous process, so the shell does not block.**

## 6. Bar widget

- The bar shows a calendar glyph and the days until the next event, for example `12d`.
- If the next event is today, the bar shows the start time.
- If the next event is a hosted event, the bar also shows the guest count, for example `12d · 23/35`.
- A badge appears when a new guest registers for a hosted event after the last poll.
- A left click opens the panel. A right click or a middle click starts a refresh.

## 7. Panel

- The panel lists all future events in one list, in date order.
- Each row shows the date, the start time, the event name, and the city.
- Each hosted event shows a `Host` marker and `guests / capacity`, for example `23 / 35`.
- A click on a row opens the event page in the browser.
- The up and down arrow keys move through the rows. `Enter` opens the event. `Escape` closes the panel. `R` starts a refresh.

## 8. Refresh

- The default poll interval for the feed is 30 minutes.
- The default poll interval for guest counts is 10 minutes.
- Events do not change often. Do not poll more than necessary.

## 9. Configuration

Manifest schema options:

| Key | Type | Default |
| --- | --- | --- |
| `secretsFilePath` | string | `~/.config/omarchy/luma.env` |
| `refreshIntervalSec` | integer | `1800` (min `300`) |
| `maxEvents` | integer | `10` |

There is no mode option. The presence of `LUMA_API_KEY` in the secrets file turns on host data.

The official Basecamp plugin shows integer schema options with `min`, `max`, and `step`. Confirm the string and boolean option types in the shell reference: `github.com/basecamp/omarchy/blob/quattro/shell/plugins/README.md`.

The secrets file uses this format:

```
LUMA_ICS_URL=https://...
LUMA_API_KEY=...
```

The secrets file must have `600` permissions. The plugin must refuse a secrets file with wider permissions and must show a hint.

## 10. Security and privacy

- The plugin must not write event data, URLs, or keys to disk.
- The plugin must not write the feed URL or the API key to a log.
- The feed URL contains a secret token. Treat the full URL as a secret.
- Demo mode must use fictional data only.
- The README must list each external dependency and each setup step.

## 11. States and errors

- Secrets file absent: the panel shows a short setup hint. The plugin makes no network request.
- Feed empty: the panel shows `No events`.
- Network error: the widget keeps the last data and shows the time of the last good poll.
- API key absent: the widget shows all events, without host data.
- API response 401: the panel shows `Invalid API key`.
- API response 429: the widget waits, doubles the wait time, and tries again.

## 12. Development workflow

1. Clone the built-in clock: `omarchy plugin clone omarchy.clock --edit`. The clock is the closest built-in: a bar widget with a details panel.
2. Develop in the folder that the command creates under `~/.config/omarchy/plugins/`. Saved changes reload automatically.
3. Validate the folder: `omarchy plugin validate "$PLUGIN_DIR"`.
4. Lint the QML files: `qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml`.
5. Test the panel routes: `omarchy-shell shell summon <id> '{}'` and `omarchy-shell shell hide <id>`.
6. Test a click, `Escape`, disable, enable, a shell restart, and removal.
7. Before publication, set the permanent id and remove the `omarchy.clonedFrom` field.

Constraints from the validator:

- The id must be namespaced and unique. The `omarchy.*` namespace is forbidden.
- The plugin folder must not contain symlinks.
- Each entry point must be a safe relative path to a file that exists.

## 13. Demo mode and screenshots

Supply a demo script that runs the widget against local fixture data. The demo must not read the secrets file and must not contact the network. Supply a screenshot script for the marketplace preview. Follow the pattern of the official Basecamp plugin (`demo/run` and `demo/run --screenshot`).

## 14. Publication

1. Put the code in a public GitHub repository. `manifest.json` must be in the repository root.
2. Include a README with these sections: Install, Usage, Configure, Remove.
3. Include a LICENSE file. An optional `preview.png` can sit in the root. The marketplace optimizes it automatically.
4. Validate the last commit locally with `omarchy plugin validate`.
5. Submit the repository link, a category, and tags through the issue form: `github.com/HANCORE-linux/omarchy-plugin-marketplace` (template `submit-plugin.yml`).
6. Automated validation checks the current commit. A maintainer approves the listing.

Note: The marketplace validates the listing, not the plugin security. The author remains responsible for the code.

## 15. Milestones

1. Version 0.1: the full event list from the feed, bar and panel, demo mode.
2. Version 0.2: host data with guest counts and the registration badge. Complete this before 28 September 2026.
3. Version 1.0: marketplace listing.

## 16. Acceptance criteria for version 0.1

1. `omarchy plugin validate` and `qmllint` complete with no errors.
2. The bar shows the next event within one poll interval after setup.
3. The panel lists at most `maxEvents` future events in date order.
4. A click on a row opens the correct event page.
5. `omarchy-shell shell summon` opens the panel. `omarchy-shell shell hide` closes it. The panel opens again after each close.
6. The plugin operates correctly after disable, enable, and a shell restart.
7. The plugin makes no network request when the secrets file is absent.
8. Demo mode runs with no secrets and no network.

Acceptance criteria for version 0.2:

1. A hosted event shows the `Host` marker, the guest count, and the capacity.
2. The bar shows the guest count when the next event is a hosted event.
3. The badge appears within one poll interval after a new registration.
4. Without an API key, the widget operates as version 0.1.

## 17. Manifest sketch

```json
{
  "schemaVersion": 1,
  "id": "studiotwin.luma",
  "name": "Luma",
  "version": "0.1.0",
  "author": "Studio Twin",
  "license": "MIT",
  "description": "Your Luma events in the bar: countdown, event list, and guest counts for hosts.",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "Luma",
    "description": "Countdown to your next Luma event, with guest counts for hosts.",
    "category": "Productivity",
    "aliases": ["luma", "events", "meetup"],
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": {
      "secretsFilePath": "~/.config/omarchy/luma.env",
      "refreshIntervalSec": 1800,
      "maxEvents": 10
    }
  }
}
```

These manifest fields are required: `schemaVersion`, `id`, `name`, `version` (maximum 64 characters), `author`, `description`, `kinds`, and `entryPoints`.

## 18. Repository layout and installation

```
manifest.json      (repository root, required)
BarWidget.qml      (entry point)
Panel.qml          (loaded by BarWidget.qml)
Model.js           (optional data logic)
lib/               (fetch and parse scripts)
demo/              (fixtures, run script, screenshot script)
tests/
README.md          (Install, Usage, Configure, Remove)
LICENSE
preview.png        (optional marketplace preview)
```

Install command:

```bash
omarchy plugin add <repo-url> --enable
```
