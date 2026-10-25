# The oracle's fixtures

Each pair is one checkpoint of phase 5's gate, recorded on 25/10/2026:

- `<name>.raw` — the bytes a real program wrote to a pty, captured with
  `tmux pipe-pane`. This is what the far end would send us.
- `<name>.txt` — how **tmux 3.5a** drew those bytes, from `capture-pane -p`,
  in a pane of exactly 100 columns by 30 rows.

`MoshOracleTests` replays the bytes into SwiftTerm at the same size and compares
the two renderings line by line. Two emulators disagreeing about the same bytes
is a defect in one of them; two agreeing is the only evidence worth having here.
tmux is one mature emulator and not the truth, so agreement means we are not
alone in a misreading — which is the most a comparison can give.

A text comparison **cannot see an attribute**: a cell in the wrong colour holds
the right character and the diff shrugs. That is why `colours` is also asserted
cell by cell against what the recording was built to produce.

Recorded with `TERM=xterm-256color`, an empty environment, `PS1='# '` and a
private tmux server, so nothing of the machine it ran on is in here. The recipe
is in BUILD-MAC.md; the shell script that made them is not committed, because
re-recording them is a deliberate act and not a build step.
