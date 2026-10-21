pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
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

      // Plugin version, read from the bundled manifest.json for the
      // Settings footer.
      FileView {
        id: manifestFile
        path: Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, "")
        printErrors: false
        onLoaded: {
          try { versionFooter.text = JSON.parse(manifestFile.text()).version || "" } catch (e) { versionFooter.text = "" }
        }
      }

      // Settings footer: the version, pinned under the scrolling area so it
      // stays on the panel's bottom edge however long the page grows.
      Text {
        id: versionFooter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.settingsOpen && text !== ""
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.font
        font.pixelSize: Style.font.caption
      }

      Flickable {
        id: scroller
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: versionFooter.visible ? versionFooter.top : parent.bottom
        anchors.bottomMargin: versionFooter.visible ? Style.space(10) : 0
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
              // llama-suite's header reticle (assets/icons/reticle.svg), drawn
              // as shapes on its 24-unit grid so it takes the theme accent.
              Item {
                implicitWidth: Style.font.display
                implicitHeight: Style.font.display

                Shape {
                  width: 24
                  height: 24
                  scale: parent.width / 24
                  transformOrigin: Item.TopLeft
                  preferredRendererType: Shape.CurveRenderer

                  ShapePath {
                    strokeColor: Color.accent
                    strokeWidth: 2
                    fillColor: "transparent"
                    capStyle: ShapePath.SquareCap
                    joinStyle: ShapePath.MiterJoin
                    PathSvg { path: "M2 7 V2 H7 M17 2 H22 V7 M22 17 V22 H17 M7 22 H2 V17" }
                  }
                  ShapePath {
                    strokeColor: Color.accent
                    strokeWidth: 1.75
                    fillColor: "transparent"
                    capStyle: ShapePath.SquareCap
                    PathSvg { path: "M16.17 7.68 A6 6 0 0 1 16.17 16.32 M13.65 17.77 A6 6 0 0 1 6.18 13.45 M6.18 10.55 A6 6 0 0 1 13.65 6.23" }
                  }
                  ShapePath {
                    strokeColor: "transparent"
                    fillColor: Color.accent
                    PathSvg { path: "M11 11 H13 V13 H11 Z" }
                  }
                }
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
