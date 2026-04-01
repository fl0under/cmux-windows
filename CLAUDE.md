# cmux-windows Development Guide

## Overview

cmux-windows is a native Windows port of [cmux](https://github.com/manaflow-ai/cmux) — a
Ghostty-based terminal with vertical tabs and notifications for AI coding agents. Built on
[ghostty-windows](https://github.com/InsipidPoint/ghostty-windows) as the terminal backend,
using Win32 + Direct2D for the UI shell and WebView2 for the embedded browser.

## Commands

- **Build:** `zig build -Dapp-runtime=win32`
- **Release build:** `zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast`
- **Test (Zig):** `zig build test`
- **Test filter:** `zig build test -Dtest-filter=<test name>`
- **Formatting:** `zig fmt .`

## Directory Structure

- Ghostty core (upstream): `src/` (terminal emulation, rendering, PTY, config)
- Win32 apprt (from ghostty-windows): `src/apprt/win32/`
- **cmux UI shell (NEW):** `src/cmux/ui/` — Sidebar, SplitContainer, NotificationRing, Theme
- **Workspace management (NEW):** `src/cmux/workspace/` — Workspace state, manager, session restore
- **Notification system (NEW):** `src/cmux/notifications/` — OSC parsing, store, Windows toast
- **Embedded browser (NEW):** `src/cmux/browser/` — WebView2 host, scriptable API
- **IPC (NEW):** `src/cmux/ipc/` — Named pipe server/client, JSON-RPC protocol
- **Git integration (NEW):** `src/cmux/git/` — Git status, port scanning, shell detection
- **CLI tool (NEW):** `cli/` — cmux.exe CLI entry point
- **Shell integration (NEW):** `shell-integration/` — PowerShell, bash/zsh, fish scripts
- **Windows resources:** `resources/` — App manifest, icon, resource file

## Architecture

All cmux-specific code lives under `src/cmux/` to maintain clean separation from the
upstream ghostty codebase. The integration points are:

1. **Window.zig** — Modified to host the sidebar HWND alongside the content area
2. **App.zig** — Extended with cmux-specific actions and IPC server initialization
3. **Surface.zig** — Notification hooks into terminal output stream

### Shell Support

All shells (PowerShell, CMD, WSL, Git Bash) run through the same libghostty → ConPTY pipeline.
WSL is not special — ConPTY bridges the Win32 pseudo-console to the Linux PTY inside WSL.

### Key Conventions

- Single statically-linked .exe is the target (no .NET, no XAML, no Node.js)
- Direct2D for all custom UI rendering (sidebar, notifications, status)
- WebView2 for embedded browser (pre-installed on Windows 10/11)
- Named Pipes for IPC (`\\.\pipe\cmux`)
- JSON-RPC protocol for CLI ↔ app communication

### Port Progress Tracking

- Keep `docs/cmux-windows-port-progress.md` up to date whenever you make meaningful port progress.
- Update it in the same change set as the code whenever feasible.
- Add new completed slices with commit hashes, refresh remaining gaps, and keep environment/build blockers current.
