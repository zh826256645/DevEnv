# Keep DevEnv Resident in the Status Bar After Window Close

DevEnv remains a regular Dock application while its main window is open and switches to status-bar residency when the last main window closes. The status bar exposes global session counts, active session names only, global start/stop actions, and a path to reopen the window; status-bar quit, `⌘Q`, and the application menu quit all perform complete application exit and clean active Project Run Sessions. Counts classify sessions as running (including lifecycle transitions), stopped (including user-initiated non-zero exits), or exceptional (including failed stops/restarts, launch failures, and non-user-initiated non-zero exits). This preserves a full dashboard when needed while making window close a non-destructive hide action.

## Considered Options

- Make DevEnv a status-bar-only app: rejected because the primary experience is a full project dashboard.
- Let window close terminate the app: rejected because active Project Run Sessions must survive temporary UI dismissal.
