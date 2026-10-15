pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "I18n.js" as I18n

// Bar indicator for local LLMs: three level meters — CPU, RAM and GPU load —
// plus a small ring, shown while a model is resident, for the GPU memory the
// models hold, in the theme accent. The meter tracks pulse while the GPU is
// generating. Left click opens the detail panel.
Ui.BarWidget {
  id: root
  moduleName: "io.github.vk2r.battle-station"

  readonly property var stats: EngineHub.stats
  // Push every snapshot into the panel; never let it read from an older widget instance.
  onStatsChanged: if (panelLoader.item && "stats" in panelLoader.item) panelLoader.item.stats = root.stats
  readonly property bool busy: stats.busy === true
  readonly property string scriptDir: Qt.resolvedUrl("scripts").toString().replace(/^file:\/\//, "")

  // Level meters on the bar: CPU, RAM and GPU load, from the engine snapshot.
  // Same green / yellow / orange / red levels as the panel's context bars.
  property var levelPalette: ({ green: "#9cba64", yellow: "#d9ab5e", orange: "#e09355", red: "#db6c4f" })
  function levelColor(fraction) {
    return fraction < 0 ? Color.accent
      : fraction >= 0.9 ? levelPalette.red
      : fraction >= 0.75 ? levelPalette.orange
      : fraction >= 0.5 ? levelPalette.yellow
      : levelPalette.green
  }

  // Level meters on the bar: CPU, RAM and GPU load, from the engine snapshot.
  readonly property color ink: root.bar ? root.bar.barForeground : Color.foreground
  // GPU load in the brand colour the engine sends for the followed card; stock when it has none.
  readonly property color gpuTint: (stats.gpu && stats.gpu.color) || ink
  readonly property bool hasGpuLoad: stats.gpu !== undefined && stats.gpu !== null
    && stats.gpu.busy !== undefined && stats.gpu.busy !== null
  readonly property real cpuFraction: stats.system && stats.system.cpu !== undefined
    ? Math.max(0, Math.min(1, stats.system.cpu / 100)) : -1
  readonly property real ramFraction: stats.system && stats.system.mem_total > 0
    ? Math.max(0, Math.min(1, stats.system.mem_used / stats.system.mem_total)) : -1
  readonly property real gpuLoadFraction: hasGpuLoad ? Math.max(0, Math.min(1, stats.gpu.busy / 100)) : -1
  // Share of the followed GPU's memory held by loaded models; -1 without a GPU.
  readonly property real modelsFraction: stats.gpu && stats.gpu.vram_total > 0
    ? Math.max(0, Math.min(1, (stats.llm_vram || 0) / stats.gpu.vram_total)) : -1

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: {
      var found = {}
      var lines = text().split("\n")
      for (var i = 0; i < lines.length; i++) {
        var match = lines[i].match(/^\s*(green|yellow|orange|red)\s*=\s*["']?(#[0-9A-Fa-f]{6})["']?/)
        if (match) found[match[1]] = match[2]
      }
      var merged = {}
      for (var key in root.levelPalette) merged[key] = found[key] || root.levelPalette[key]
      root.levelPalette = merged
    }
  }
  // A theme switch changes the accent; re-read the named colours with it.
  Connections {
    target: Color
    function onAccentChanged() { themeColors.reload() }
  }

  // Interface language: automatic (Hyprland keyboard layout, then the system
  // locale) unless one is picked in the panel's settings (stored in this
  // widget's own shell.json entry).
  readonly property string localeLang: I18n.systemLanguage(Quickshell.env("LC_ALL"), Quickshell.env("LC_MESSAGES"), Quickshell.env("LANG"))
  property string keyboardLang: ""
  readonly property string systemLang: I18n.autoLanguage(keyboardLang, localeLang)
  readonly property string languageSetting: String(root.setting("language", "auto"))
  readonly property string lang: I18n.resolve(languageSetting, systemLang)
  function t(key, args) { return I18n.tr(lang, key, args) }
  function tn(key, n, args) { return I18n.trn(lang, key, n, args) }
  function setLanguage(code) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var next = Object.assign({}, root.settings || {})
    if (code === "auto") delete next.language
    else next.language = code
    root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // Which GPU the panel follows: the card with the most memory ("auto") unless
  // one is picked in the panel's settings; the engine gets it as --gpu.
  readonly property string gpuSetting: String(root.setting("gpu", "auto"))
  function setGpu(id) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var next = Object.assign({}, root.settings || {})
    if (id === "auto") delete next.gpu
    else next.gpu = id
    root.bar.shell.updateEntryInline(root.moduleName, next)
  }


  // Which meters the bar shows, picked in the settings' Plugin section. A
  // hidden meter is stored as false; absent means shown, so the default
  // shell.json entry stays clean. The models ring is always on.
  function barShown(key) {
    var value = root.setting(key, true)
    return value !== false && String(value) !== "false"
  }
  readonly property bool showCpu: root.barShown("showCpu")
  readonly property bool showRam: root.barShown("showRam")
  readonly property bool showLoad: root.barShown("showLoad")
  readonly property bool showModels: root.barShown("showModels")
  function setBarVisible(key, on) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var next = Object.assign({}, root.settings || {})
    if (on) delete next[key]
    else next[key] = false
    root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  readonly property bool loadShown: root.hasGpuLoad && root.showLoad
  readonly property bool ringShown: root.showModels && root.modelsFraction > 0
  readonly property int meterCount: (root.showCpu ? 1 : 0) + (root.showRam ? 1 : 0) + (root.loadShown ? 1 : 0) + (root.ringShown ? 1 : 0)

  // One-line tooltip with the gauges' figures — only the meters the bar
  // shows; the models part only while a model is resident.
  readonly property string summary: {
    var sys = stats.system || {}
    var gpu = stats.gpu || {}
    var parts = []
    if (root.showCpu) parts.push(t("tipCpu", [sys.cpu !== undefined ? Math.round(sys.cpu) : "–"]))
    if (root.showRam) parts.push(t("tipRam", [sys.mem_total > 0 ? Math.round(100 * sys.mem_used / sys.mem_total) : "–"]))
    if (root.showLoad) parts.push(t("tipLoad", [root.hasGpuLoad ? Math.round(gpu.busy) : "–"]))
    if (root.showModels && root.modelsFraction > 0) parts.push(t("tipModels", [Math.round(root.modelsFraction * 100)]))
    return parts.join(" - ")
  }

  // The engine is shared by every bar's widget (see EngineHub.qml); this
  // widget only attaches to it while it exists.
  Component.onCompleted: EngineHub.attach(root)
  Component.onDestruction: EngineHub.detach(root)

  // The active layout of the main keyboard, read once: the language should not
  // flip while someone switches layouts to type.
  Process {
    id: keyboardProbe
    command: ["hyprctl", "-j", "devices"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var keyboards = JSON.parse(text).keyboards || []
          var kb = keyboards.filter(function(k) { return k.main })[0] || keyboards[0]
          if (!kb) return
          var layouts = String(kb.layout || "").split(",")
          var index = Math.max(0, Math.min(layouts.length - 1, Number(kb.active_layout_index) || 0))
          root.keyboardLang = I18n.keyboardLanguage(layouts[index])
        } catch (e) { /* not on Hyprland: the system locale decides */ }
      }
    }
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("stats" in target) target.stats = root.stats
  }

  // Shape contract for shell summon/hide/toggle routing (see omarchy.weather).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    // A per-load query defeats the QML component cache, so a plugin hot reload
    // also picks up a changed Panel.qml instead of an old compiled copy.
    source: Qt.resolvedUrl("Panel.qml") + "?load=" + Date.now()
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  // 0..1 glow while generating; drives the chip colour.
  property real glow: 0
  SequentialAnimation on glow {
    running: root.busy
    loops: Animation.Infinite
    NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
    NumberAnimation { to: 0; duration: 650; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) root.glow = 0
  }

  // Vertical level meter: dim track, bottom fill with a gamma curve — idle
  // machines read in the bottom fifth of the scale, where a 13px track cannot
  // separate 10% from 25%. The fill takes a tint; the stock one is the bar's
  // text colour, as in the panel's gauges.
  component LoadMeter: Item {
    property real fraction: 0
    property color tint: root.ink
    property int settleMs: 240

    readonly property real shown: Math.pow(Math.max(0, Math.min(1, fraction)), 0.6)

    width: Style.space(5)
    height: Style.space(13)

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: root.ink
      // The track breathes with the generation pulse: with no text on the
      // bar, this is what keeps "generating" visible at a glance.
      opacity: 0.18 + (root.busy ? root.glow * 0.27 : 0)
    }

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      // A 2px floor keeps a fully idle meter visible on its track without
      // swallowing the difference between low readings.
      height: Math.max(Style.space(2), parent.height * parent.shown)
      radius: width / 2
      color: parent.tint

      Behavior on height { NumberAnimation { duration: settleMs; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  // Model usage ring: the share of the followed GPU's memory that the loaded
  // models hold, filling clockwise from the top in the theme accent over a
  // dim track.
  component ModelRing: Canvas {
    property real fraction: 0
    readonly property real shown: Math.max(0, Math.min(1, fraction))
    property color tint: Color.accent
    property color ink: root.ink
    readonly property real thickness: Style.space(2)

    width: Style.space(13)
    height: width

    onShownChanged: requestPaint()
    onTintChanged: requestPaint()
    onInkChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
      var c = getContext("2d")
      c.reset()
      var cx = width / 2, cy = height / 2
      var r = Math.min(cx, cy) - thickness / 2
      var top = -Math.PI / 2
      c.lineWidth = thickness
      c.lineCap = "round"
      c.strokeStyle = Qt.rgba(ink.r, ink.g, ink.b, 0.18)
      c.beginPath()
      c.arc(cx, cy, r, 0, 2 * Math.PI)
      c.stroke()
      if (shown > 0) {
        c.strokeStyle = tint
        c.beginPath()
        c.arc(cx, cy, r, top, top + shown * 2 * Math.PI)
        c.stroke()
      }
    }
  }

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.opened ? "" : root.summary
    fixedWidth: button.vertical ? -1 : metersBlock.implicitWidth + Style.space(14)
    fixedHeight: button.vertical ? metersBlock.implicitHeight + Style.space(14) : -1
    onPressed: function(code) {
      if (code === Qt.LeftButton) root.toggle()
      else if (code === Qt.RightButton && root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
    }

    // Four gauges and no text: CPU, RAM, GPU load and the models ring.
    Grid {
      id: metersBlock
      anchors.centerIn: parent
      // Columns follow the shown meters: a Grid sized for four would reserve
      // room for a hidden one and push the rest off-centre.
      columns: button.vertical ? 1 : Math.max(1, root.meterCount)
      columnSpacing: Style.space(5)
      rowSpacing: Style.space(5)

      LoadMeter { fraction: root.cpuFraction; settleMs: 180; visible: root.showCpu }
      LoadMeter { fraction: root.ramFraction; settleMs: 320; visible: root.showRam }
      LoadMeter { fraction: root.gpuLoadFraction; settleMs: 240; visible: root.loadShown; tint: root.gpuTint }
      ModelRing { fraction: root.modelsFraction; visible: root.ringShown }
    }
  }
}
