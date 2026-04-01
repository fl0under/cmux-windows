# cmux-windows port progress

This file tracks the current state of the cmux-to-Windows port so future agent
passes can resume quickly and keep the summary up to date.

## Last updated

- Date: 2026-04-01
- Branch: `cursor/cmux-sidebar-features-a87b`

## Upstream reference

- Upstream cmux clone is available at `/workspace/.vendor/cmux-upstream`
- Current inspected upstream revision: `92d4fa68`

## Completed slices

### 1. cmux control plane wired into live Win32 runtime

Implemented and committed in:

- `be72a50f1` - `feat(win32): wire cmux control plane into runtime`

What landed:

- Added `src/apprt/win32/CmuxController.zig`
- Started a cmux named-pipe server from the live Win32 app
- Reworked `src/cmux/ipc/Server.zig` so requests marshal onto the main UI thread
- Mapped core cmux RPCs onto the existing Ghostty Windows tab/split runtime:
  - `new-workspace`
  - `close-workspace`
  - `switch-workspace`
  - `rename-workspace`
  - `split`
  - `close-pane`
  - `send-keys`
  - `notify`
  - `open-url`
  - `list`
  - `focus`
  - `move-focus`
  - `status`
- Installed a Windows `cmux` CLI executable from `cli/main.zig`

Current behavior:

- The live Win32 runtime can now act as a cmux-like control target
- Workspace RPCs are currently mapped onto the existing Ghostty Windows tab model
- Pane RPCs are currently mapped onto the existing Ghostty Windows split model

### 2. First visible cmux sidebar shell hosted in the Win32 window

Implemented and committed in:

- `f4cd6db49` - `feat(win32): host cmux sidebar in window shell`

What landed:

- `src/apprt/win32/Window.zig` now creates and hosts `src/cmux/ui/Sidebar.zig`
- The terminal content area shifts right to make room for the sidebar
- The old top tab bar is suppressed when the sidebar is active
- Workspace selection and new-workspace clicks route into the live tab model
- Sidebar GDI fallback now draws workspace names instead of only blocks
- Basic sidebar rename/reorder plumbing exists

Current behavior:

- The runtime has a left-hand workspace sidebar shell
- Sidebar entries mirror the current tab/workspace list at a basic level
- The existing Ghostty tab/split runtime still powers the actual terminal model underneath

### 3. Sidebar metadata and native sidebar interactions

Implemented and committed in progress on this branch:

- `ba6008c60` - `feat(win32): surface sidebar metadata in workspace chrome`

What landed after that slice:

- Added persistent port tracking in `docs/cmux-windows-port-progress.md`
- Added repo guidance in `CLAUDE.md` to keep the progress file current
- Wired live Win32 `pwd` actions into sidebar workspace metadata
- Wired desktop notifications into sidebar unread/snippet state
- Sidebar now renders:
  - workspace title
  - latest notification snippet
  - cwd fallback when no notification snippet exists
  - unread badge
- Sidebar now emits native interaction messages for:
  - workspace click
  - new workspace
  - double-click rename
  - right-click context actions
- Window shell now handles sidebar-driven:
  - rename
  - close workspace
  - context menu actions

Current behavior:

- Sidebar is now the main visible workspace chrome for selection and basic management
- Live title/cwd/notification changes are reflected into sidebar entries
- Some advanced interactions still route through the legacy tab model under the hood

### 3. Sidebar state and maintenance tracking tightened

Implemented in the current working tree after:

- `f4cd6db49` - `feat(win32): host cmux sidebar in window shell`

What landed in this follow-up slice:

- Added this progress file at `docs/cmux-windows-port-progress.md`
- Added a repo instruction in `CLAUDE.md` to keep this file updated on future port progress
- Added a lightweight per-tab sidebar metadata mirror in `src/apprt/win32/Window.zig`
- Sidebar title changes now stay synchronized with runtime tab title changes
- Sidebar entries now show a secondary line using the latest notification text when available
- Added a first live hook point for routing runtime notifications into the sidebar model

Current behavior:

- The sidebar is no longer just a structural shell; it now carries persistent per-workspace UI state
- Workspace titles and basic notification snippets can flow into the sidebar model
- The sidebar remains a partial cmux port rather than a full metadata-complete implementation

