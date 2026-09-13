// Claude session meter.
//
// Collapsed: a lane per live session along the bottom edge. Lane HEIGHT carries
// state (quiet 2px -> working 5px -> needs you 8px) so the bar is readable at a
// glance without relying on colour at all; colour only says which category.
// Hover: it grows into a panel with per-session detail, Allow/Deny for a pending
// request, and the 5h / 7d limits.
//
// State comes from a long-lived state.py --serve feed; a decision goes
// back as a file the approve.sh hook is blocking on.
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "themes.js" as Themes

ShellRoot {
    id: root

    readonly property string dir: Quickshell.shellDir
    readonly property string stateRoot: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/claude-approve"
    readonly property string cfgDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/claude-island"
    readonly property string cfgPath: cfgDir + "/config.json"

    // ----------------------------------------------------------------- config
    // Watched, not read once: the settings window writes this file and the
    // surface picks the change up, so there is one path in and no second
    // channel to keep in step. A missing or broken file is a normal state --
    // it means the defaults, not an error.
    property var cfg: Themes.settle({})

    FileView {
        id: cfgFile
        path: root.cfgPath
        watchChanges: true
        // No file is the common case, not a fault worth a line in the journal.
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.cfg = Themes.settle(JSON.parse(text() || "{}"));
            } catch (e) {
                root.cfg = Themes.settle({});
            }
        }
        onLoadFailed: root.cfg = Themes.settle({})
    }

    // FileView will not make the directory for a path that has none.
    Process {
        id: cfgDirProc
        command: ["mkdir", "-p", root.cfgDir]
        running: true
    }

    function saveCfg(next) {
        root.cfg = Themes.settle(next);
        cfgFile.setText(JSON.stringify(root.cfg, null, 2) + "\n");
    }

    // Right-click anything on the surface, click "settings" in the panel, or
    // call in from outside -- the last one is the only route that works when no
    // session is open, because the surface hides itself when there is nothing
    // to show:
    //
    //   quickshell ipc -p <this dir>/island.qml call settings toggle
    //
    // settings.sh wraps that, so a keybind is one line.
    property bool settingsOpen: false

    IpcHandler {
        target: "settings"
        function open(): void { root.settingsOpen = true; }
        function close(): void { root.settingsOpen = false; }
        function toggle(): void { root.settingsOpen = !root.settingsOpen; }
    }

    Settings {
        isl: root
        visible: root.settingsOpen
        // Closing it from the titlebar has to put the flag back, or the next
        // right-click toggles a window that is already "open" and nothing shows.
        onVisibleChanged: if (!visible) root.settingsOpen = false
    }

    // One key at a time, which is every edit the settings window makes.
    function setCfg(key, value) {
        const next = Themes.settle(root.cfg);
        next[key] = value;
        saveCfg(next);
    }

    property var sessions: []
    property string sig: ""     // what `sessions` last drew; an identical feed
                            // line then costs nothing to re-apply
    property var usage: null
    // When the usage reading arrived. The feed no longer re-sends just because
    // the reading got a second older, so the surface ages it against its own
    // clock -- the same trick the per-session timers use.
    property double usageAt: 0
    // Hover is per surface but the announce clock is not: one counter, so
    // reaching for any monitor's panel takes the request off the clock.
    property int hoverCount: 0
    readonly property bool hovered: hoverCount > 0
    // A new request opens the panel on its own, but only long enough to be seen.
    // Holding it open until answered meant a surface that cannot take your
    // keyboard sat over the screen indefinitely; after this it collapses back to
    // the bar and the pulsing lane carries the request until you deal with it.
    property bool announcing: false
    property int prevAsking: 0

    onAskingCountChanged: {
        if (askingCount > prevAsking) {
            announcing = true;
            announceTimer.restart();
            countdownAnim.restart();
        } else if (askingCount === 0) {
            announcing = false;
            announceTimer.stop();
        }
        prevAsking = askingCount;
    }

    Timer {
        id: announceTimer
        interval: root.cfg.announceMs
        onTriggered: root.announcing = false
    }

    // Drains 1 -> 0 across the announce window so the panel visibly has a clock
    // on it, rather than vanishing on you mid-read.
    property real announceFrac: 0
    NumberAnimation {
        id: countdownAnim
        target: root
        property: "announceFrac"
        from: 1; to: 0
        duration: announceTimer.interval
    }

    // Reaching for the panel takes it off the clock: from then on it is yours
    // until you leave, and the countdown has nothing left to say.
    onHoveredChanged: if (hovered) {
        announceTimer.stop();
        countdownAnim.stop();
        announcing = false;
    }

    readonly property int askingCount: {
        let n = 0;
        for (const s of sessions) if (s.pending) n++;
        return n;
    }

    // ---------------------------------------------------------------- palette
    // The default is Tokyo Night, rationed: four grounds forming one luminance
    // ramp, and hue spent only on status. Any of it can be replaced from the
    // config -- see themes.js for what each key is answering.
    readonly property var pal: Themes.palette(cfg)

    readonly property color ink:    pal.ink      // the bar, hard against the edge
    readonly property color base:   pal.base     // panel ground
    readonly property color edge:   pal.edge     // hairlines
    readonly property color muted:  pal.muted    // secondary type
    readonly property color text:   pal.text     // body
    readonly property color bright: pal.bright   // titles, emphasis

    // Hue is the scarce resource. Warm appears in exactly one situation -- a
    // session is blocked on you -- so it never has to compete for attention.
    // The other two are pushed apart on the wheel rather than kept neighbours:
    // cyan against blue was a distinction only a colour picker could see in a
    // 5px lane, so thinking moved to violet. Cyan is the machine acting on the
    // world, violet is the machine thinking, orange is you.
    readonly property color signal_: pal.signal_ // waiting on you
    readonly property color flow:    pal.flow    // producing: a tool, or text
    readonly property color mull:    pal.mull    // waiting on the model
    readonly property color fault:   pal.fault   // the turn died on an API error
    readonly property color stall:   pal.stall   // parked on the usage limit
    readonly property color quiet:   pal.quiet   // idle
    // Earned their saturation by being a two-way choice, and used nowhere else.
    readonly property color yes:     pal.yes
    readonly property color no:      pal.no

    // Two families with a job each: one for what a person meant, one for what the
    // machine is doing. Override if you do not have these; Qt substitutes a
    // default rather than failing, but the contrast is the point.
    readonly property string sans: cfg.fontSans || Quickshell.env("CA_FONT_SANS") || "Cantarell"
    readonly property string mono: cfg.fontMono || Quickshell.env("CA_FONT_MONO") || "JetBrainsMono Nerd Font"

    // ------------------------------------------------------------ lane sizing
    readonly property int laneW:   cfg.laneWidth
    readonly property int laneGap:  4
    readonly property int barPad:   6
    readonly property int barH:    cfg.barHeight
    readonly property int grabH:   Math.max(18, barH + 8)  // generous, so the bar is easy to hit

    // Which side of the screen this lives on. Everything that touches an edge
    // reads this rather than assuming the bottom.
    readonly property bool atTop: cfg.position === "top"

    // Screens to draw on. An unknown name in the list is simply not matched, so
    // a config written on a docked laptop does not break on the train.
    readonly property var monitors: {
        const want = cfg.monitors;
        if (!want || want === "all" || !want.length)
            return Quickshell.screens;
        return Quickshell.screens.filter(function (s) { return want.indexOf(s.name) >= 0; });
    }

    // Cool means the machine is busy and you can ignore it. Anything warm means
    // the session is stopped and you are the reason it stays stopped, or it
    // cannot continue on its own -- which is why there are now four warm-ish
    // states rather than one: they call for different things from you.
    function statusTone(st) {
        if (st === "waiting") return signal_;
        if (st === "error")   return fault;
        if (st === "limit")   return stall;
        if (st.indexOf("running") === 0 || st === "responding") return flow;
        if (st === "thinking" || st === "compacting" || st === "queued") return mull;
        return quiet;
    }
    // Actually producing something, as opposed to stopped or asking. Only these
    // shimmer -- a stalled lane that still looked alive would be a lie.
    function statusWorking(st) {
        return st.indexOf("running") === 0 || st === "responding"
            || st === "thinking" || st === "compacting" || st === "queued";
    }
    function shortModel(m) {
        if (!m) return "";
        return m.replace(/^claude-/, "").replace(/-\d{8}$/, "");
    }
    // Height is the primary channel: a glance down the screen edge reads the
    // shape of the bar before it reads any colour. Three steps, not five --
    // inside a 10px bar a 4px lane and a 5px lane are the same lane, so height
    // answers the only two questions worth asking from across the room: is it
    // working, and does it want me. Colour says which kind of working.
    function statusRise(st) {
        if (st === "waiting" || st === "error") return 8;
        return statusBusy(st) ? 5 : 2;
    }
    // `quiet` is tuned to sit against the near-black bar, which makes it far too
    // dark to set type in. Idle text steps up to the secondary type colour.
    function statusInk(st) {
        return statusBusy(st) ? statusTone(st) : muted;
    }
    function statusBusy(st) {
        return st !== "idle" && st !== "";
    }
    // Ticks the elapsed readouts. `since` only moves when the state does, and
    // the feed stays silent in between, so without this every timer on screen
    // would sit frozen until something happened.
    property double clock: Date.now() / 1000
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: root.clock = Date.now() / 1000
    }

    function elapsed(since) {
        if (!since) return "";
        const s = Math.max(0, Math.floor(root.clock - since));
        if (s < 60) return s + "s";
        const m = Math.floor(s / 60);
        if (m < 60) return m + "m " + ("0" + (s % 60)).slice(-2) + "s";
        return Math.floor(m / 60) + "h " + ("0" + (m % 60)).slice(-2) + "m";
    }
    function shortMs(ms) {
        if (!ms) return "";
        const s = Math.round(ms / 1000);
        return s < 60 ? s + "s" : Math.floor(s / 60) + "m " + ("0" + (s % 60)).slice(-2) + "s";
    }
    function pctTone(p) {
        return p >= 85 ? no : (p >= 60 ? signal_ : mull);
    }
    function tilde(p) {
        return (p || "").replace(Quickshell.env("HOME") || "", "~");
    }

    component LimitBar: RowLayout {
        property string label: ""
        property var d: null
        readonly property int pct: d ? d.pct : 0
        // The fill is animated through this fraction, never through its width.
        // A collapsed panel is laid out at zero width, so animating the width
        // directly meant every hover replayed the fill sweeping up from empty;
        // bound this way the width tracks the layout instantly and only a real
        // change in the number animates.
        property real frac: Math.min(1, pct / 100)
        Behavior on frac { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        visible: !!d
        spacing: 7

        Text {
            text: label
            color: root.muted
            font { family: root.mono; pixelSize: 9 }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 3
            radius: 1.5
            color: root.edge
            Rectangle {
                width: parent.width * frac
                height: parent.height
                radius: 1.5
                color: root.pctTone(pct)
                Behavior on color { ColorAnimation { duration: 250 } }
            }
        }
        Text {
            text: pct + "%"
            color: root.text
            font { family: root.mono; pixelSize: 9 }
        }
        Text {
            text: d ? d.resets_in : ""
            color: root.muted
            font { family: root.mono; pixelSize: 9 }
        }
    }

    // Verdict on the first line, the optional reason on the second. Written
    // through FileView rather than `sh -c`: the reason is free text a person
    // typed, and building a shell command string out of it would make every
    // decision an injection site. approve.sh needs no nudge -- decisions/ is
    // one of the directories the feed already watches.
    FileView { id: verdict }

    function decide(reqId, answer, reason) {
        const note = (reason || "").replace(/[\r\n]+/g, " ").trim();
        verdict.path = stateRoot + "/decisions/" + reqId;
        verdict.setText(answer + "\n" + note + "\n");
    }

    // One long-lived feed, not a poll. state.py --serve watches the state files
    // and prints a line only when something drawn changed; spawning it per frame
    // cost 48ms of CPU a time (16ms of that bare interpreter startup), which at
    // 5Hz was a quarter of a core to redraw a 10px bar.
    Process {
        id: feed
        command: [root.dir + "/state.py", "--serve"]
        running: true
        onExited: feedGuard.restart()
        stdout: SplitParser {
            onRead: function (line) {
                try {
                    const d = JSON.parse(line);
                    const ss = d.sessions || [];
                    // Assigning a fresh array destroys and rebuilds every
                    // delegate, which restarts the waiting pulse and replays
                    // each width animation from zero -- five times a second.
                    // Only swap the model in when something drawn changed.
                    let sig = "";
                    for (const x of ss)
                        sig += [x.id, x.status, x.since, x.title, x.dir, x.last,
                                x.pmode, x.turn_ms,
                                x.pending ? x.pending.id : "-"].join("") + "\n";
                    if (sig !== root.sig) {
                        root.sig = sig;
                        root.sessions = ss;
                    }
                    root.usage = d.usage || null;
                    root.usageAt = root.clock;
                } catch (e) { /* transient: a torn line */ }
            }
        }
    }

    // Clicking a session brings its terminal to the front. A claude process owns
    // no window -- the terminal above it does, and that terminal may be holding
    // several sessions in tabs -- so the walking happens in focus.sh, which has
    // the process tree and the session's own environment to work from.
    Process { id: focusProc }

    function focusSession(pid) {
        if (!pid)
            return;
        focusProc.running = false;
        focusProc.command = [root.dir + "/focus.sh", String(pid)];
        focusProc.running = true;
    }

    Timer {
        // If the feed dies the surface would silently freeze on stale state, so
        // bring it back. The delay keeps a crash-looping binary from spinning.
        id: feedGuard
        interval: 2000
        onTriggered: feed.running = true
    }

    // One surface per monitor. A single PanelWindow lands on whichever screen
    // Quickshell picked and nowhere else, which on a two-monitor desk means the
    // bar is missing from the half you are looking at. Each gets its own hover
    // state -- reaching for one panel must not open the other.
    Variants {
        model: root.monitors
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData

            property bool hovered: false
            readonly property bool expanded: hovered || root.announcing
            // What the row under the cursor wants to say. It lives at the foot of
            // the panel rather than inside the row, so nothing reflows and the
            // panel does not change height as you read down it -- a panel that
            // resizes under the pointer moves the thing you were pointing at.
            property string hint: ""
            // Hover is exclusive: a hoverEnabled MouseArea sits above the
            // hitbox's own, so entering a control inside the panel tells the
            // hitbox the pointer LEFT the bar. Every control that wants hover
            // therefore claims the surface, and the claims are COUNTED -- the
            // enter of one and the exit of the other arrive in that order, so a
            // release that simply restarted the timer collapsed the panel out
            // from under the cursor a fifth of a second later. Only the last
            // release standing starts the clock.
            property int holds: 0
            function hold() {
                holds += 1;
                collapseTimer.stop();
                win.hovered = true;
            }
            function release() {
                holds = Math.max(0, holds - 1);
                // The timer is the grace period for crossing the seam between
                // two of these areas, where neither is entered for a frame.
                if (holds === 0)
                    collapseTimer.restart();
            }

            // The count is what the announce clock watches; a monitor unplugged
            // mid-hover would otherwise leave it stuck above zero forever.
            onHoveredChanged: root.hoverCount += hovered ? 1 : -1
            Component.onDestruction: if (hovered) root.hoverCount -= 1

            // A 468px panel is right on a 1280px-wide desktop and mean on a
            // 3440px one, so both widths are a fraction of the screen inside
            // sane bounds rather than a constant that was tuned on one laptop.
            readonly property int panelW: root.cfg.panelWidth > 0
                ? root.cfg.panelWidth
                : Math.round(Math.max(400, Math.min(680, (screen ? screen.width : 1280) * 0.36)))
            readonly property int barMinW: Math.round(panelW * 0.33)
            readonly property int barW: Math.max(
                barMinW,
                root.sessions.length * root.laneW
                    + Math.max(0, root.sessions.length - 1) * root.laneGap
                    + 2 * root.barPad)

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "claude-island"
            // Keyboard focus only while something is actually asking, and only on a
            // click. Holding it permanently is how a stray keypress once produced a
            // spurious allow; OnDemand means the surface takes focus when you click
            // into the reason box and at no other time.
            WlrLayershell.keyboardFocus: (win.expanded && root.askingCount > 0)
                                         ? WlrKeyboardFocus.OnDemand
                                         : WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore

            anchors { top: root.atTop; bottom: !root.atTop; left: true; right: true }
            implicitHeight: 460
            color: "transparent"
            visible: root.sessions.length > 0

            // The mask must NOT follow the animating panel: if the pointer lands
            // outside it mid-animation the compositor delivers the event to the
            // window below, which fires onExited, collapses, and re-expands -- the
            // flicker that made the buttons unclickable. hitbox snaps to its target
            // size with no Behavior, so it always covers the panel.
            mask: Region { item: hitbox }

            Item {
                id: hitbox
                anchors.horizontalCenter: parent.horizontalCenter
                // Positioned, not anchored. Re-binding an anchor to undefined
                // does not release it once it has been established, so flipping
                // the bar to the other edge left everything anchored to BOTH
                // and stretched down the whole screen.
                y: root.atTop ? 0 : parent.height - height
                // Both dimensions jump straight to the final size, and the height
                // reads the panel's TARGET rather than its animating height. A mask
                // that tracks the animation is a mask that is smaller than what you
                // can see for a fifth of a second: reach for Allow at the right edge
                // during that window and the click lands on the window underneath,
                // which fires onExited and collapses the panel out from under you.
                width:  win.expanded ? panel.width + 8 : win.barW + 24
                height: win.expanded ? panel.targetH + 12 : root.grabH

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    onEntered: win.hold()
                    onExited:  win.release()
                }
            }

            Timer {
                id: collapseTimer
                interval: 220
                onTriggered: { win.holds = 0; win.hovered = false; }
            }

            // ---------------------------------------------- collapsed: the meter
            Rectangle {
                id: meter
                anchors.horizontalCenter: parent.horizontalCenter
                y: root.atTop ? 0 : parent.height - height
                width: win.barW
                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                height: root.barH
                // Flush with the screen edge, so only the two corners facing the
                // desktop round -- a fully rounded pill sitting on the edge reads
                // as floating. Per-corner radius needs Qt 6.7+; this is 6.11.
                topLeftRadius:     root.atTop ? 0 : 5
                topRightRadius:    root.atTop ? 0 : 5
                bottomLeftRadius:  root.atTop ? 5 : 0
                bottomRightRadius: root.atTop ? 5 : 0
                color: root.ink
                // No fade on expand. The panel is opaque, anchored to the same edge
                // and drawn after, so it simply covers this -- one surface rising,
                // rather than two things cross-dissolving into each other.

                // A rule along the inner edge rather than an outline around
                // everything: it separates the bar from the desktop without
                // drawing a box.
                Rectangle {
                    anchors { left: parent.left; right: parent.right
                              leftMargin: 5; rightMargin: 5 }
                    height: 1
                    y: root.atTop ? parent.height - height : 0
                    color: root.askingCount > 0
                           ? Qt.rgba(root.signal_.r, root.signal_.g, root.signal_.b, 0.55)
                           : root.edge
                    Behavior on color { ColorAnimation { duration: 300 } }
                }

                // Lanes share the bar's full width. Past the minimum width the bar
                // grows by a lane per session rather than subdividing what it has,
                // so opening a session never shrinks the others below laneW.
                RowLayout {
                    anchors { fill: parent; leftMargin: root.barPad; rightMargin: root.barPad }
                    spacing: root.laneGap

                    Repeater {
                        model: root.sessions
                        delegate: Item {
                            id: lane
                            required property var modelData
                            readonly property string st: modelData.status || "idle"
                            // Not readonly and not inline in the gradient: a
                            // Gradient's stops cannot animate, so the crossfade has
                            // to happen on the colour the stops are derived from.
                            property color tone: root.statusTone(st)
                            Behavior on tone { ColorAnimation { duration: 280 } }
                            readonly property bool busy: root.statusBusy(st)
                            readonly property bool asking: st === "waiting"
                            readonly property bool working: root.statusWorking(st)
                            Layout.fillWidth: true
                            Layout.preferredWidth: root.laneW
                            Layout.fillHeight: true

                            // Carries the heartbeat, so the bloom and the lane dim
                            // together instead of drifting out of step.
                            property real beat: 1.0

                            // The click target is the lane's whole column, not the
                            // few pixels it happens to be drawn at -- an idle lane
                            // is 2px tall and nobody can hit 2px on purpose.
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: function (m) {
                                    if (m.button === Qt.RightButton)
                                        root.settingsOpen = true;
                                    else
                                        root.focusSession(lane.modelData.pid);
                                }
                            }

                            // Lanes sit on the screen edge and grow upward, like a
                            // level meter -- so the bar's silhouette is the reading.
                            Rectangle {
                                id: fill
                                anchors { left: parent.left; right: parent.right }
                                y: root.atTop ? 0 : parent.height - height
                                topLeftRadius:     root.atTop ? 0 : 2
                                topRightRadius:    root.atTop ? 0 : 2
                                bottomLeftRadius:  root.atTop ? 2 : 0
                                bottomRightRadius: root.atTop ? 2 : 0
                                // The heartbeat deliberately does NOT touch this.
                                // Fading orange toward a near-black ground turns it
                                // brown however shallow the dip is -- dimming the
                                // colour was simply the wrong channel for it.

                                // Light spilling off the lane. A flat fill on a
                                // black strip reads as painted on; this reads as
                                // lit, and it is what makes a working session
                                // catch your eye without the lane getting taller.
                                // A gradient rectangle was the first attempt and
                                // looked like a smear, because a glow needs to fall
                                // off sideways too, not only upward.
                                layer.enabled: lane.busy
                                layer.effect: MultiEffect {
                                    shadowEnabled: true
                                    shadowColor: lane.tone
                                    shadowBlur: 1.0
                                    shadowVerticalOffset: root.atTop ? 2 : -2
                                    // The halo carries the beat instead. The lane
                                    // keeps its true colour and the light around it
                                    // is what swells, which reads as a beacon.
                                    shadowScale: lane.asking ? 1.00 + 0.14 * lane.beat : 1.06
                                    shadowOpacity: lane.asking ? 0.25 + 0.75 * lane.beat : 0.5
                                    Behavior on shadowOpacity {
                                        enabled: !lane.asking
                                        NumberAnimation { duration: 260 }
                                    }
                                }
                                // Brighter where it emerges: a lane lit from its own
                                // top edge, not a swatch of flat colour.
                                // Brightest where it emerges, which is the end
                                // away from the screen edge.
                                gradient: Gradient {
                                    GradientStop { position: 0.0
                                        color: root.atTop ? lane.tone : Qt.lighter(lane.tone, 1.22) }
                                    GradientStop { position: 1.0
                                        color: root.atTop ? Qt.lighter(lane.tone, 1.22) : lane.tone }
                                }

                                // Starts flat and rises once, so a session opening
                                // is a lane coming up rather than a lane appearing.
                                height: 0
                                Component.onCompleted: height = Qt.binding(function () {
                                    return root.statusRise(lane.st);
                                })
                                // A touch of overshoot: the lane arrives at its new
                                // level and settles, which reads as a meter rather
                                // than a value being set.
                                Behavior on height {
                                    NumberAnimation { duration: 340; easing.type: Easing.OutBack
                                                      easing.overshoot: 1.4 }
                                }
                            }

                                // Light travelling along the lane. The lane already
                            // says a session is working; this says it is still
                            // moving, which a static bar cannot. Only lanes that
                            // are actually producing get it -- putting it on a
                            // stalled or waiting lane would be a lie, and the
                            // waiting lane has the heartbeat to itself.
                            Item {
                                // Sits OUTSIDE the layered fill on purpose. Inside
                                // it, every frame of the sweep invalidated the layer
                                // and re-ran the glow's blur shader -- 3.5% of a
                                // core against 0.4% idle. Out here the blur stays
                                // cached and only this strip repaints.
                                anchors { left: parent.left; right: parent.right
                                          bottom: parent.bottom }
                                height: fill.height
                                clip: true
                                visible: lane.working
                                Rectangle {
                                    id: sheen
                                    width: Math.max(16, parent.width * 0.38)
                                    height: parent.height
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.38) }
                                        GradientStop { position: 1.0; color: "transparent" }
                                    }
                                    SequentialAnimation on x {
                                        running: lane.working
                                        loops: Animation.Infinite
                                        NumberAnimation {
                                            from: -sheen.width
                                            to: lane.width + sheen.width
                                            duration: 1400
                                            easing.type: Easing.InOutSine
                                        }
                                        // A sweep with no gap reads as a progress
                                        // bar; the rest is what makes it a pulse of
                                        // light. The gap is also most of the cost
                                        // control -- the surface only repaints
                                        // while the sweep is moving, so the duty
                                        // cycle is the CPU bill. 1.4s on, 3s off.
                                        PauseAnimation { duration: 3000 }
                                    }
                                }
                            }

                            // Two quick beats and a rest -- a pulse, not a fade.
                            // A sine breath reads as "loading"; this reads as
                            // something asking for you, which is what it is.
                            SequentialAnimation on beat {
                                running: lane.asking
                                loops: Animation.Infinite
                                alwaysRunToEnd: true
                                onStopped: lane.beat = 1.0
                                NumberAnimation { to: 0.15; duration: 170; easing.type: Easing.OutQuad }
                                NumberAnimation { to: 1.0;  duration: 170; easing.type: Easing.InQuad }
                                NumberAnimation { to: 0.15; duration: 170; easing.type: Easing.OutQuad }
                                NumberAnimation { to: 1.0;  duration: 200; easing.type: Easing.InQuad }
                                PauseAnimation  { duration: 820 }
                            }
                        }
                    }
                }
            }

            // ---------------------------------------------- expanded: the panel
            Rectangle {
                id: panel
                anchors.horizontalCenter: parent.horizontalCenter
                y: root.atTop ? 0 : parent.height - height
                width: win.panelW
                readonly property int targetH: body.implicitHeight + 20
                height: win.expanded ? targetH : 0
                topLeftRadius:     root.atTop ? 0 : 12
                topRightRadius:    root.atTop ? 0 : 12
                bottomLeftRadius:  root.atTop ? 12 : 0
                bottomRightRadius: root.atTop ? 12 : 0
                clip: true

                // Lit from the edge it emerges from, like the lanes. A single flat
                // slab of #1a1b26 is what made the panel read as a screenshot of a
                // panel.
                gradient: Gradient {
                    GradientStop { position: 0.0
                        color: root.atTop ? root.ink : Qt.lighter(root.base, 1.30) }
                    GradientStop { position: 0.5; color: root.base }
                    GradientStop { position: 1.0
                        color: root.atTop ? Qt.lighter(root.base, 1.30) : root.ink }
                }

                visible: height > 0
                // No opacity fade. The panel rises out of the bar and the bar is
                // still there underneath; fading it in as well made two surfaces
                // out of what should read as one.
                Behavior on height {
                    NumberAnimation { duration: 260; easing.type: Easing.OutBack
                                      easing.overshoot: 0.9 }
                }

                Rectangle {
                    anchors { left: parent.left; right: parent.right }
                    height: 1
                    y: root.atTop ? parent.height - height : 0
                    color: root.askingCount > 0
                           ? Qt.rgba(root.signal_.r, root.signal_.g, root.signal_.b, 0.6)
                           : Qt.rgba(root.bright.r, root.bright.g, root.bright.b, 0.14)
                    Behavior on color { ColorAnimation { duration: 300 } }
                }

                // The clock, riding the panel's own inner edge rather than taking
                // up room inside it. Only visible while the panel is showing itself
                // unasked, which is the only time it is about to leave unasked.
                Rectangle {
                    anchors.left: parent.left
                    height: 2
                    y: root.atTop ? parent.height - height : 0
                    width: parent.width * root.announceFrac
                    visible: root.announcing
                    color: root.signal_
                }

                ColumnLayout {
                    id: body
                    anchors { left: parent.left; right: parent.right; top: parent.top
                              topMargin: 11; leftMargin: 0; rightMargin: 0 }
                    spacing: 0

                    Repeater {
                        model: root.sessions
                        delegate: ColumnLayout {
                            id: row
                            required property var modelData
                            required property int index
                            readonly property var pend: modelData.pending
                            readonly property string st: modelData.status || "idle"
                            // Set on click so the row can acknowledge the answer.
                            // The feed removes the request about 250ms later, which
                            // is just enough for the confirmation to land.
                            property string decided: ""
                            Layout.fillWidth: true
                            spacing: 0

                            // One orchestrated reveal: rows come up in sequence
                            // rather than the whole panel arriving at once, which
                            // gives the eye an order to read them in.
                            opacity: win.expanded ? 1 : 0
                            Behavior on opacity {
                                SequentialAnimation {
                                    PauseAnimation { duration: row.index * 45 }
                                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                                }
                            }
                            transform: Translate {
                                y: win.expanded ? 0 : (root.atTop ? -7 : 7)
                                Behavior on y {
                                    SequentialAnimation {
                                        PauseAnimation { duration: row.index * 45 }
                                        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                                    }
                                }
                            }

                            Rectangle {
                                visible: index > 0
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                Layout.leftMargin: 14
                                Layout.rightMargin: 14
                                Layout.topMargin: 3
                                Layout.bottomMargin: 3
                                color: root.edge
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: rowCol.implicitHeight + 18
                                // Only the blocked session gets a ground, and it
                                // is warm rather than a neutral lift -- the same
                                // rationed hue as the lane, so the row that wants
                                // you is the one warm thing on the panel.
                                // On a click it takes the answer's colour for a
                                // moment: you should see the decision land, not
                                // just watch the row disappear a beat later.
                                color: {
                                    if (row.decided === "allow")
                                        return Qt.rgba(root.yes.r, root.yes.g, root.yes.b, 0.22);
                                    if (row.decided === "deny")
                                        return Qt.rgba(root.no.r, root.no.g, root.no.b, 0.22);
                                    if (pend)
                                        return Qt.rgba(root.signal_.r, root.signal_.g, root.signal_.b, 0.09);
                                    // A lift rather than a tint: the row you are
                                    // about to click should stand out without
                                    // borrowing a colour that already means
                                    // something on this panel.
                                    return rowMa.containsMouse ? Qt.rgba(1, 1, 1, 0.045)
                                                               : "transparent";
                                }
                                Behavior on color { ColorAnimation { duration: 130 } }

                                // The row's own lane colour, on the edge the bar
                                // would be on -- so a row under the cursor is tied
                                // back to the lane it came from.
                                Rectangle {
                                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                    width: 2
                                    color: root.statusTone(row.st)
                                    opacity: rowMa.containsMouse ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 140 } }
                                    Behavior on color { ColorAnimation { duration: 280 } }
                                }

                                // Declared before the content so it sits underneath
                                // it: the buttons and the reason box take their own
                                // clicks, and everything else falls through to here.
                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onEntered: {
                                        win.hold();
                                        win.hint = row.modelData.pid
                                            ? "Click to focus " + root.tilde(row.modelData.cwd)
                                            : root.tilde(row.modelData.cwd);
                                    }
                                    onExited: {
                                        win.release();
                                        // Only clear what is still ours: moving to
                                        // the next row sets the new hint first.
                                        if (win.hint.indexOf(root.tilde(row.modelData.cwd)) >= 0)
                                            win.hint = "";
                                    }
                                    onClicked: function (m) {
                                        if (m.button === Qt.RightButton)
                                            root.settingsOpen = true;
                                        else
                                            root.focusSession(row.modelData.pid);
                                    }
                                }

                                ColumnLayout {
                                    id: rowCol
                                    anchors { left: parent.left; right: parent.right; top: parent.top
                                              leftMargin: 14; rightMargin: 14; topMargin: 9 }
                                    spacing: 3

                                    // Title and location belong together -- which
                                    // project this is answers "whose session?"
                                    // faster than the name alone.
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text {
                                            text: modelData.title
                                            color: root.bright
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                            font { family: root.sans; pixelSize: 13; weight: Font.DemiBold }
                                        }
                                        Text {
                                            text: modelData.dir
                                            color: root.muted
                                            font { family: root.mono; pixelSize: 10 }
                                        }
                                    }

                                    // One timer per line, and the live one carries
                                    // the status it belongs to. Two bare durations
                                    // side by side told you nothing about either.
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text {
                                            // A waiting with no request behind it is
                                            // Claude Code prompting in its own
                                            // terminal -- the island was told it is
                                            // happening but has nothing to answer
                                            // with, and showing a bare "waiting"
                                            // with no buttons reads as a dead alert.
                                            text: pend ? ("wants " + pend.tool)
                                                       : (st === "waiting" ? "waiting in terminal" : st)
                                            color: root.statusInk(st)
                                            Behavior on color { ColorAnimation { duration: 280 } }
                                            font { family: root.mono; pixelSize: 10
                                                   weight: root.statusBusy(st) ? Font.Medium : Font.Normal }
                                        }
                                        Text {
                                            text: root.elapsed(modelData.since)
                                            color: root.statusBusy(st) ? root.text : root.muted
                                            font { family: root.mono; pixelSize: 10 }
                                        }
                                        Item { Layout.fillWidth: true }
                                        Text {
                                            visible: modelData.pmode !== ""
                                            text: modelData.pmode
                                            color: modelData.pmode === "bypassPermissions" ? root.no : root.muted
                                            font { family: root.mono; pixelSize: 9 }
                                        }
                                        // A session that has fanned out is doing
                                        // more than its own status suggests, and
                                        // that is worth seeing before you judge how
                                        // long it has been busy.
                                        Text {
                                            visible: modelData.agents > 0
                                            text: modelData.agents + (modelData.agents === 1 ? " agent" : " agents")
                                            color: root.flow
                                            font { family: root.mono; pixelSize: 9 }
                                        }
                                        Text {
                                            visible: modelData.model !== ""
                                            text: root.shortModel(modelData.model)
                                            color: root.muted
                                            font { family: root.mono; pixelSize: 9 }
                                        }
                                        Text {
                                            visible: modelData.turn_ms > 0 && !pend
                                            text: "last turn " + root.shortMs(modelData.turn_ms)
                                            color: root.muted
                                            font { family: root.mono; pixelSize: 9 }
                                        }
                                    }

                                    Text {
                                        visible: !pend && modelData.last !== ""
                                        Layout.fillWidth: true
                                        Layout.topMargin: 4
                                        text: modelData.last
                                        // Light rather than dim: the prompt is the
                                        // one line you actually read, so it keeps
                                        // its contrast and gives up weight instead.
                                        color: root.text
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                        font { family: root.sans; pixelSize: 11; weight: Font.Light }
                                    }

                                    Text {
                                        visible: !!pend
                                        Layout.fillWidth: true
                                        Layout.topMargin: 4
                                        text: pend ? pend.body : ""
                                        color: root.text
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 4
                                        elide: Text.ElideRight
                                        font { family: root.mono; pixelSize: 11 }
                                    }

                                    Text {
                                        // Says where the answer has to go, so you are
                                        // not hunting the panel for a button.
                                        visible: !pend && st === "waiting"
                                        Layout.fillWidth: true
                                        Layout.topMargin: 3
                                        text: "Answer it in the terminal — this prompt did not come through the island."
                                        color: root.signal_
                                        wrapMode: Text.Wrap
                                        font { family: root.sans; pixelSize: 11 }
                                    }

                                    // Optional note back to Claude. On a deny this
                                    // is the useful half -- "not on prod, use the
                                    // stage profile" tells it what to do instead,
                                    // where a bare refusal just makes it guess.
                                    Rectangle {
                                        visible: !!pend
                                        Layout.fillWidth: true
                                        Layout.topMargin: 7
                                        implicitHeight: 27
                                        radius: 6
                                        color: Qt.rgba(0, 0, 0, 0.22)
                                        border.width: 1
                                        border.color: why.activeFocus
                                            ? Qt.rgba(root.signal_.r, root.signal_.g, root.signal_.b, 0.55)
                                            : root.edge
                                        Behavior on border.color { ColorAnimation { duration: 120 } }

                                        TextInput {
                                            id: why
                                            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: root.text
                                            selectionColor: Qt.rgba(root.signal_.r, root.signal_.g, root.signal_.b, 0.35)
                                            selectedTextColor: root.bright
                                            selectByMouse: true
                                            clip: true
                                            maximumLength: 400
                                            font { family: root.sans; pixelSize: 11 }
                                            // Deliberately does nothing on Enter.
                                            // Two buttons means Enter has no
                                            // unambiguous target, and guessing one
                                            // is how a keystroke becomes an approval.
                                            Keys.onEscapePressed: focus = false
                                        }
                                        Text {
                                            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                            verticalAlignment: Text.AlignVCenter
                                            visible: why.text === "" && !why.activeFocus
                                            text: "Reason (optional) — sent back to Claude"
                                            color: root.muted
                                            font { family: root.sans; pixelSize: 11 }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.IBeamCursor
                                            acceptedButtons: Qt.LeftButton
                                            onClicked: function (m) { why.forceActiveFocus(); }
                                            z: -1
                                        }
                                    }

                                    RowLayout {
                                        visible: !!pend
                                        Layout.fillWidth: true
                                        Layout.topMargin: 6
                                        spacing: 8
                                        Text {
                                            text: root.tilde(modelData.cwd)
                                            color: root.muted
                                            elide: Text.ElideLeft
                                            Layout.fillWidth: true
                                            font { family: root.mono; pixelSize: 9 }
                                        }
                                        Repeater {
                                            model: [
                                                { label: "Deny",  answer: "deny",  col: root.no },
                                                { label: "Allow", answer: "allow", col: root.yes }
                                            ]
                                            delegate: Rectangle {
                                                id: btn
                                                required property var modelData
                                                readonly property bool chosen: row.decided === modelData.answer
                                                readonly property bool dropped: row.decided !== "" && !chosen
                                                radius: 6
                                                implicitWidth: bt.implicitWidth + 24
                                                implicitHeight: 25
                                                color: Qt.rgba(modelData.col.r, modelData.col.g, modelData.col.b,
                                                               chosen ? 0.9 : (bma.containsMouse ? 0.22 : 0.10))
                                                border.width: 1
                                                border.color: Qt.rgba(modelData.col.r, modelData.col.g, modelData.col.b,
                                                                      chosen ? 1.0 : (bma.containsMouse ? 0.7 : 0.35))
                                                // The button not taken steps back
                                                // rather than vanishing, so the one
                                                // you picked is unambiguous.
                                                opacity: dropped ? 0.25 : 1
                                                scale: chosen ? 1.06 : (bma.containsMouse ? 1.03 : 1.0)
                                                Behavior on color        { ColorAnimation  { duration: 120 } }
                                                Behavior on border.color { ColorAnimation  { duration: 120 } }
                                                Behavior on opacity      { NumberAnimation { duration: 120 } }
                                                Behavior on scale {
                                                    NumberAnimation { duration: 150; easing.type: Easing.OutBack
                                                                      easing.overshoot: 2.5 }
                                                }
                                                Text {
                                                    id: bt
                                                    anchors.centerIn: parent
                                                    text: modelData.label
                                                    // Fills solid on the answer, so
                                                    // the label flips to read against
                                                    // it rather than disappearing.
                                                    color: btn.chosen ? root.ink : modelData.col
                                                    Behavior on color { ColorAnimation { duration: 120 } }
                                                    font { family: root.sans; pixelSize: 12; weight: Font.DemiBold }
                                                }
                                                MouseArea {
                                                    id: bma
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    enabled: row.decided === ""
                                                    onEntered: win.hold()
                                                    onExited:  win.release()
                                                    onClicked: {
                                                        row.decided = modelData.answer;
                                                        root.decide(pend.id, modelData.answer, why.text);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ------------------------------------------------- limits
                    Rectangle {
                        visible: !!root.usage
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        Layout.topMargin: 8
                        color: root.edge
                    }

                    RowLayout {
                        visible: !!root.usage
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        Layout.topMargin: 9
                        Layout.bottomMargin: 1
                        spacing: 18

                        LimitBar {
                            Layout.fillWidth: true
                            label: "5h"
                            d: root.usage ? root.usage.session : null
                        }
                        LimitBar {
                            Layout.fillWidth: true
                            label: "7d"
                            d: root.usage ? root.usage.week : null
                        }
                    }

                    Text {
                        // The cache only refreshes while a session renders its status
                        // line, so say so rather than showing stale numbers as live.
                        readonly property double staleFor:
                            root.usage ? root.usage.age + Math.max(0, root.clock - root.usageAt) : 0
                        visible: !!root.usage && staleFor > 120
                        Layout.leftMargin: 14
                        Layout.topMargin: 4
                        text: "limits last read " + Math.round(staleFor / 60) + "m ago"
                        color: root.muted
                        font { family: root.sans; pixelSize: 10 }
                    }

                    // The way in. Right-click works anywhere on the surface, but
                    // a gesture nobody can see is a gesture nobody finds, so the
                    // panel says so once it is open.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        Layout.topMargin: 9
                        Layout.bottomMargin: 1
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: win.hint
                            color: root.muted
                            elide: Text.ElideMiddle
                            opacity: win.hint === "" ? 0 : 1
                            Behavior on opacity { NumberAnimation { duration: 140 } }
                            font { family: root.sans; pixelSize: 10 }
                        }

                        Text {
                            id: gear
                            text: "settings"
                            color: gm.containsMouse ? root.bright : root.muted
                            Behavior on color { ColorAnimation { duration: 120 } }
                            font { family: root.sans; pixelSize: 10
                                   underline: gm.containsMouse }
                            MouseArea {
                                id: gm
                                anchors { fill: parent; margins: -6 }
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: win.hold()
                                onExited:  win.release()
                                onClicked: root.settingsOpen = true
                            }
                        }
                    }
                }
            }
        }
    }
}
