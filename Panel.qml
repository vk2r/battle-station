pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "I18n.js" as I18n
import "panel"

// Detail popup: GPU memory split into "held by LLM runtimes" and "everything
// else", GPU load/temperature/power, system CPU/RAM, then one block per runtime
// with its loaded model(s), context, VRAM, CPU, RAM and connected clients.
Panel {
  id: root
  moduleName: "io.github.vk2r.battle-station"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property var stats: ({})  // pushed by BarWidget on every snapshot
  readonly property var gpu: stats.gpu || ({})
  readonly property var system: stats.system || ({})
  readonly property var runtimes: stats.runtimes || []
  // Every GPU the engine sees, for the settings selector.
  readonly property var gpus: stats.gpus || []
  // Runtimes this machine has: installed, or running even if the install check missed it.
  readonly property var foundRuntimes: runtimes.filter(function(runtime) { return runtime.running || runtime.installed !== false })
  readonly property bool hasRuntimes: foundRuntimes.length > 0
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string font: root.bar ? root.bar.fontFamily : Style.font.family

  function gib(bytes) { return (Number(bytes || 0) / 1073741824).toFixed(1) }
  function pct(value) { return value === null || value === undefined ? "—" : Math.round(value) + "%" }
  function ctx(value) {
    if (!value) return ""
    return t("ctx", [value >= 1024 ? Math.round(value / 1024) + "k" : value])
  }
  // Same green / yellow / orange / red levels as the bar chip.
  function levelColor(fraction) {
    return root.hostWidget && root.hostWidget.levelColor ? root.hostWidget.levelColor(fraction) : Color.accent
  }
  function tokens(value) {
    value = Number(value || 0)
    return value >= 1000 ? (value / 1000).toFixed(value >= 10000 ? 0 : 1) + "k" : String(value)
  }
  function mib(bytes) {
    bytes = Number(bytes || 0)
    return bytes >= 1073741824 ? root.gib(bytes) + " GiB" : Math.round(bytes / 1048576) + " MiB"
  }
  function runtimeState(runtime) {
    if (!runtime.running) return runtime.installed === false ? t("notInstalled") : t("stopped")
    var resident = runtime.models.filter(function(model) { return model.state !== "sleeping" }).length
    if (resident) return tn("modelsLoaded", resident)
    if (runtime.models.length) return t("modelSleeping")
    return t("runningNoModel")
  }
  function stateName(state) {
    var key = { sleeping: "stateSleeping", loading: "stateLoading", unloaded: "stateUnloaded" }[state]
    return key ? t(key) : state
  }

  // Settings page (gear in the header). Back with the button, Backspace or Esc.
  property bool settingsOpen: false
  // The GPU picked in the settings, or the engine's default (the one with the
  // most memory) when nothing is stored or the stored card is gone.
  readonly property string gpuChoice: {
    var setting = hostWidget ? hostWidget.gpuSetting : "auto"
    if (setting !== "auto") {
      for (var i = 0; i < gpus.length; i++) {
        if (gpus[i].id === setting) return setting
      }
    }
    return gpus.length ? gpus[0].id : "auto"
  }
  readonly property string lang: hostWidget ? hostWidget.lang : "en"
  readonly property string languageSetting: hostWidget ? hostWidget.languageSetting : "auto"
  readonly property string systemLang: hostWidget ? hostWidget.systemLang : "en"
  function t(key, args) { return I18n.tr(lang, key, args) }
  function tn(key, n, args) { return I18n.trn(lang, key, n, args) }

  // Which meters the bar shows, as picked in this page's Plugin section; the
  // host widget owns the setting, the page only mirrors and writes it.
  readonly property bool showCpu: root.hostWidget ? root.hostWidget.showCpu : true
  readonly property bool showRam: root.hostWidget ? root.hostWidget.showRam : true
  readonly property bool showLoad: root.hostWidget ? root.hostWidget.showLoad : true
  readonly property bool showModels: root.hostWidget ? root.hostWidget.showModels : true
  function setBarVisible(key, on) { if (root.hostWidget) root.hostWidget.setBarVisible(key, on) }

  function open() { root.controller.show() }
  function close() { root.controller.hide(); root.settingsOpen = false }
  function toggle() { if (root.opened) root.close(); else root.open() }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Both pages share the panel: it is always as tall as Home (hero included),
    // so Settings does not shrink the card. homePage stays laid out while
    // Settings is open (see its opacity comment) or this would measure stale.
    contentHeight: panel.fittedContentHeight(homeHero.implicitHeight + column.spacing + homePage.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: { if (root.settingsOpen) root.settingsOpen = false; else root.close() }
      onTextKey: function(text) { if (text === "\b" && root.settingsOpen) root.settingsOpen = false }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        // On Settings the faded-out Home page still sits below this page in the
        // column; without the clamp it would make the short page scrollable.
        contentHeight: root.settingsOpen ? Math.max(height, settingsPage.implicitHeight) : column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(10)

          PanelHero {
            id: homeHero
            visible: !root.settingsOpen
            foreground: root.fg
            fontFamily: root.font
            title: "BattleStation"
            trailingControl: Component {
              // Kit-default sizing, identical to the settings header's back
              // button; the hero centers it against the title and pill.
              Item {
                implicitWidth: gearButton.width
                implicitHeight: gearButton.height
                Button {
                  id: gearButton
                  iconText: "\udb81\udc93"
                  bordered: false
                  foreground: root.fg
                  fontFamily: root.font
                  tooltipText: root.t("settings")
                  onClicked: root.settingsOpen = true
                }
              }
            }
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\udb85\udcde"
                color: Color.accent
                font.family: root.font
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------------------------------------------------------------- settings
          Settings {
            id: settingsPage
            host: root
            visible: root.settingsOpen
            width: parent.width
          }

          // ---------------------------------------------------------------- main view
          Home {
            id: homePage
            host: root
            // Faded out instead of hidden: a Column stops laying out its
            // children while invisible, which left the panel measuring a stale
            // Home height whenever a model loaded while Settings was open.
            opacity: root.settingsOpen ? 0 : 1
            enabled: !root.settingsOpen
            width: parent.width
          }
        }
      }
    }
  }
}
