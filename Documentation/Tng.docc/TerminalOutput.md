# Terminal output

When standard output is a terminal, `tng` experimentally renders
human-readable Markdown, tables, and details with ANSI styling and
terminal-width-aware wrapping on macOS and Linux. OSC-8 hyperlinks are
disabled. When output is piped or redirected, `tng` keeps the existing plain
output. Use `--json` when scripts or agents need a stable, structured result.

For terminal-style output, `tng repo view`, `tng issue view`, `tng pr view`, and
`tng pr diff` use the pager configured by `TNG_PAGER` or `PAGER`.
`TNG_PAGER` takes precedence, including when it is set to an empty value. If
neither variable is set, `tng` uses `less` by default. An empty selected value,
`cat`, or `TERM=dumb` disables paging. If the selected pager is unavailable,
`tng` warns and writes output directly.

The following environment variables control paging, terminal detection, width,
and ANSI styling:

| Variable | Behavior |
| --- | --- |
| `TNG_PAGER` | Pager command for supported human-readable output; takes precedence over `PAGER`. |
| `PAGER` | Pager command when `TNG_PAGER` is unset; defaults to `less`. |
| `TNG_FORCE_TTY` | Forces terminal-style output and can specify a width or percentage. |
| `TNG_MDWIDTH` | Limits the width available to width-aware rendering. |
| `NO_COLOR` | Disables ANSI styling when set to a nonempty value. |
| `CLICOLOR` | Disables ANSI styling when set to `0`. |
| `CLICOLOR_FORCE` | Forces ANSI styling when no color-disable setting is active. |

JSON, raw, binary, list, and streaming output is never sent to a pager or
decorated with human-readable styling.
