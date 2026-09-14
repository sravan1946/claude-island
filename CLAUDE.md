# claude-island

A Hyprland/quickshell bar that shows every live Claude Code session and answers
its permission prompts with a click. `README.md` explains the design; this file
is what you need before changing it.

## Shape

- `island.qml` — the surface (bar, panel, settings). Runs as a user service.
- `state.py --serve` — watches state files, prints a JSON line when something
  *drawn* changes. The surface's only source of session data.
- `approve.sh` — `PermissionRequest` hook: writes `requests/<id>.json`, blocks
  for `decisions/<id>`, returns the verdict.
- `status.sh` — writes `live/<sid>.json` on every state-change hook event.
- State lives in `${XDG_STATE_HOME:-~/.local/state}/claude-approve/`.

## Running it

```
systemctl --user restart claude-island.service   # after editing island.qml
journalctl --user -u claude-island.service -f    # QML errors and warnings land here
./doctor.sh                                      # hooks, service, state, config
```

Hot reload usually picks up an edit, but **not always** — if a change seems to
have no effect, check for `Reloading configuration` in the journal before
concluding anything. Restart rather than assume. A QML warning is a bug: the
journal should be silent in normal use.

## Rules that are not obvious

- **The grant runs on `PermissionRequest`, never `PreToolUse`.** That event
  fires only when Claude Code is about to ask, and matches no tool name. The
  decision is an object — `decision:{behavior:"allow"}` — and a bare string is
  ignored in silence.
- **`approve.sh` must never approve on its own.** Any error, timeout, missing
  daemon or bad payload exits 0 with no output, which leaves the prompt alone.
- **A new `FileView` per write.** Reassigning `path` on a live one retargets it
  asynchronously and drops the `setText` behind it, with no error and no
  `saved()`. One long-lived view wrote the first decision of a session and
  silently lost every one after.
- **Never hand a Repeater a fresh JS array.** It destroys every delegate, and
  the delegates have a memory — lanes rise from zero, colours stop crossfading,
  hover claims leak. `applyFeed()` reconciles a `ListModel` in place; keep it
  that way.
- **Hover claims are held by the area that made them**, released on
  `containsMouse` and on destruction. A counter that only balances when every
  exit arrives is how the panel welded itself open.
- **Evidence has to be new.** The hook decides a prompt was answered elsewhere
  by watching `live/<sid>.json`, and the file already holds the *previous*
  tool's completion. Compare against what it said when the request went up, or
  live prompts get pulled off the panel half a second after they arrive.
  `MessageDisplay` is not a resolution signal — message text keeps rendering
  after the tool call inside it goes out.

## Testing

Never test against live state — a stray decision file can approve a real tool
call, and a fake session shows up on the user's bar. Point the script at its own
root instead:

```
F=/tmp/fakestate; mkdir -p "$F/claude-approve"/{requests,decisions,live}
touch "$F/claude-approve/alive"        # or the hook defers as "island not running"
printf '%s' "$payload" | XDG_STATE_HOME="$F" CA_TIMEOUT=3 ./approve.sh
```

`CA_TIMEOUT` shortens the wait; `approve.log` records every request and what
answered it. When a click seems not to work, instrument the path and look —
`decide()` firing without `saved()` is a different bug from a click that never
arrives, and they are indistinguishable from the symptom.

## Style

Comments say *why*, especially where the obvious approach was tried and failed —
much of this codebase is the record of that. Commit messages are prose: a
sentence subject, then what was wrong and what it cost, in paragraphs. No
trailers, no session links.
