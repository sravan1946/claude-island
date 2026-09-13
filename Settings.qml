// The settings window: one place to change what the surface looks like and
// where it sits, writing the same config.json the surface is already watching.
// There is no apply button and no second channel -- every control writes the
// file, the surface reloads it, and you watch the bar change behind the window.
//
// The controls are hand-built rather than QtQuick.Controls. They have to sit
// next to the bar they are configuring, and the Basic style does not; these are
// the same rectangles, the same radii and the same two typefaces the surface
// uses, so the window reads as part of it.
import QtQuick
import QtQuick.Layouts
import Quickshell
import "themes.js" as Themes

FloatingWindow {
    id: sw

    // The island itself: the live palette, the current config, and the writer.
    required property var isl

    title: "claude-island"
    implicitWidth: 520
    implicitHeight: 680
    minimumSize.width: 420
    minimumSize.height: 420
    color: isl.base

    // ------------------------------------------------------------- primitives

    component Heading: Text {
        Layout.fillWidth: true
        Layout.topMargin: 18
        Layout.bottomMargin: 2
        color: sw.isl.bright
        font { family: sw.isl.sans; pixelSize: 12; weight: Font.DemiBold }
    }

    component Note: Text {
        Layout.fillWidth: true
        Layout.bottomMargin: 6
        color: sw.isl.muted
        wrapMode: Text.Wrap
        font { family: sw.isl.sans; pixelSize: 11 }
    }

    component Rule: Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        Layout.topMargin: 12
        color: sw.isl.edge
    }

    // A row of mutually exclusive choices. Wide enough to read, never a dropdown
    // -- there are never more than a handful and hiding them behind a click is
    // how a settings window stops telling you what it can do.
    component Seg: RowLayout {
        property var options: []        // [{ label, value }]
        property var current: null
        signal picked(var value)
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: options
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: modelData.value === current
                Layout.fillWidth: true
                implicitHeight: 30
                radius: 7
                color: on ? Qt.rgba(sw.isl.signal_.r, sw.isl.signal_.g, sw.isl.signal_.b, 0.16)
                          : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent")
                border.width: 1
                border.color: on ? Qt.rgba(sw.isl.signal_.r, sw.isl.signal_.g, sw.isl.signal_.b, 0.5)
                                 : sw.isl.edge
                Behavior on color { ColorAnimation { duration: 110 } }
                Behavior on border.color { ColorAnimation { duration: 110 } }
                Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    color: on ? sw.isl.bright : sw.isl.text
                    font { family: sw.isl.sans; pixelSize: 12
                           weight: on ? Font.DemiBold : Font.Normal }
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: picked(modelData.value)
                }
            }
        }
    }

    // Label, track, number. Dragging anywhere on the track moves it -- a handle
    // you have to hit exactly is a control that fights you.
    component Slide: RowLayout {
        property string label: ""
        property int from: 0
        property int to: 100
        property int value: 0
        property string suffix: ""
        property string zeroLabel: ""   // what 0 means, when it means something
        signal moved(int v)
        Layout.fillWidth: true
        spacing: 10

        Text {
            Layout.preferredWidth: 96
            text: label
            color: sw.isl.text
            font { family: sw.isl.sans; pixelSize: 12 }
        }
        Rectangle {
            id: track
            Layout.fillWidth: true
            implicitHeight: 4
            radius: 2
            color: sw.isl.edge
            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, (value - from) / (to - from)))
                height: parent.height
                radius: 2
                color: sw.isl.flow
            }
            Rectangle {
                x: parent.width * Math.max(0, Math.min(1, (value - from) / (to - from))) - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 12; height: 12; radius: 6
                color: sw.isl.bright
                border.width: 1
                border.color: sw.isl.base
                scale: sma.pressed ? 1.2 : (sma.containsMouse ? 1.1 : 1.0)
                Behavior on scale { NumberAnimation { duration: 110 } }
            }
            MouseArea {
                id: sma
                anchors.fill: parent
                anchors.margins: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                function set(mx) {
                    const f = Math.max(0, Math.min(1, mx / track.width));
                    moved(Math.round(from + f * (to - from)));
                }
                onPressed: function (m) { set(m.x); }
                onPositionChanged: function (m) { if (pressed) set(m.x); }
            }
        }
        Text {
            Layout.preferredWidth: 54
            horizontalAlignment: Text.AlignRight
            text: (value === 0 && zeroLabel) ? zeroLabel : value + suffix
            color: sw.isl.muted
            font { family: sw.isl.mono; pixelSize: 11 }
        }
    }

    component Field: Rectangle {
        property string label: ""
        property string value: ""
        property string placeholder: ""
        signal committed(string v)
        Layout.fillWidth: true
        implicitHeight: 30
        radius: 7
        color: Qt.rgba(0, 0, 0, 0.22)
        border.width: 1
        border.color: inp.activeFocus
            ? Qt.rgba(sw.isl.signal_.r, sw.isl.signal_.g, sw.isl.signal_.b, 0.55)
            : sw.isl.edge
        Behavior on border.color { ColorAnimation { duration: 110 } }
        TextInput {
            id: inp
            anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
            verticalAlignment: TextInput.AlignVCenter
            text: value
            color: sw.isl.text
            selectByMouse: true
            clip: true
            font { family: sw.isl.sans; pixelSize: 12 }
            onEditingFinished: committed(text)
            Keys.onReturnPressed: { committed(text); focus = false; }
            Keys.onEscapePressed: { text = value; focus = false; }
        }
        Text {
            anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
            verticalAlignment: Text.AlignVCenter
            visible: inp.text === "" && !inp.activeFocus
            text: placeholder
            color: sw.isl.muted
            font { family: sw.isl.sans; pixelSize: 12 }
        }
    }

    component Btn: Rectangle {
        property string label: ""
        property color tint: sw.isl.muted
        signal clicked()
        implicitWidth: bl.implicitWidth + 22
        implicitHeight: 27
        radius: 7
        color: bm.containsMouse ? Qt.rgba(tint.r, tint.g, tint.b, 0.18)
                                : Qt.rgba(tint.r, tint.g, tint.b, 0.08)
        border.width: 1
        border.color: Qt.rgba(tint.r, tint.g, tint.b, bm.containsMouse ? 0.6 : 0.3)
        Behavior on color { ColorAnimation { duration: 110 } }
        Text {
            id: bl
            anchors.centerIn: parent
            text: label
            color: sw.isl.text
            font { family: sw.isl.sans; pixelSize: 11; weight: Font.DemiBold }
        }
        MouseArea {
            id: bm
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

    // ------------------------------------------------------------------ state
    readonly property var cfg: isl.cfg
    readonly property var pal: Themes.palette(isl.cfg)

    function put(key, value) {
        isl.setCfg(key, value);
    }

    function putColor(key, hex) {
        const next = {};
        for (const k in (cfg.colors || {}))
            next[k] = cfg.colors[k];
        const clean = (hex || "").trim();
        if (/^#[0-9a-fA-F]{6}$/.test(clean))
            next[key] = clean.toLowerCase();
        else
            delete next[key];
        put("colors", next);
    }

    // ----------------------------------------------------------------- layout
    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: form.implicitHeight + 36
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: form
            anchors { left: parent.left; right: parent.right; top: parent.top
                      leftMargin: 20; rightMargin: 20; topMargin: 16 }
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: "Settings"
                color: sw.isl.bright
                font { family: sw.isl.sans; pixelSize: 17; weight: Font.DemiBold }
            }
            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: 4
                text: "Changes are saved as you make them and take effect immediately."
                color: sw.isl.muted
                wrapMode: Text.Wrap
                font { family: sw.isl.sans; pixelSize: 11 }
            }

            // ---------------------------------------------------------- theme
            Heading { text: "Theme" }

            Repeater {
                model: Themes.themeNames
                delegate: Rectangle {
                    required property var modelData
                    readonly property var preset: Themes.presets[modelData]
                    readonly property bool on: modelData === sw.cfg.theme
                    Layout.fillWidth: true
                    implicitHeight: 38
                    radius: 8
                    color: on ? Qt.rgba(sw.isl.signal_.r, sw.isl.signal_.g, sw.isl.signal_.b, 0.13)
                              : (tm.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent")
                    border.width: 1
                    border.color: on ? Qt.rgba(sw.isl.signal_.r, sw.isl.signal_.g, sw.isl.signal_.b, 0.45)
                                     : sw.isl.edge
                    Behavior on color { ColorAnimation { duration: 110 } }

                    RowLayout {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        spacing: 10
                        Text {
                            Layout.fillWidth: true
                            text: modelData
                            color: on ? sw.isl.bright : sw.isl.text
                            font { family: sw.isl.sans; pixelSize: 12
                                   weight: on ? Font.DemiBold : Font.Normal }
                        }
                        // The palette itself is the label: the four hues the
                        // bar actually spends, in the order you meet them.
                        Repeater {
                            model: ["flow", "mull", "signal_", "fault"]
                            delegate: Rectangle {
                                required property var modelData
                                width: 16; height: 7; radius: 2
                                color: preset[modelData]
                            }
                        }
                    }
                    MouseArea {
                        id: tm
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sw.put("theme", modelData)
                    }
                }
            }

            // --------------------------------------------------------- colour
            Heading { text: "Colours" }
            Note {
                text: Object.keys(sw.cfg.colors || {}).length
                      ? "Overrides sit on top of the theme. Clear a field to go back to it."
                      : "Six-digit hex. Anything you set here overrides the theme above."
            }

            Repeater {
                model: Themes.keys
                delegate: RowLayout {
                    required property var modelData
                    readonly property bool overridden: !!(sw.cfg.colors || {})[modelData]
                    Layout.fillWidth: true
                    spacing: 10

                    Rectangle {
                        implicitWidth: 22; implicitHeight: 22; radius: 5
                        color: sw.pal[modelData]
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.15)
                    }
                    Text {
                        Layout.fillWidth: true
                        text: Themes.labels[modelData]
                        color: overridden ? sw.isl.text : sw.isl.muted
                        font { family: sw.isl.sans; pixelSize: 11 }
                    }
                    Field {
                        Layout.preferredWidth: 108
                        Layout.fillWidth: false
                        value: sw.pal[modelData]
                        placeholder: "#000000"
                        onCommitted: function (v) { sw.putColor(modelData, v); }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8
                Btn {
                    label: "Clear colour overrides"
                    onClicked: sw.put("colors", ({}))
                }
                Item { Layout.fillWidth: true }
            }

            Rule {}

            // ------------------------------------------------------- position
            Heading { text: "Position" }
            Seg {
                options: [{ label: "Bottom edge", value: "bottom" },
                          { label: "Top edge", value: "top" }]
                current: sw.cfg.position
                onPicked: function (v) { sw.put("position", v); }
            }

            Heading { text: "Monitors" }
            Note { text: "The bar is drawn on every screen unless you narrow it here." }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 30
                radius: 7
                readonly property bool on: sw.cfg.monitors === "all"
                color: on ? Qt.rgba(sw.isl.signal_.r, sw.isl.signal_.g, sw.isl.signal_.b, 0.13)
                          : "transparent"
                border.width: 1
                border.color: on ? Qt.rgba(sw.isl.signal_.r, sw.isl.signal_.g, sw.isl.signal_.b, 0.45)
                                 : sw.isl.edge
                Text {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    text: "All monitors"
                    color: parent.on ? sw.isl.bright : sw.isl.text
                    font { family: sw.isl.sans; pixelSize: 12 }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sw.put("monitors", "all")
                }
            }

            Repeater {
                model: Quickshell.screens
                delegate: Rectangle {
                    required property var modelData
                    readonly property var list: sw.cfg.monitors === "all" ? [] : sw.cfg.monitors
                    readonly property bool on: list.indexOf(modelData.name) >= 0
                    Layout.fillWidth: true
                    implicitHeight: 30
                    radius: 7
                    color: on ? Qt.rgba(sw.isl.flow.r, sw.isl.flow.g, sw.isl.flow.b, 0.13)
                              : "transparent"
                    border.width: 1
                    border.color: on ? Qt.rgba(sw.isl.flow.r, sw.isl.flow.g, sw.isl.flow.b, 0.45)
                                     : sw.isl.edge
                    RowLayout {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.name
                            color: on ? sw.isl.bright : sw.isl.text
                            font { family: sw.isl.sans; pixelSize: 12 }
                        }
                        Text {
                            text: modelData.width + "×" + modelData.height
                            color: sw.isl.muted
                            font { family: sw.isl.mono; pixelSize: 10 }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const next = list.slice();
                            const at = next.indexOf(modelData.name);
                            if (at >= 0)
                                next.splice(at, 1);
                            else
                                next.push(modelData.name);
                            sw.put("monitors", next.length ? next : "all");
                        }
                    }
                }
            }

            Rule {}

            // ----------------------------------------------------------- size
            Heading { text: "Size" }

            Slide {
                label: "Lane width"; from: 24; to: 96; suffix: "px"
                value: sw.cfg.laneWidth
                onMoved: function (v) { sw.put("laneWidth", v); }
            }
            Slide {
                label: "Bar height"; from: 6; to: 24; suffix: "px"
                value: sw.cfg.barHeight
                onMoved: function (v) { sw.put("barHeight", v); }
            }
            Slide {
                label: "Panel width"; from: 0; to: 900; suffix: "px"
                zeroLabel: "auto"
                value: sw.cfg.panelWidth
                onMoved: function (v) { sw.put("panelWidth", v < 360 ? 0 : v); }
            }
            Note {
                Layout.topMargin: 2
                text: "Auto takes a share of each screen, so a wide monitor gets a wider panel."
            }

            Heading { text: "Timing" }
            Slide {
                label: "Prompt shows for"; from: 2000; to: 20000; suffix: "ms"
                value: sw.cfg.announceMs
                onMoved: function (v) { sw.put("announceMs", Math.round(v / 500) * 500); }
            }
            Note {
                Layout.topMargin: 2
                text: "How long a permission prompt holds the panel open before folding back to the pulsing lane. Hovering cancels the countdown."
            }

            Rule {}

            // ---------------------------------------------------------- fonts
            Heading { text: "Fonts" }
            Note { text: "One for what a person meant, one for what the machine is doing." }

            Field {
                value: sw.cfg.fontSans
                placeholder: "Cantarell"
                onCommitted: function (v) { sw.put("fontSans", v.trim()); }
            }
            Field {
                Layout.topMargin: 6
                value: sw.cfg.fontMono
                placeholder: "JetBrainsMono Nerd Font"
                onCommitted: function (v) { sw.put("fontMono", v.trim()); }
            }

            Rule {}

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 12
                Layout.bottomMargin: 20
                spacing: 10
                Text {
                    Layout.fillWidth: true
                    text: sw.isl.cfgPath.replace(Quickshell.env("HOME") || "", "~")
                    color: sw.isl.muted
                    elide: Text.ElideMiddle
                    font { family: sw.isl.mono; pixelSize: 9 }
                }
                Btn {
                    label: "Reset everything"
                    tint: sw.isl.no
                    onClicked: sw.isl.saveCfg({})
                }
                Btn {
                    label: "Close"
                    onClicked: sw.isl.settingsOpen = false
                }
            }
        }
    }
}
