# HEY Calendar for Omarchy

Omarchy's stock clock and calendar, exactly as it ships, with your
[HEY](https://hey.com) calendar laid over it.

- **Chips under every day.** One chip per calendar color, with the number of
  that day's events in it. A day with a Work meeting and a dinner shows a
  blue `1` and a red `1`. More than three colors collapse into `+N`. Hover a
  day for its events.
- **Click a day to see it.** The day view under the grid draws the day the
  way HEY does: all-day pills, then a pastel block per event with its time,
  calendar and location. The event under way is ringed and marked `NOW`.
  Clicking an event opens its meeting link, or the event in HEY.
- **New events.** `+`, `N`, or double-clicking a day opens a quick form:
  title, day, calendar, all-day or a time range, place, reminder. Days and
  times are typed loosely: `fri`, `tomorrow`, `next mon`, `3 oct` for the
  day, `9`, `930`, `9:30pm`, `21.30` for times. An end before the start
  means the next morning.
- **Quick add from anywhere.** **Alt+Shift+Space** opens the same form as a
  card in the middle of the screen, like OmaTasks' quick add. The shortcut
  is bound in Hyprland by the plugin, never over one that is already taken,
  and released when the plugin unloads.
- **Delete** a one-off event from its hover button (with a confirmation).
  Repeating events are left to HEY, since deleting by id takes the series.
- **Notifications.** The reminders you set in HEY arrive as desktop
  notifications. Clicking one opens the meeting link or the event.
- **Time tracking.** Start and stop HEY's time tracker from today's view.
  Finished tracks show on their day under **Tracked**, with the day's
  total. Stopping one opens its name field right away; any track can be
  renamed by clicking it (HEY names a track by its category, created if
  new) or deleted from its hover button.
- **Live sync.** A `hey watch` stream refreshes the panel within seconds of
  a change made anywhere else, with polling as the fallback.
- **In the bar**, like a macOS menu-bar calendar: an event's name and when
  sit in front of the stock clock (`󰃭 Omarchy Podcast · in 12m`, then
  `· until 14:30`) from its **earliest HEY reminder** until it ends. A day
  ahead if you asked for a day's notice, 30 minutes if 30. Without
  reminders it uses `alertLeadMinutes`; all-day events only show when they
  have a reminder. When several overlap, the bar names one and counts the
  rest (`+2`), and hovering lists them all. What it names first: something
  starting within `alertLeadMinutes`, then what is under way (ending
  soonest first), then what is coming, then all-day events.
- **Today in HEY's orange**, in the grid as well as the day view, and a
  **Today** button (or `T`) back to it whenever you have moved away.

## Requirements

- Omarchy 4 with the Quattro shell plugin system
- **hey-cli 1.3.0 or newer**, signed in (`hey setup`). 1.3.0 is the version
  Omarchy installs, so a stock system works as is.
- `jq` (part of Omarchy)

### hey-cli versions

| hey-cli | How weeks are read | Notes |
| --- | --- | --- |
| 1.4.0 and newer | `hey event week`, HEY's own expansion | Exact. Calendars switched off in HEY are left out. |
| 1.3.x (Omarchy's package) | `hey event list`, expanded by the plugin | HEY's repeat presets (daily, weekdays, weekly, every other week, monthly, yearly, with "until" or a count) are expanded locally. A single occurrence edited or deleted in HEY is not visible. Every calendar is included; hide ones you switched off with `hiddenCalendars`. |
| older, or missing | nothing | The panel says so instead of showing empty days. |

The version is read once, from `hey --version`, when the shell starts.

## Install

```bash
omarchy plugin add https://github.com/crmne/omarchy-hey.git --enable
omarchy plugin disable omarchy.clock
```

Point the bar's center anchor at it, so the center section stays put when
hover-only widgets appear:

```jsonc
// ~/.config/omarchy/shell.json
{ "bar": { "centerAnchor": "crmne.hey-calendar" } }
```

## Keys

### New-event form (panel and quick add)

The form never needs the mouse. A hint line under it says what the keys do
where the focus is.

| Key | Does |
| --- | --- |
| `Tab` / `Shift+Tab` | Next / previous field, the calendar and reminder rows included |
| `←` `→` | On the calendar row: switch calendar. On the reminder row: switch reminder. On all day: toggle |
| `↑` `↓` | In a time: 15 minutes earlier or later. In the day: a day (`Shift`: a week) |
| `Alt+←` `Alt+→` | Switch calendar, from any field |
| `Alt+↑` `Alt+↓` | Switch reminder, from any field |
| `Alt+A` | Toggle all day, from any field |
| `Enter` | Add the event |
| `Esc` | Cancel |

### Calendar panel

The stock ones all work: arrows, `[` `]` months, `{` `}` years, `T` today,
`W` week start. Added:

| Key | Does |
| --- | --- |
| `,` `.` | Previous / next day |
| `<` `>` | Previous / next week |
| `N` | New event on the selected day |
| `S` | Settings |
| `O` | Open the selected day in HEY |
| `R` | Refresh from HEY |

## Settings

The gear button in the panel (or `S`) opens the settings, right under the
calendar. Omarchy does not draw settings screens for plugin widgets yet, so
they live there. Tab walks them, arrows pick, Enter applies, Esc goes back.
Each change is saved to the widget's entry in `~/.config/omarchy/shell.json`
at once, so it can be edited there too.

| Key | Default | Meaning |
| --- | --- | --- |
| `barEvent` | `soon` | `soon`: name an event in the bar from its earliest reminder until it ends. `name`: the same, but only the title. `time`: the same, but only when (`in 12m`). `next`: always name today's next event. `off`: the glyph only. |
| `notifications` | `true` | Show HEY reminders as notifications. |
| `quickAddShortcut` | `ALT + SHIFT + SPACE` | Opens the quick-add card. Empty turns it off. |
| `alertLeadMinutes` | `15` | How early the bar names an event that has no reminders, and what counts as "about to start". |
| `timeFormat` | `auto` | `auto`, `12` or `24`. |
| `liveSync` | `true` | Keep a `hey watch` running for instant updates. |
| `refreshIntervalSec` | `300` | Polling fallback, 30 to 3600. |
| `hiddenCalendars` | `""` | Comma-separated calendar names to leave out. |

The panel also stores `weekStartDay`, `birthYear`, `lifeExpectancy` (stock)
and `lastCalendarId` (the calendar the last new event went on).

## Not yet

HEY's day titles, photos and "Sometime this week" are not exposed by
hey-cli, so they are not here yet. Day titles are in HEY's API
(`Calendar::DayTitle`), and are the first candidate for a hey-cli addition.

## Develop

```bash
tests/run                  # Hey.js, in five timezones
omarchy plugin validate .
```

Plugin code under `~/.config/omarchy/plugins` hot-reloads on save, but not
through a symlink: when developing from a linked checkout, load changes with
`omarchy-restart-shell`. `omarchy-shell shell toggle crmne.hey-calendar`
opens the quick-add card; `omarchy-shell crmne.hey-calendar open` the panel,
and `omarchy-shell crmne.hey-calendar settings` the panel's settings.

`Model.js` is Omarchy's and stays stock; `Hey.js` holds the HEY data, date
math and command lines and runs under plain node.
