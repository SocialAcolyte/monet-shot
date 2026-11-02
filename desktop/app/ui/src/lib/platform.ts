// Small per-OS differences in wording and layout.
const ua = navigator.userAgent;
export const isMac = /Mac OS X|Macintosh/.test(ua);
export const isWindows = /Windows/.test(ua);
export const isLinux = !isMac && !isWindows;

/** Where "Show in …" points. */
export const fileManager = isMac ? "Finder" : isWindows ? "Explorer" : "Files";
/** The Trash has a different name on Windows. */
export const trashName = isWindows ? "Recycle Bin" : "Trash";
/** Where the ring lives. */
export const ringHome = isMac ? "menu bar" : isWindows ? "taskbar tray" : "tray";
/** macOS draws the title bar over the page; elsewhere it's above it. */
export const titleBarInset = isMac ? 46 : 22;