### 4. Sidebar interaction path promoted toward primary workspace chrome

Implemented and committed in:

- `b8ad8077f` - `feat(win32): promote sidebar workspace interactions`

What landed in this slice:

- Fixed `src/apprt/win32/Window.zig` tab moves so `sidebar_tabs` metadata now reorders with the live tab model
- Added native drag-reorder handling inside `src/cmux/ui/Sidebar.zig`
- Wired sidebar context-menu messages back into `Window.zig` so right-click actions are handled from the sidebar path
- Expanded GDI sidebar rendering to show existing per-workspace metadata when available:
  - git branch
  - PR number
  - listening ports
- Added active-workspace accenting and sidebar/content separator polish in the interim GDI renderer

Current behavior:

- Sidebar reorder now updates both workspace position and mirrored sidebar metadata together
- Right-click and drag interactions can flow through the sidebar itself instead of relying on top-tab assumptions
- Sidebar now exposes more of the metadata already present in the workspace model, though live git/port discovery is still incomplete

### 5. Sidebar rename path and git metadata wiring tightened

Implemented and committed in:

- `4fcd4fbbd` - `feat(win32): tighten sidebar rename and git metadata`

What landed in this slice:

- Updated `src/apprt/win32/Window.zig` inline rename flow to use sidebar-relative geometry when the sidebar is the active workspace chrome
- Switched rename commit handling to route through the existing tab-title update path so sidebar state stays synchronized
- Added lightweight git/PR metadata refresh from live `pwd` updates using `src/cmux/git/GitStatus.zig`
- Kept the legacy top-tab rename path intact for non-sidebar cases while making the sidebar path the primary visible one

Current behavior:

- Double-click rename from the sidebar now targets the visible sidebar workspace entry instead of hidden top-tab rectangles
- Sidebar title updates continue to flow through the shared title-sync path used by the runtime
- Sidebar git branch and PR number can now refresh from cwd changes for native git workspaces, though ports and shell-type detection are still incomplete

### 6. Sidebar shell metadata surfaced in live workspace chrome

Implemented and committed in:

- `45edaab65` - `feat(win32): surface sidebar shell metadata`

What landed in this slice:

- Updated `src/apprt/win32/Window.zig` to infer sidebar shell type from the configured launch command when new workspaces are created
- Expanded `src/cmux/ui/Sidebar.zig` metadata rendering to show shell labels alongside git branch / PR / ports when available
- Kept shell metadata wiring lightweight and local to the sidebar model without disturbing the underlying terminal launch path

Current behavior:

- New sidebar workspaces now expose shell-type metadata such as PowerShell, CMD, or Git Bash in the visible workspace chrome
- Existing sidebar git/PR metadata remains visible and is now grouped with shell metadata in a single rendered line
- Shell metadata still reflects configured launch intent rather than per-workspace runtime detection, so WSL/native divergence is still incomplete

### 7. Sidebar runtime detection promoted beyond config inference

Implemented and committed in:

- `8f1b472a0` - `feat(win32): wire sidebar runtime metadata`

What landed in this slice:

- Updated `src/apprt/win32/Window.zig` to derive sidebar shell type from each live surface's exec argv instead of only from global config
- Switched sidebar git / PR refresh to use WSL-aware command routing when the live workspace shell resolves to WSL
- Added a first real Windows TCP listener scan in `src/cmux/git/PortScanner.zig`
- Wired sidebar port metadata refresh to the live workspace process handle and sidebar state refresh path
- Refreshed runtime sidebar metadata on workspace creation, cwd updates, and tab selection so the visible chrome stays closer to live process state

Current behavior:

- Sidebar shell labels now reflect the live workspace launch argv rather than only configured launch intent
- Sidebar git branch / PR refresh now follows WSL command routing when the workspace shell is detected as WSL
- Sidebar can now surface a first live set of interesting listening ports tied to the active workspace process on Windows

### 8. Sidebar port attribution extended to child process trees

Implemented and committed in:

- `48b930b9d` - `feat(win32): follow child process ports in sidebar`

What landed in this slice:

