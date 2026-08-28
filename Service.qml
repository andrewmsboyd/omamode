import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Backend for the light/dark plugin: owns the current mode (mirrored from
// GNOME's color-scheme gsetting), the configured per-mode default themes,
// the daily schedule, and the manual-override bookkeeping. The bar widget
// is purely a view over this — everything here keeps running whether or
// not the popup is open, so external gsettings changes and the schedule
// are both handled even when nobody's looking at the bar.
Item {
  id: root

  // Injected by omarchy-shell, same convention as the first-party services.
  property var shell: null

  // ---- Config, pushed in by BarWidget.qml from the shell.json entry ----
  property string lightTheme: ""
  property string darkTheme: ""
  property bool scheduleEnabled: false
  property string scheduleLightTime: "07:00"
  property string scheduleDarkTime: "19:00"

  // ---- State ----
  property string mode: "light"          // "light" | "dark"
  property bool stateLoaded: false
  property bool overrideActive: false
  property double overrideSetAt: 0       // epoch ms, only meaningful while overrideActive

  // The gsettings scheme value ("prefer-dark"/"prefer-light") from the most
  // recent write *we* issued. Lets the gsettings monitor tell our own writes
  // apart from a genuinely external change (e.g. GNOME Settings, another
  // script) without needing a debounce timer.
  property string lastAppliedScheme: ""

  property bool hasPendingApply: false
  property var pendingApply: null

  readonly property string statusText: {
    if (!stateLoaded) return "Loading…"
    var modeLabel = mode === "dark" ? "Dark" : "Light"
    if (!scheduleEnabled) return modeLabel + " · schedule off"
    if (overrideActive) {
      var lightM = Model.parseTimeToMinutes(scheduleLightTime)
      var darkM = Model.parseTimeToMinutes(scheduleDarkTime)
      if (lightM === null || darkM === null) return modeLabel + " · manual override"
      var next = Model.nextBoundaryTimestampAfter(overrideSetAt, lightM, darkM)
      return modeLabel + " · manual until " + Model.formatTimestampHHMM(next)
    }
    return modeLabel + " · following schedule"
  }

  function updateConfig(cfg) {
    if (cfg.lightTheme !== undefined) lightTheme = cfg.lightTheme
    if (cfg.darkTheme !== undefined) darkTheme = cfg.darkTheme
    if (cfg.scheduleEnabled !== undefined) scheduleEnabled = cfg.scheduleEnabled
    if (cfg.scheduleLightTime !== undefined) scheduleLightTime = cfg.scheduleLightTime
    if (cfg.scheduleDarkTime !== undefined) scheduleDarkTime = cfg.scheduleDarkTime
    evaluateSchedule()
  }

  // Manual entry point: bar buttons and the IPC handler. Engages the
  // schedule override (if a schedule is active) so the next automatic tick
  // doesn't immediately fight the user's choice.
  function setMode(target) {
    if (target !== "light" && target !== "dark") return
    applyMode(target, { manual: true })
  }

  function applyMode(target, opts) {
    opts = opts || {}
    root.mode = target
    root.stateLoaded = true
    if (opts.manual && scheduleEnabled) {
      overrideActive = true
      overrideSetAt = Date.now()
    }
    runApply(target, !!opts.skipGsettings)
  }

  function runApply(target, skipGsettings) {
    var scheme = target === "dark" ? "prefer-dark" : "prefer-light"
    var theme = target === "dark" ? darkTheme : lightTheme
    var parts = []

    if (!skipGsettings) {
      root.lastAppliedScheme = scheme
      parts.push("gsettings set org.gnome.desktop.interface color-scheme " + scheme)
    }
    if (theme && theme.length > 0) {
      parts.push("omarchy theme set " + shellQuote(theme))
    }
    if (parts.length === 0) return

    if (applyProcess.running) {
      root.pendingApply = { mode: target, skipGsettings: skipGsettings }
      root.hasPendingApply = true
      return
    }

    applyProcess.command = ["bash", "-lc", parts.join(" && ")]
    applyProcess.running = true
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function refresh() {
    if (!colorSchemeProbe.running) colorSchemeProbe.running = true
  }

  // Re-checks the schedule against the wall clock. Called on the periodic
  // timer, and also right after any config change so toggling the schedule
  // on or editing a time reacts immediately instead of waiting up to 60s.
  // Because this always asks "what should the mode be *right now*" rather
  // than tracking elapsed time, a missed transition (machine asleep through
  // a boundary) is simply caught up on the next tick after wake.
  function evaluateSchedule() {
    if (!scheduleEnabled) return

    var lightM = Model.parseTimeToMinutes(scheduleLightTime)
    var darkM = Model.parseTimeToMinutes(scheduleDarkTime)
    if (lightM === null || darkM === null) return

    if (overrideActive) {
      var nextBoundary = Model.nextBoundaryTimestampAfter(overrideSetAt, lightM, darkM)
      if (Date.now() >= nextBoundary) {
        overrideActive = false
      } else {
        return
      }
    }

    var now = new Date()
    var nowMinutes = now.getHours() * 60 + now.getMinutes()
    var expected = Model.expectedModeForMinutes(nowMinutes, lightM, darkM)
    if (expected !== root.mode) applyMode(expected, { manual: false })
  }

  Timer {
    id: scheduleTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.evaluateSchedule()
  }

  Process {
    id: colorSchemeProbe
    command: ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.mode = Model.modeFromColorSchemeValue(text)
        root.stateLoaded = true
      }
    }
  }

  // Long-running: reports every future change to color-scheme, whoever
  // makes it (this service, GNOME Settings, another script). Restarted if
  // it ever exits (dbus hiccup, etc).
  Process {
    id: colorSchemeMonitor
    command: ["gsettings", "monitor", "org.gnome.desktop.interface", "color-scheme"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        var raw = Model.parseMonitorLine(line)
        if (!raw) return
        if (raw === root.lastAppliedScheme) return // echo of our own write

        root.lastAppliedScheme = raw
        var externalMode = Model.modeFromColorSchemeValue(raw)
        root.applyMode(externalMode, { manual: true, skipGsettings: true })
      }
    }
    onExited: monitorRestart.restart()
  }

  Timer {
    id: monitorRestart
    interval: 2000
    onTriggered: if (!colorSchemeMonitor.running) colorSchemeMonitor.running = true
  }

  Process {
    id: applyProcess
    onExited: function() {
      if (root.hasPendingApply) {
        var pending = root.pendingApply
        root.hasPendingApply = false
        root.pendingApply = null
        root.runApply(pending.mode, pending.skipGsettings)
      }
    }
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "omamode"

    function status(): string {
      return JSON.stringify({
        mode: root.mode,
        scheduleEnabled: root.scheduleEnabled,
        overrideActive: root.overrideActive
      })
    }

    function light(): string { root.setMode("light"); return "light" }
    function dark(): string { root.setMode("dark"); return "dark" }

    function toggle(): string {
      var next = root.mode === "dark" ? "light" : "dark"
      root.setMode(next)
      return next
    }

    function refresh(): void { root.refresh() }
  }
}
