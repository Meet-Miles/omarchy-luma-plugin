# Luma for Omarchy

A bar widget for the Omarchy Quattro shell. The widget shows all your future [Luma](https://luma.com) events in the bar: the events that you attend and the events that you host.

- The bar shows a calendar glyph and the days until the next event, for example `󰃭 12d`.
- If the next event is today, the bar shows the start time.
- If the next event is an event that you host, the bar also shows the guest count, for example `󰃭 12d · 23/35`.
- A badge appears when a new guest registers for one of your events.
- The panel lists all future events with the date, the time, the name, and the city.
- A click on a row opens the event page in the browser.

## Install

The plugin needs these programs. Omarchy includes all of them:

- `curl` (feed and API downloads)
- `bash` and GNU coreutils (`stat`, `grep`, `cut`)
- `grim` (only for demo screenshots)

Install the plugin with the Omarchy plugin manager:

```bash
omarchy plugin add https://github.com/Meet-Miles/omarchy-luma-plugin --enable
```

Then connect your Luma feed:

1. Open [luma.com](https://luma.com) and go to your profile **Settings**.
2. Find the **Calendar Syncing** row (under Account Syncing).
3. Click **Add iCal Subscription** and copy the link (right-click a calendar-app option and select "Copy link address"). A `webcal://` link is also good; the plugin converts it.
4. Create the secrets file and make it private:

```bash
install -m 600 /dev/null ~/.config/omarchy/luma.env
```

5. Write the URL to the secrets file:

```
LUMA_ICS_URL=https://api.lu.ma/ics/get?entity=calendar&id=...
```

**Caution: The subscription URL contains a secret token. Do not share the URL and do not put it in a log or a repository.** The plugin refuses a secrets file with permissions wider than `600` and shows a hint in the panel.

The widget shows the next event within one refresh interval. Right-click the widget for an immediate refresh.

### Optional: guest counts for hosts

The guest count and the capacity for your hosted events come from the Luma public API. The API needs an API key and an active Luma Plus subscription on your calendar. Luma issues one API key for each calendar.

Add the key to the secrets file:

```
LUMA_API_KEY=...
```

**Caution: The API key gives full read and write access to the calendar. Keep the key in the secrets file only.** Without a key, the widget shows all events without host data.

## Usage

| Input | Action |
| --- | --- |
| Left click | Open or close the panel |
| Right click or middle click | Refresh |
| `↑` / `↓` | Move through the rows |
| `Enter` | Open the selected event page |
| `R` | Refresh |
| `Escape` | Close the panel |

Shell commands:

```bash
omarchy-shell shell summon studiotwin.luma '{}'
```

```bash
omarchy-shell shell hide studiotwin.luma
```

The panel shows `HOST` and `guests / capacity` on each event that you host. The footer shows the time of the last good refresh. When the network is not available, the widget keeps the last data.

## Configure

Set the options in the bar layout entry for `studiotwin.luma`:

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `secretsFilePath` | string | `~/.config/omarchy/luma.env` | Path of the secrets file |
| `refreshIntervalSec` | integer | `1800` | Feed refresh interval in seconds (minimum `300`) |
| `maxEvents` | integer | `10` | Maximum number of rows in the panel |

There is no mode option. When the secrets file contains `LUMA_API_KEY`, the widget shows host data. Guest counts refresh every 10 minutes.

## Demo

The demo runs the widget against fictional local data. The demo does not read the secrets file and does not contact the network.

```bash
demo/run
```

```bash
demo/run --screenshot --output ~/Pictures/luma-preview.png
```

## Tests

The data layer has a test suite that runs with Node:

```bash
node --test tests/model.test.js
```

## Remove

```bash
omarchy plugin remove studiotwin.luma
```

Then delete the secrets file:

```bash
rm ~/.config/omarchy/luma.env
```

The plugin writes no other files. Event data stays in memory only.

## Privacy and security

- The plugin does not write event data, URLs, or keys to disk.
- The plugin does not write the feed URL or the API key to a log.
- The `lib/` scripts read the secrets file directly. The URL and the key never appear in process arguments or in the shell process.
- Demo mode uses fictional data only.

## Development status

The plugin was written and unit-tested on a Mac. The QML follows the contracts of the built-in
`omarchy.clock` and `omarchy.weather` plugins (branch `quattro`), but it did not run against
the real shell yet.

The fetch script and the parser were validated against a live personal feed on 2026-08-25:

- The personal feed contains the events that you host (spec section 4.1 is confirmed).
- Real feeds have no `URL` property. The parser takes the event page link from `DESCRIPTION`.
- Real feeds mark events `STATUS:TENTATIVE`. The parser drops only `CANCELLED`.
- Dates come as UTC (`...Z`). The parser converts them to local time.
- The `ORGANIZER` email is always `calendar-invite@lu.ma`, so the feed cannot identify the
  host reliably. The `HOST` marker stays an API-key feature.

Continue on an Omarchy machine with these steps:

1. Clone this repository into the plugin folder and enable it:

```bash
git clone https://github.com/Meet-Miles/omarchy-luma-plugin ~/.config/omarchy/plugins/studiotwin.luma
```

```bash
omarchy plugin enable studiotwin.luma
```

2. Validate the folder:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/studiotwin.luma
```

3. Lint the QML files:

```bash
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
```

4. Run the data-layer tests: `node --test tests/model.test.js` (31 tests, all pass on 2026-08-25).
5. Test the panel routes: `omarchy-shell shell summon studiotwin.luma '{}'` and `omarchy-shell shell hide studiotwin.luma`.
6. Test a click, `Escape`, disable, enable, a shell restart, and removal.
7. Run `demo/run` and `demo/run --screenshot`.

Open items to verify on the Omarchy machine:

- `demo/run` calls `omarchy-shell ipc call studiotwin.luma refresh`. Confirm this IPC syntax. The fallback is the right-click refresh in the bar.
- The `Style`, `Color`, `WidgetButton`, `KeyboardPanel`, `PanelKeyCatcher`, and `OpticalGlyph` calls come from the built-in plugins. Confirm them with `qmllint`.
- Before the marketplace submission: make the repository public, validate the last commit, and submit through the issue form at `github.com/HANCORE-linux/omarchy-plugin-marketplace` (template `submit-plugin.yml`).

The full specification is in [spec-omarchy-luma-widget.md](spec-omarchy-luma-widget.md).

## License

MIT. See [LICENSE](LICENSE).
