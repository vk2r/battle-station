pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Home page: GPU gauge, system rings, memory legend and one block per runtime.
Column {
  id: page
  required property var host
  spacing: Style.space(10)
  // Side padding of the runtimes section, the same as the gap above it.
  readonly property real inset: Style.space(10)

  // Small sibling of the GPU gauge: one ring of square blocks, percent inside,
  // label and detail beside it. No dial marks, a single rim.
  component MiniGauge: Item {
    id: mini
    property string label: ""
    property string detail: ""
    property color tint: host.fg   // colour of the filled blocks; the stock one is the text colour
    property real fraction: 0
    readonly property real shown: Math.max(0, Math.min(1, fraction))
    width: parent ? parent.width : 180
    height: miniRing.height
    onShownChanged: miniRing.requestPaint()

    Canvas {
      id: miniRing
      width: Style.space(52)
      height: width
      readonly property int blocks: 20
      readonly property real thickness: Style.space(7)
      property color ink: host.fg
      onInkChanged: requestPaint()
      property color fill: mini.tint
      onFillChanged: requestPaint()

      onPaint: {
        var c = getContext("2d")
        c.reset()
        var cx = width / 2, cy = height / 2
        var outer = width / 2 - Style.space(2)
        var step = 2 * Math.PI / blocks
        var gap = step * 0.25
        var top = -Math.PI / 2
        c.lineCap = "butt"
        c.lineWidth = thickness
        for (var i = 0; i < blocks; i++) {
          c.strokeStyle = (i + 0.5) / blocks <= mini.shown ? Qt.rgba(fill.r, fill.g, fill.b, 0.85) : Qt.rgba(ink.r, ink.g, ink.b, 0.08)
          c.beginPath()
          c.arc(cx, cy, outer - Style.space(2) - thickness / 2, top + i * step + gap / 2, top + (i + 1) * step - gap / 2, false)
          c.stroke()
        }
        c.lineWidth = Style.space(1)
        c.strokeStyle = Qt.rgba(ink.r, ink.g, ink.b, 0.6)
        c.beginPath(); c.arc(cx, cy, outer, 0, 2 * Math.PI); c.stroke()
      }

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: Math.round(mini.shown * 100) + "%"
        color: host.fg
        font.family: host.font
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Column {
      anchors.left: miniRing.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: miniRing.verticalCenter
      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: mini.label.toUpperCase()
        color: host.fg
        font.family: host.font
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }
      Text {
        visible: mini.detail !== ""
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: mini.detail
        color: host.dim
        font.family: host.font
        font.pixelSize: Style.font.caption
      }
    }
  }


  PanelSeparator { width: parent.width; foreground: host.fg }
  // Brutalist gauge: a heavy ring of square blocks that fills clockwise from
  // the top, split into LLM / desktop & apps / free like the legend below.
  // The bar icon shows only the LLM part, and the legend says so.
  // Load, CPU and RAM sit to its right as small rings, spread top to bottom.
  Item {
    id: gauge
    width: parent.width
    height: Style.space(176)
    readonly property real total: host.gpu.vram_total || 0
    property real llm: total ? Math.min(1, (host.stats.llm_vram || 0) / total) : 0
    property real other: total ? Math.min(1 - llm, (host.stats.other_vram || 0) / total) : 0
    Behavior on llm { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    Behavior on other { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    onLlmChanged: ring.requestPaint()
    onOtherChanged: ring.requestPaint()

    Canvas {
      id: ring
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.height
      height: width
      readonly property int blocks: 40
      readonly property real thickness: Style.space(20)
      readonly property real tickLength: Style.space(8)
      property color accent: Color.accent
      property color ink: host.fg
      onAccentChanged: requestPaint()
      onInkChanged: requestPaint()

      function inkAt(alpha) { return Qt.rgba(ring.ink.r, ring.ink.g, ring.ink.b, alpha) }

      onPaint: {
        var c = getContext("2d")
        c.reset()
        var cx = width / 2, cy = height / 2
        var outer = width / 2 - tickLength - Style.space(4)
        var radius = outer - thickness / 2
        var step = 2 * Math.PI / blocks
        var gap = step * 0.22
        var top = -Math.PI / 2

        // The blocks: square-cut slabs, no rounding, no gradients.
        c.lineCap = "butt"
        c.lineWidth = thickness
        for (var i = 0; i < blocks; i++) {
          var middle = (i + 0.5) / blocks
          c.strokeStyle = middle <= gauge.llm ? ring.accent
            : middle <= gauge.llm + gauge.other ? inkAt(0.55) : inkAt(0.08)
          c.beginPath()
          c.arc(cx, cy, radius, top + i * step + gap / 2, top + (i + 1) * step - gap / 2, false)
          c.stroke()
        }

        // Hard rims hugging the slabs, like a cast concrete collar.
        c.lineWidth = Style.space(2)
        c.strokeStyle = inkAt(0.85)
        c.beginPath(); c.arc(cx, cy, outer + Style.space(2), 0, 2 * Math.PI); c.stroke()
        c.lineWidth = 1
        c.strokeStyle = inkAt(0.35)
        c.beginPath(); c.arc(cx, cy, outer - thickness - Style.space(3), 0, 2 * Math.PI); c.stroke()

        // Quarter marks of an old dial: heavy at 0 / 50 %, light at 25 / 75 %.
        for (var q = 0; q < 4; q++) {
          var angle = top + q * Math.PI / 2
          c.lineWidth = q % 2 === 0 ? Style.space(4) : Style.space(2)
          c.strokeStyle = inkAt(q % 2 === 0 ? 0.9 : 0.5)
          c.beginPath()
          c.moveTo(cx + Math.cos(angle) * (outer + Style.space(3)), cy + Math.sin(angle) * (outer + Style.space(3)))
          c.lineTo(cx + Math.cos(angle) * (outer + Style.space(3) + tickLength), cy + Math.sin(angle) * (outer + Style.space(3) + tickLength))
          c.stroke()
        }
      }
    }

    Column {
      anchors.centerIn: ring
      spacing: 0
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: "GPU"
        color: host.dim
        font.family: host.font
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 2
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: host.gib(host.gpu.vram_used)
        color: host.fg
        font.family: host.font
        font.pixelSize: Style.font.display
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: "/ " + host.gib(host.gpu.vram_total) + " GIB"
        color: host.dim
        font.family: host.font
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: host.t("ringInUse").toUpperCase()
        color: host.dim
        font.family: host.font
        font.pixelSize: Style.font.caption
        font.letterSpacing: 2
      }
    }

    // justify-content: space-between, vertically: first at the top of the
    // big ring, last at its bottom, the middle one centred.
    Item {
      anchors.left: ring.right
      anchors.leftMargin: Style.space(16)
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      MiniGauge {
        anchors.top: parent.top
        label: host.t("load")
        // The engine sends the followed card's brand colour; stock when it has none.
        tint: host.gpu.color || host.fg
        detail: [host.gpu.temp ? Math.round(host.gpu.temp) + " °C" : "", host.gpu.power ? Math.round(host.gpu.power) + " W" : ""]
          .filter(function(part) { return part !== "" }).join(" · ")
        fraction: (host.gpu.busy || 0) / 100
      }
      MiniGauge {
        anchors.verticalCenter: parent.verticalCenter
        label: "CPU"
        // Busy share expressed as cores: 25 % of 16 cores is 4.0 / 16.
        detail: host.system.cores
          ? host.t("coresUsed", [((host.system.cpu || 0) / 100 * host.system.cores).toFixed(1), host.system.cores])
          : ""
        fraction: (host.system.cpu || 0) / 100
      }
      MiniGauge {
        anchors.bottom: parent.bottom
        label: "RAM"
        detail: host.gib(host.system.mem_used) + " / " + host.gib(host.system.mem_total) + " GiB"
        fraction: host.system.mem_total ? host.system.mem_used / host.system.mem_total : 0
      }
    }
  }

  // Level bar of square-cut blocks with gaps, like the GPU ring: a block is
  // lit once the fill reaches it (any usage lights the first), in the same
  // green-to-red level colour.
  component SegmentBar: Item {
    id: seg
    property real fraction: 0
    readonly property int blocks: 30
    readonly property real gap: Style.space(2)
    readonly property real step: (width + gap) / blocks
    property real shown: Math.max(0, Math.min(1, fraction))
    Behavior on shown { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
    height: Style.space(8)

    Repeater {
      model: seg.blocks
      delegate: Rectangle {
        required property int index
        x: index * seg.step
        width: seg.step - seg.gap
        height: seg.height
        color: index < Math.ceil(seg.shown * seg.blocks - 0.001)
          ? host.levelColor(seg.fraction) : Qt.rgba(host.fg.r, host.fg.g, host.fg.b, 0.12)
      }
    }
  }

  component LegendRow: Item {
    id: legend
    property color swatch: "transparent"
    property bool outlined: false
    property string name: ""
    property string amount: ""
    property string note: ""
    property real fraction: -1    // >= 0 draws a fill bar in the level colour
    width: parent ? parent.width : 300
    height: Math.max(legendName.height, legendNote.visible ? legendName.height + legendNote.height : 0)
      + (fraction >= 0 ? Style.space(8) : 0)
    Rectangle {
      id: swatchBox
      y: (legendName.height - height) / 2
      width: Style.space(10); height: width; radius: 0
      color: legend.outlined ? "transparent" : legend.swatch
      border.width: legend.outlined ? 1 : 0
      border.color: host.dim
    }
    Text {
      textFormat: Text.PlainText
      id: legendName
      anchors.left: swatchBox.right
      anchors.leftMargin: Style.space(8)
      text: legend.name
      color: host.fg
      font.family: host.font
      font.pixelSize: Style.font.caption
    }
    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      text: legend.amount
      color: host.fg
      font.family: host.font
      font.pixelSize: Style.font.caption
    }
    Text {
      textFormat: Text.PlainText
      id: legendNote
      visible: legend.note !== ""
      anchors.top: legendName.bottom
      anchors.left: legendName.left
      anchors.right: parent.right
      elide: Text.ElideRight
      text: legend.note
      color: host.dim
      font.family: host.font
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      visible: legend.fraction >= 0
      anchors.bottom: parent.bottom
      anchors.left: legendName.left
      anchors.right: parent.right
      height: Style.space(4)
      radius: height / 2
      color: Qt.rgba(host.fg.r, host.fg.g, host.fg.b, 0.12)
      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, legend.fraction))
        height: parent.height
        radius: parent.radius
        color: host.levelColor(legend.fraction)
        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 400 } }
      }
    }
  }

  // Extra air between the gauges and the VRAM line.
  Item { width: 1; height: Style.space(8) }

  // The VRAM split in one line, one entry per share of the ring: colour,
  // name and GiB, spread like justify-content: space-between.
  Item {
    id: vramRow
    width: parent.width
    height: vramEntries.height
    // Zero shows as "0 MiB", not "0.0": JetBrains Mono's dotted zeros read as "8.8" at caption size.
    function amount(bytes) { return (bytes || 0) > 0 ? host.gib(bytes) + " GiB" : "0 MiB" }
    readonly property var entries: (host.hasRuntimes ? [
      { title: host.t("colModels"), swatch: Color.accent, outlined: false, amount: amount(host.stats.llm_vram) }
    ] : []).concat([
      { title: host.t("colApps"), swatch: Qt.rgba(host.fg.r, host.fg.g, host.fg.b, 0.5), outlined: false,
        amount: amount(host.stats.other_vram) },
      { title: host.t("free"), swatch: "transparent", outlined: true,
        amount: amount(Math.max(0, (host.gpu.vram_total || 0) - (host.gpu.vram_used || 0))) }
    ])

    Row {
      id: vramEntries
      // space-around: equal air per entry, edges get half the inner gap.
      readonly property real widthOfEntries: {
        var total = 0
        for (var i = 0; i < children.length; i++) if (children[i].visible) total += children[i].implicitWidth
        return total
      }
      readonly property real freeSpace: Math.max(0, vramRow.width - widthOfEntries)
      spacing: Math.max(Style.space(8), freeSpace / vramRow.entries.length)
      x: spacing / 2
      Repeater {
        model: vramRow.entries
        delegate: Row {
          id: entry
          required property var modelData
          spacing: Style.space(6)
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(10); height: width
            color: entry.modelData.outlined ? "transparent" : entry.modelData.swatch
            border.width: entry.modelData.outlined ? 1 : 0
            border.color: host.dim
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: entry.modelData.title
            color: host.fg
            font.family: host.font
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: entry.modelData.amount
            color: host.dim
            font.family: host.font
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: (host.stats.llm_spilled || 0) > 268435456
    width: parent.width
    wrapMode: Text.WordWrap
    text: host.t("spilled", [host.gib(host.stats.llm_spilled)])
    color: Color.urgent
    font.family: host.font
    font.pixelSize: Style.font.caption
  }
  // Air between the VRAM split and the runtimes; with no runtime installed
  // the whole section disappears.
  Item { width: 1; height: Style.space(3); visible: host.hasRuntimes }
  PanelSectionHeader {
    x: page.inset
    width: parent.width - 2 * page.inset
    text: host.t("runtimes").toUpperCase(); foreground: host.fg; fontFamily: host.font; visible: host.hasRuntimes
  }

  Repeater {
    model: host.hasRuntimes ? host.foundRuntimes : []
    // A running runtime sits in a card; a stopped or missing one stays flat.
    delegate: Rectangle {
      id: card
      required property var modelData
      readonly property real pad: modelData.running ? Style.space(8) : 0
      x: page.inset
      width: page.width - 2 * page.inset
      height: block.implicitHeight + 2 * pad
      color: modelData.running ? Qt.rgba(host.fg.r, host.fg.g, host.fg.b, 0.04) : "transparent"
      border.width: modelData.running ? 1 : 0
      border.color: Qt.rgba(host.fg.r, host.fg.g, host.fg.b, 0.2)

      Column {
        id: block
        property var modelData: card.modelData
        x: card.pad
        y: card.pad
        width: card.width - 2 * card.pad
        spacing: Style.space(6)
        readonly property bool loaded: modelData.models.some(function(model) { return model.state !== "sleeping" })

        Item {
          width: parent.width
          height: runtimeName.height
          Rectangle {
            id: dot
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8); height: width; radius: width / 2
            color: block.loaded ? Color.accent : (block.modelData.running ? host.dim : "transparent")
            border.width: 1
            border.color: block.loaded ? Color.accent : host.dim
          }
          Text {
            textFormat: Text.PlainText
            id: runtimeName
            anchors.left: dot.right
            anchors.leftMargin: Style.space(8)
            text: block.modelData.name
            color: host.fg
            font.family: host.font
            font.pixelSize: Style.font.body
            font.bold: block.loaded
          }
          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: host.runtimeState(block.modelData)
            color: block.loaded ? Color.accent : host.dim
            font.family: host.font
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: block.modelData.models
          delegate: Column {
            id: modelBlock
            required property var modelData
            readonly property bool hasUsage: modelData.context_used !== undefined && modelData.context_used !== null && modelData.context > 0
            width: block.width
            spacing: Style.space(6)
            Text {
              textFormat: Text.PlainText
              width: parent.width
              leftPadding: Style.space(16)
              elide: Text.ElideMiddle
              text: modelBlock.modelData.name
                + (modelBlock.modelData.context && !modelBlock.hasUsage ? "  ·  " + host.ctx(modelBlock.modelData.context) : "")
                + (modelBlock.modelData.state && modelBlock.modelData.state !== "loaded" ? "  ·  " + host.stateName(modelBlock.modelData.state) : "")
              color: host.fg
              font.family: host.font
              font.pixelSize: Style.font.caption
            }
            // Tokens in the context window, and the VRAM llama.cpp reserved for it (KV cache).
            Item {
              visible: modelBlock.hasUsage
              x: Style.space(16)
              width: parent.width - x
              height: visible ? Math.max(contextLabel.height, contextValue.height) + Style.space(16) + Style.space(4) : 0
              readonly property real fraction: modelBlock.hasUsage ? modelBlock.modelData.context_used / modelBlock.modelData.context : 0
              Text {
                textFormat: Text.PlainText
                id: contextLabel
                text: host.t("context")
                  + (modelBlock.modelData.context_memory
                    ? " · " + host.mib(modelBlock.modelData.context_memory * parent.fraction)
                      + " / " + host.mib(modelBlock.modelData.context_memory)
                    : "")
                color: host.dim
                font.family: host.font
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                id: contextValue
                anchors.right: parent.right
                text: host.t("tokensPct", [host.tokens(modelBlock.modelData.context_used), host.tokens(modelBlock.modelData.context), Math.round(parent.fraction * 100)])
                color: parent.fraction >= 0.9 ? host.levelColor(parent.fraction) : host.fg
                font.family: host.font
                font.pixelSize: Style.font.caption
              }
              SegmentBar {
                anchors.bottom: parent.bottom
                // Air between this bar and the Output one below it.
                anchors.bottomMargin: Style.space(4)
                width: parent.width
                fraction: parent.fraction
              }
            }

            // Tokens generated for the reply in progress (or the last one)
            // and the most it may produce (n_predict), from llama.cpp's slots.
            Item {
              visible: (modelBlock.modelData.output_limit || 0) > 0
              x: Style.space(16)
              width: parent.width - x
              height: visible ? Math.max(outputLabel.height, outputValue.height) + Style.space(16) : 0
              readonly property real fraction: modelBlock.modelData.output_limit ? (modelBlock.modelData.output_used || 0) / modelBlock.modelData.output_limit : 0
              Text {
                textFormat: Text.PlainText
                id: outputLabel
                text: host.t("output")
                color: host.dim
                font.family: host.font
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                id: outputValue
                anchors.right: parent.right
                text: host.t(modelBlock.modelData.generating ? "outGenerating" : "outLastReply",
                  [host.tokens(modelBlock.modelData.output_used), host.tokens(modelBlock.modelData.output_limit), Math.round(parent.fraction * 100)])
                color: parent.fraction >= 0.9 ? host.levelColor(parent.fraction) : host.fg
                font.family: host.font
                font.pixelSize: Style.font.caption
              }
              SegmentBar {
                anchors.bottom: parent.bottom
                width: parent.width
                fraction: parent.fraction
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: block.modelData.running
          width: block.width
          leftPadding: Style.space(16)
          wrapMode: Text.WordWrap
          text: [
            (block.modelData.vram || 0) > 0
              ? host.t("rtVram", [host.mib(block.modelData.vram)])
                + ((block.modelData.spilled || 0) > 268435456 ? " " + host.t("rtInRam", [host.gib(block.modelData.spilled)]) : "")
              : "",
            "CPU " + host.pct(block.modelData.cpu),
            host.t("rtRam", [host.mib(block.modelData.memory)])
          ].filter(function(part) { return part !== "" }).join(" · ")
            + (block.modelData.clients.length ? " · " + block.modelData.clients.join(", ").toUpperCase() : "")
          color: host.dim
          font.family: host.font
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  PanelSeparator { width: parent.width; foreground: host.fg }

  Item {
    width: parent.width
    height: detachButton.height

    Button {
      id: detachButton
      visible: host.hasRuntimes
      text: host.t("detach")
      iconText: "󰇪"
      bordered: true
      foreground: host.fg
      fontFamily: host.font
      enabled: host.stats.active === true
      tooltipText: host.t("freeGpuTip")
      onClicked: Quickshell.execDetached(["bash", host.hostWidget.scriptDir + "/free-gpu.sh"])
    }
    Button {
      id: traceButton
      anchors.right: parent.right
      text: host.t("trace")
      iconText: "󰐰"
      bordered: true
      foreground: host.fg
      fontFamily: host.font
      onClicked: { host.close(); if (host.bar) host.bar.run("omarchy-launch-or-focus-tui btop") }
    }
  }
}
