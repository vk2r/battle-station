pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../I18n.js" as I18n

// The outer column splits the page into blocks — header, Widget
// section, Hardware section — that sit further apart than the rows
// inside them; each block keeps its own tight spacing.
Column {
  id: page
  required property var host
  spacing: Style.space(16)

  // Section title for the settings page: a small bold label above
  // its items.
  component SettingsTitle: Text {
    id: settingsTitle
    property string title: ""
    textFormat: Text.PlainText
    text: settingsTitle.title
    color: host.fg
    font.family: host.font
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1
  }

  // Checkbox for the Plugin section: a square check and the meter's
  // name in the colour its bar uses. `checked` stays bound to the
  // setting; toggling only emits, so the bar reacts through it.
  component SettingCheck: Item {
    id: settingCheck
    property string label: ""
    property color tint: host.fg
    property bool checked: true
    readonly property bool hot: checkArea.containsMouse
    signal toggled()

    implicitWidth: checkSquare.width + Style.space(6) + checkLabel.implicitWidth
    implicitHeight: Math.max(checkSquare.height, checkLabel.implicitHeight)
    opacity: settingCheck.checked ? 1 : 0.4
    Behavior on opacity { NumberAnimation { duration: 160 } }

    Rectangle {
      id: checkSquare
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      height: width
      radius: Style.space(3)
      color: settingCheck.checked ? settingCheck.tint : "transparent"
      border.width: 1
      border.color: settingCheck.checked || settingCheck.hot ? settingCheck.tint : host.dim

      Text {
        anchors.centerIn: parent
        visible: settingCheck.checked
        textFormat: Text.PlainText
        text: "\udb80\udd2c"  // check
        color: Color.popups.background
        font.family: host.font
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      id: checkLabel
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: checkSquare.right
      anchors.leftMargin: Style.space(6)
      textFormat: Text.PlainText
      text: settingCheck.label
      color: settingCheck.tint
      font.family: host.font
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    MouseArea {
      id: checkArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: settingCheck.toggled()
    }
  }

  // Header: back button beside the page title, using the hero's
  // title typography instead of duplicating the home header. Its
  // rule stays glued to it whatever the outer spacing.
  Column {
    width: parent.width
    spacing: Style.space(10)

    Row {
      spacing: Style.space(12)
      Button {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "\udb80\udc4d"
        bordered: false
        foreground: host.fg
        fontFamily: host.font
        tooltipText: host.t("backTip")
        onClicked: host.settingsOpen = false
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: host.t("settings")
        color: host.fg
        font.family: host.font
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    PanelSeparator { width: parent.width; foreground: host.fg }
  }

  // Widget: interface language.
  Column {
    width: parent.width
    spacing: Style.space(10)

    SettingsTitle { title: host.t("sectionWidget").toUpperCase() }

    // The dropdown fills the row after the fixed label, so both
    // selects end flush with the panel edge.
    Item {
      width: parent.width
      height: languageLabel.implicitHeight + Style.space(6)

      Text {
        id: languageLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(90)
        textFormat: Text.PlainText
        text: host.t("language")
        color: host.dim
        font.family: host.font
        font.pixelSize: Style.font.caption
      }
      CompactDropdown {
        id: languagePicker
        anchors.left: languageLabel.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // Wide enough for the longest option, plus padding and the chevron.
        fontSize: Style.font.caption
        rowHeight: languageLabel.implicitHeight + Style.space(6)
        popupRowHeight: languageLabel.implicitHeight + Style.space(8)
        showLabel: false
        fontFamily: host.font
        options: [{ value: "auto", label: host.t("systemLanguage", [I18n.languageName(host.systemLang)]) }]
          .concat(I18n.LANGUAGES.map(function(l) { return { value: l.code, label: l.name } }))
        value: host.languageSetting
        // Picking cuts the value binding inside the dropdown; restore it.
        onChanged: function(picked) {
          if (host.hostWidget) host.hostWidget.setLanguage(picked)
          languagePicker.value = Qt.binding(function() { return host.languageSetting })
        }
      }
    }
  }

  // Hardware: which graphics card the panel follows.
  Column {
    width: parent.width
    spacing: Style.space(10)

    SettingsTitle { title: host.t("sectionHardware").toUpperCase() }

    // Same full-width select as the language row.
    Item {
      width: parent.width
      height: gpuLabel.implicitHeight + Style.space(6)
      visible: host.gpus.length > 0

      Text {
        id: gpuLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(90)
        textFormat: Text.PlainText
        text: host.t("gpu")
        color: host.dim
        font.family: host.font
        font.pixelSize: Style.font.caption
      }
      CompactDropdown {
        id: gpuPicker
        anchors.left: gpuLabel.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // Wide enough for the longest option, plus padding and the chevron.
        fontSize: Style.font.caption
        rowHeight: gpuLabel.implicitHeight + Style.space(6)
        popupRowHeight: gpuLabel.implicitHeight + Style.space(8)
        showLabel: false
        fontFamily: host.font
        options: host.gpus.map(function(gpu) {
          return { value: gpu.id, label: (gpu.name || gpu.id) + " · " + host.gib(gpu.vram_total) + " GiB" }
        })
        value: host.gpuChoice
        // Picking cuts the value binding inside the dropdown; restore it.
        onChanged: function(picked) {
          if (host.hostWidget) host.hostWidget.setGpu(picked)
          gpuPicker.value = Qt.binding(function() { return host.gpuChoice })
        }
      }
    }
  }

  // Plugin: which level meters the bar shows. The checkboxes carry
  // their meter's colour — CPU and RAM in the panel's ink, load in
  // the followed card's brand colour, models in the theme accent.
  Column {
    width: parent.width
    spacing: Style.space(10)

    SettingsTitle { title: host.t("sectionPlugin").toUpperCase() }

    // Same full-width row as the language and GPU selects.
    Item {
      width: parent.width
      height: itemsLabel.implicitHeight + Style.space(6)

      Text {
        id: itemsLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(90)
        textFormat: Text.PlainText
        text: host.t("items")
        color: host.dim
        font.family: host.font
        font.pixelSize: Style.font.caption
      }
      Row {
        anchors.left: itemsLabel.right
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(20)

        SettingCheck {
          label: host.t("barCpu")
          tint: host.fg
          checked: host.showCpu
          onToggled: host.setBarVisible("showCpu", !host.showCpu)
        }
        SettingCheck {
          label: host.t("barRam")
          tint: host.fg
          checked: host.showRam
          onToggled: host.setBarVisible("showRam", !host.showRam)
        }
        SettingCheck {
          label: host.t("barLoad")
          tint: host.gpu.color || host.fg
          checked: host.showLoad
          onToggled: host.setBarVisible("showLoad", !host.showLoad)
        }
        SettingCheck {
          label: host.t("barModels")
          tint: Color.accent
          checked: host.showModels
          onToggled: host.setBarVisible("showModels", !host.showModels)
        }
      }
    }
  }
}