- Extended `src/cmux/git/PortScanner.zig` to snapshot the Windows process table and collect descendant PIDs for a workspace root process
- Updated sidebar port refresh to attribute interesting listening ports across the workspace shell's child process tree instead of only the direct shell PID
- Added an explicit Win32 `GetProcessId` declaration in `src/apprt/win32/win32.zig` so workspace process handles can be resolved cleanly for sidebar metadata

Current behavior:

- Sidebar ports now better track dev servers launched under the workspace shell rather than only ports owned by the shell process itself
- Port attribution is still limited to Windows process-tree visibility and interesting TCP listeners; broader protocol/state attribution is still pending

### 9. Sidebar polish and legacy-tab dependency reduced further

Implemented and committed in:

- `ed5379374` - `feat(win32): polish sidebar chrome`

What landed in this slice:

- Refined `src/cmux/ui/Sidebar.zig` GDI rendering with tighter text columns, active outlines, viewport clipping, and a more visible new-workspace affordance
- Updated `src/apprt/win32/Window.zig` invalidation so sidebar mode repaints the sidebar child directly instead of routing through hidden top-tab assumptions
- Reduced live message-loop dependence on legacy tab-bar hover state when the sidebar is active

Current behavior:

- Sidebar mode now behaves more like the primary workspace chrome and less like a mirror layered on top of a hidden tab bar
- The interim GDI sidebar is still not full Direct2D/DirectWrite quality, but it is visually closer to a finished workspace chrome

## Verified environment notes

### Local tools added during port work

- Installed local Zig toolchain at `/workspace/.tools/zig`

### Current build blocker in this Linux environment

Attempted:

- `"/workspace/.tools/zig/zig" build -Dapp-runtime=win32 -Dtarget=x86_64-windows -Doptimize=Debug`

Blocked by environment/toolchain gaps, not yet by a fully isolated cmux code error:

- Missing Windows/MSVC SDK and cross C/C++ stdlib headers for existing Windows-target dependencies
- Observed missing headers include:
  - `windows.h`
  - `cstring`
  - `vector`
  - `algorithm`
  - `string`
  - `stdlib.h`

Affected existing dependencies include:

- `simdutf`
- `highway`
- `glslang`

This means full Windows-target compile verification still requires a richer cloud
image or cross-compilation environment.

## Known remaining gaps to full cmux parity

### Sidebar / workspace UI

- Sidebar is still GDI fallback, not full Direct2D/DirectWrite quality
- Sidebar metadata rendering now has slots for shell type, git branch, PR number, and ports; runtime population is improved but still incomplete overall
- Legacy top-tab assumptions still exist in parts of `Window.zig`
- Sidebar-driven rename, reorder, and context menus now exist, but some focus/selection/layout paths still assume the legacy top tab bar

### Notifications

- Notification store is wired into the control plane
- Full notification ring and notification panel integration is still pending
- Desktop notifications still use the existing Win32 notification path
- Sidebar notification state has an initial plumbing path, but it is not yet complete for all runtime notification sources

### Browser

- WebView2 host is still scaffold-level
- Browser automation API is still placeholder-heavy

### Session restore

- Session restore exists as scaffold under `src/cmux/workspace/`
- Not yet integrated into the live Win32 runtime

### Shell / metadata / integration

- Sidebar shell metadata now uses live exec argv classification for active workspaces, but deeper runtime/process-tree detection is still incomplete
- Sidebar port metadata now has a first live Windows listener scan, but only for directly owned process handles rather than full descendant trees
- WSL-aware sidebar git metadata refresh now exists, but it still depends on cwd updates and does not yet cover every runtime/source path
- Shell integration scripts exist but are not yet fully connected end-to-end to sidebar state

### Remote / SSH / teams workflows

- Upstream cmux remote/SSH workflows are not ported
- Claude Code Teams-style orchestration is not ported

## Immediate next recommended work

1. Finish sidebar state synchronization so it is the canonical workspace chrome
2. Populate sidebar metadata from real runtime state:
   - title
   - cwd
   - notifications
   - git branch
   - ports
3. Clean up remaining top-tab event paths in `Window.zig`
4. Integrate notification ring/panel into the live window/surface runtime
5. Bring up the browser host as a real split leaf

## Maintenance rule for future agent passes

When making progress on the port:

- update this file in the same change set
- add newly completed slices with commit hashes
- refresh the “Known remaining gaps” section
- keep the environment/build blocker notes current
