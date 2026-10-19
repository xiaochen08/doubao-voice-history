# Doubao voice history companion

This is a standalone companion app. It does not modify the Doubao IME UI.

- Detects the Doubao voice bar (`OimeVoiceWaveWindow`) appearing/disappearing.
- Snapshots the focused control text with UI Automation when voice starts.
- Reads it again after the session ends and diffs out the inserted text.
- Shows a floating card above the voice bar: click the text or 复制 to copy.
- Keeps the last 500 sessions in `%APPDATA%\DoubaoVoiceHistory\history.json`.
- Tray icon: 历史记录 / 退出.

Run:

    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\VoiceHistory.ps1

Test UI without speaking:

    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\VoiceHistory.ps1 -Test

Autostart:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Autostart.ps1

UI:

- Frosted glass: captures the screen region behind the window, blurs it, then overlays an ink-glass tint, a hairline border and a top highlight.
- Overlay: serif transcript, gold accent, fade/scale/rise entrance, 22-second progress line, click-to-copy.
- History: borderless draggable glass window, live search, keyboard navigation (Up/Down, Enter, Delete, Esc), single-entry delete, clear confirmation, autostart toggle and data-folder shortcut.

Limitations:

- Text capture depends on UI Automation. Chrome/Edge/Electron and classic edit controls work; custom-drawn or game windows may not expose text.
- If the app does not expose text, the floating card shows a "not captured" notice.
- The history is local to this Windows account.
