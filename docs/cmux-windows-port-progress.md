# cmux-windows port progress

This file tracks the current state of the cmux-to-Windows port so future agent
passes can resume quickly and keep the summary up to date.

## Last updated

- Date: 2026-04-01
- Branch: `cursor/cmux-windows-feature-parity-a423`

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
- Sidebar metadata is still minimal; it does not yet fully show:
  - git branch
  - PR status/number
  - ports
- Legacy top-tab assumptions still exist in parts of `Window.zig`
- Sidebar-driven rename, reorder, and context menus still need to become the primary path
- Sidebar drag reorder is still not fully native through the sidebar itself

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

- WSL/native shell detection and git/port metadata are not yet live in the sidebar
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
