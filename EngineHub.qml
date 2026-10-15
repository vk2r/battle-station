pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The one engine behind every bar widget. Quickshell builds a bar per monitor
// and each bar builds its own BarWidget, so a collector inside the widget
// would start one engine per monitor, all printing the same snapshot. Widgets
// attach here instead; the engine runs while at least one is attached.
Scope {
  id: hub

  // Latest snapshot, shared by every widget.
  property var stats: ({})
  property var consumers: []

  // Every widget reads the same shell.json entry, so the first one speaks for all.
  readonly property string gpuSetting: consumers.length > 0 ? String(consumers[0].gpuSetting) : "auto"
  readonly property string engine: Qt.resolvedUrl("bin/engine").toString().replace(/^file:\/\//, "")

  function attach(widget) {
    if (consumers.indexOf(widget) < 0) consumers = consumers.concat([widget])
  }
  function detach(widget) {
    consumers = consumers.filter(function(known) { return known !== widget })
  }

  // The engine never starts a runtime; it only reads /proc, the GPU (all-smi)
  // and the runtimes' local APIs, and streams a JSON snapshot every two seconds.
  Process {
    id: collector
    // --gpu points every number in the snapshot at the picked card.
    command: hub.gpuSetting !== "" && hub.gpuSetting !== "auto"
      ? [hub.engine, "--gpu", hub.gpuSetting] : [hub.engine]
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var data = JSON.parse(line)
          if (!data.error) hub.stats = data
        } catch (e) { /* partial line during shutdown */ }
      }
    }
    onExited: {
      if (hub.consumers.length === 0) return
      // A stop we asked for (new GPU, last widget gone) comes back at once;
      // a crash waits five seconds.
      if (hub.stopped) quickRestart.start(); else restart.start()
    }
  }

  property bool stopped: false
  onConsumersChanged: {
    if (consumers.length === 0) {
      if (collector.running) { stopped = true; collector.running = false }
    } else if (!collector.running && !restart.running && !quickRestart.running) {
      quickRestart.start()
    }
  }
  onGpuSettingChanged: {
    if (consumers.length === 0) return
    if (collector.running) { stopped = true; collector.running = false }
    else quickRestart.start()
  }
  Timer { id: quickRestart; interval: 300; onTriggered: { hub.stopped = false; if (hub.consumers.length > 0) collector.running = true } }
  Timer { id: restart; interval: 5000; onTriggered: if (hub.consumers.length > 0) collector.running = true }
}
