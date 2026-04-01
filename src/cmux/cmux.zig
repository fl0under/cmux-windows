//! cmux-windows: Native Windows port of cmux — the Ghostty-based terminal
//! with vertical tabs and notifications for AI coding agents.
//!
//! This is the root module for all cmux-specific functionality layered on
//! top of the ghostty-windows terminal backend.

// UI shell
pub const ui = struct {
    pub const Sidebar = @import("ui/Sidebar.zig").Sidebar;
    pub const SidebarTab = @import("ui/SidebarTab.zig");
    pub const SplitContainer = @import("ui/SplitContainer.zig").SplitContainer;
    pub const NotificationRing = @import("ui/NotificationRing.zig").NotificationRing;
    pub const NotificationPanel = @import("ui/NotificationPanel.zig").NotificationPanel;
    pub const StatusBar = @import("ui/StatusBar.zig").StatusBar;
    pub const Theme = @import("ui/Theme.zig").Theme;
    pub const Color = @import("ui/Theme.zig").Color;
};

// Workspace management
pub const workspace = struct {
    pub const Workspace = @import("workspace/Workspace.zig").Workspace;
    pub const WorkspaceManager = @import("workspace/WorkspaceManager.zig").WorkspaceManager;
    pub const SessionRestore = @import("workspace/SessionRestore.zig").SessionRestore;
};

// Notification system
pub const notifications = struct {
    pub const OscParser = @import("notifications/OscParser.zig").OscParser;
    pub const NotificationStore = @import("notifications/NotificationStore.zig").NotificationStore;
    pub const ToastBridge = @import("notifications/ToastBridge.zig").ToastBridge;
};

// IPC (Named Pipes)
pub const ipc = struct {
    pub const Server = @import("ipc/Server.zig").Server;
    pub const Client = @import("ipc/Client.zig").Client;
    pub const Protocol = @import("ipc/Protocol.zig").Protocol;
    pub const Commands = @import("ipc/Commands.zig");
};

// Embedded browser
pub const browser = struct {
    pub const WebView = @import("browser/WebView.zig").WebView;
    pub const BrowserApi = @import("browser/BrowserApi.zig").BrowserApi;
    pub const DevTools = @import("browser/DevTools.zig").DevTools;
};

// Git + environment integration
pub const git = struct {
    pub const GitStatus = @import("git/GitStatus.zig").GitStatus;
    pub const PortScanner = @import("git/PortScanner.zig").PortScanner;
    pub const ShellDetect = @import("git/ShellDetect.zig").ShellDetect;
};

// Re-export key types at the top level for convenience
pub const Sidebar = ui.Sidebar;
pub const WorkspaceManager = workspace.WorkspaceManager;
pub const NotificationStore = notifications.NotificationStore;
pub const OscParser = notifications.OscParser;
pub const IpcServer = ipc.Server;
