import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.andrewmsboyd.omamode"

  readonly property var service: bar?.shell?.firstPartyServiceFor(moduleName)
  property var themeOptions: []
  property bool popupOpen: false

  function close() { popupOpen = false }

  // ---- Settings <-> Service wiring ----
  // shell.json is the single source of truth for config; the service just
  // gets pushed a copy whenever it changes so it can run the schedule and
  // react to external gsettings changes independent of whether the popup
  // (or even the bar on this monitor) is open.
  function pushConfigToService() {
    if (!root.service) return
    root.service.updateConfig({
      lightTheme: root.setting("lightTheme", "Flexoki Light"),
      darkTheme: root.setting("darkTheme", "Nord"),
      scheduleEnabled: root.setting("scheduleEnabled", false) === true,
      scheduleLightTime: root.setting("scheduleLightTime", "07:00"),
      scheduleDarkTime: root.setting("scheduleDarkTime", "19:00")
    })
  }

  function updateSetting(patch) {
    var next = Object.assign({}, root.settings, patch)
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function updateScheduleTime(which, hour, minute) {
    var key = which === "light" ? "scheduleLightTime" : "scheduleDarkTime"
    var fallback = which === "light" ? "07:00" : "19:00"
    var current = Model.parseTimeToMinutes(root.setting(key, fallback))
    if (current === null) current = Model.parseTimeToMinutes(fallback)
    var h = hour !== null ? hour : Math.floor(current / 60)
    var m = minute !== null ? minute : current % 60
    var patch = {}
    patch[key] = Model.formatMinutes(h * 60 + m)
    root.updateSetting(patch)
  }

  function refreshThemeList() {
    if (!themeListProcess.running) themeListProcess.running = true
  }

  onServiceChanged: pushConfigToService()
  onSettingsChanged: pushConfigToService()
  Component.onCompleted: {
    pushConfigToService()
    refreshThemeList()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: themeListProcess
    command: ["omarchy", "theme", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.themeOptions = Model.parseThemeList(text)
    }
  }

  // Two hand-drawn twins rather than runtime recoloring (mirrors the agents
  // plugin's assets/<id>-light.svg convention): dimmer-switch.svg is drawn
  // light-on-transparent for a dark bar, dimmer-switch-light.svg is drawn
  // dark-on-transparent for a light bar. Luminance of the bar's own
  // background decides which one actually reads against it.
  Component {
    id: iconComponent

    Item {
      id: iconRoot
      readonly property var candidates: Model.iconCandidates(
        Qt.resolvedUrl("assets/dimmer-switch.svg"),
        root.bar ? root.bar.background : Color.background)
      property string candidatesKey: candidates.join("\n")
      property int candidateIndex: 0
      onCandidatesKeyChanged: candidateIndex = 0

      Image {
        id: img
        anchors.fill: parent
        source: iconRoot.candidateIndex < iconRoot.candidates.length ? iconRoot.candidates[iconRoot.candidateIndex] : ""
        sourceSize.width: Math.round(width * Screen.devicePixelRatio)
        sourceSize.height: Math.round(height * Screen.devicePixelRatio)
        fillMode: Image.PreserveAspectFit
        smooth: true
        // Advancing source from inside its own status change trips the
        // binding-loop detector; defer the step one tick (same guard the
        // agents plugin uses for its icon fallback walk).
        onStatusChanged: if (status === Image.Error && iconRoot.candidateIndex < iconRoot.candidates.length)
          Qt.callLater(function() { iconRoot.candidateIndex++ })
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: iconComponent
    tooltipText: root.service ? root.service.statusText : ""
    onPressed: function() { root.popupOpen = !root.popupOpen }
  }

  // PopupCard is a fixed-size popup window: it only grows to fit
  // column.implicitHeight, which doesn't account for a child Dropdown's own
  // floating list popup (Popups don't participate in layout flow, so
  // opening one never grows its parent's implicitHeight). With the Dark
  // theme row sitting near the bottom of the column, its popup had nowhere
  // to expand into and got clipped a couple of rows in. Mirror Dropdown's
  // own popup-height cap formula here and, while either theme dropdown is
  // open, size the card tall enough to fit that dropdown's full popup below
  // it — the same live-resize path the schedule-time toggle already uses
  // when it reveals extra rows.
  readonly property int themeDropdownPopupCap: Math.min(
    root.themeOptions.length * Style.spacing.popupRowHeight + Math.max(0, root.themeOptions.length - 1) * Style.spacing.labelGap + Style.spacing.xxs,
    Style.spacing.popupRowHeight * 8 + 7 * Style.spacing.labelGap + Style.spacing.xxs)

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: Style.space(300)
    contentHeight: popup.fittedContentHeight(Math.max(
      column.implicitHeight,
      lightDropdown.popupOpen ? lightDropdown.y + lightDropdown.height + root.themeDropdownPopupCap + Style.spacing.xxs : 0,
      darkDropdown.popupOpen ? darkDropdown.y + darkDropdown.height + root.themeDropdownPopupCap + Style.spacing.xxs : 0))

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      Text {
        width: parent.width
        text: root.service ? root.service.statusText : "Loading…"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Light"
          bordered: true
          active: !!(root.service && root.service.mode === "light")
          foreground: root.bar.foreground
          onClicked: if (root.service) root.service.setMode("light")
        }

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Dark"
          bordered: true
          active: !!(root.service && root.service.mode === "dark")
          foreground: root.bar.foreground
          onClicked: if (root.service) root.service.setMode("dark")
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      PanelSectionHeader {
        text: "DEFAULT THEMES"
        foreground: root.bar.foreground
      }

      Dropdown {
        id: lightDropdown
        width: parent.width
        label: "Light theme"
        options: root.themeOptions
        value: root.setting("lightTheme", "Flexoki Light")
        foreground: root.bar.foreground
        onChanged: function(v) { root.updateSetting({ lightTheme: v }) }
      }

      Dropdown {
        id: darkDropdown
        width: parent.width
        label: "Dark theme"
        options: root.themeOptions
        value: root.setting("darkTheme", "Nord")
        foreground: root.bar.foreground
        onChanged: function(v) { root.updateSetting({ darkTheme: v }) }
      }

      PanelSeparator { foreground: root.bar.foreground }

      Row {
        width: parent.width

        Text {
          width: parent.width - toggle.width
          anchors.verticalCenter: parent.verticalCenter
          text: "Automatic schedule"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        ToggleSwitch {
          id: toggle
          checked: root.setting("scheduleEnabled", false) === true
          foreground: root.bar.foreground
          onToggled: root.updateSetting({ scheduleEnabled: !checked })
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.setting("scheduleEnabled", false) === true

        Text {
          text: "Switch to light at"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          spacing: Style.space(8)
          NumberField {
            label: "Hour"
            from: 0; to: 23
            value: {
              var m = Model.parseTimeToMinutes(root.setting("scheduleLightTime", "07:00"))
              return m === null ? 7 : Math.floor(m / 60)
            }
            foreground: root.bar.foreground
            onModified: function(v) { root.updateScheduleTime("light", v, null) }
          }
          NumberField {
            label: "Minute"
            from: 0; to: 59
            value: {
              var m = Model.parseTimeToMinutes(root.setting("scheduleLightTime", "07:00"))
              return m === null ? 0 : m % 60
            }
            foreground: root.bar.foreground
            onModified: function(v) { root.updateScheduleTime("light", null, v) }
          }
        }

        Text {
          text: "Switch to dark at"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          spacing: Style.space(8)
          NumberField {
            label: "Hour"
            from: 0; to: 23
            value: {
              var m = Model.parseTimeToMinutes(root.setting("scheduleDarkTime", "19:00"))
              return m === null ? 19 : Math.floor(m / 60)
            }
            foreground: root.bar.foreground
            onModified: function(v) { root.updateScheduleTime("dark", v, null) }
          }
          NumberField {
            label: "Minute"
            from: 0; to: 59
            value: {
              var m = Model.parseTimeToMinutes(root.setting("scheduleDarkTime", "19:00"))
              return m === null ? 0 : m % 60
            }
            foreground: root.bar.foreground
            onModified: function(v) { root.updateScheduleTime("dark", null, v) }
          }
        }
      }
    }
  }
}
