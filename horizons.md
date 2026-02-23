# Configurable Horizons

Subproject of [PROJECT.md](PROJECT.md). Date-based time horizons (Overdue, Today, Tomorrow, etc.) are fully configurable: users define custom labels, boundaries, and ordering via `setup()`.

## Config API

```lua
require("taskbuffer").setup({
    horizons = {
        { label = "# Overdue",      after = "past" },
        { label = "# Today",        after = 0 },
        { label = "# Tomorrow",     after = 1 },
        { label = "# This Week",    after = 2 },
        { label = "# End of Month", after = "end_of_month" },
        { label = "# This Month",   after = "30d" },
        { label = "# This Year",    after = "1y" },
        { label = "# Someday",      undated = true },
    },
    horizons_overlap = "sorted",   -- "sorted" | "first_match" | "narrowest"
    week_start = "monday",         -- affects end_of_week keyword
})
```

Omitting `horizons` (or setting it to `nil`) uses built-in defaults matching the original behavior.

## `after` Field Reference

| Type | Examples | Resolution |
|------|----------|------------|
| Integer | `0`, `1`, `2`, `-7` | Day offset from today |
| Duration string | `"2d"`, `"1w"`, `"1m"`, `"1y"`, `"-1w"` | Fixed days: d=1, w=7, m=30, y=365 |
| Calendar keyword | `"past"`, `"yesterday"`, `"end_of_week"`, `"end_of_month"`, `"end_of_quarter"`, `"end_of_year"` | Dynamic based on current date |

Calendar keywords resolve to start-of-next-period (exclusive upper boundary):
- `"past"` → today − 100 years
- `"yesterday"` → today − 1 day
- `"end_of_week"` → day after last day of week (respects `week_start`)
- `"end_of_month"` → first day of next month
- `"end_of_quarter"` → first day of next quarter
- `"end_of_year"` → Jan 1 of next year

## Undated Horizon

Use `{ label = "# Someday", undated = true }` to define where undated tasks render. The label is configurable. If no undated horizon is defined, undated tasks use the default "# Someday" label.

## Overlap Strategies

- **`"sorted"`** (default): Resolve all cutoffs to dates, sort ascending. Tasks bucketed between adjacent cutoffs. No overlap possible.
- **`"first_match"`**: Evaluate horizons in user-defined list order. First matching range wins.
- **`"narrowest"`**: Task goes into the horizon with the tightest date range containing it.

## Error Handling

Invalid horizon specs produce a warning on stderr and fall back to defaults. An empty `horizons = {}` also triggers defaults.

## Implementation

| File | Role |
|------|------|
| `go/horizon.go` | Types (`HorizonSpec`, `ResolvedHorizon`), parsing, resolution |
| `go/horizon_test.go` | Unit tests for all resolution logic |
| `go/format.go` | Uses `ResolvedHorizon` instead of hardcoded `dateBucket` |
| `go/main.go` | Threads `Config.Horizons` through to `FormatOpts` |
| `lua/taskbuffer/init.lua` | Exposes `horizons`, `horizons_overlap`, `week_start` in config |
