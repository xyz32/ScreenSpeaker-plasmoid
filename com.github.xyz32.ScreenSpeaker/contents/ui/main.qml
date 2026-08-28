import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Which channel this instance visualizes (from config): 0=Left 1=Right
    readonly property int channel: Plasmoid.configuration.channel

    // Room light horizontal direction, mirrored per channel so a placed L/R
    // pair is lit symmetrically. Left speaker (0) is lit from the RIGHT (light
    // toward the pair's center); Right speaker (1) from the LEFT.
    readonly property bool lightFromLeft: root.channel !== 0

    // Audio levels for THIS instance: [Tweeter, Mid, Woofer] normalized 0.0-1.0
    // audioLevels = per-band ENERGY (drives vibration amplitude).
    // audioActivity = per-band ACTIVITY, fraction of active bins (drives rate).
    property var audioLevels: [0.0, 0.0, 0.0]
    property var audioActivity: [0.0, 0.0, 0.0]

    readonly property real originalWidth: 300
    readonly property real originalHeight: 800

    // Shared-daemon state. All instances use a FIXED data path (no PID suffix)
    // so the first instance launches the daemon and the rest discover the same
    // one via its singleton lock. One parec + one FFT serves every speaker.
    property string runtimeDir: ""
    property string dataPath: ""
    property string alivePath: ""
    property string portPath: ""
    property string logPath: ""
    property string spectrumUrl: ""
    property string daemonPath: Qt.resolvedUrl("../code/speaker-daemon.py").toString().replace("file://", "")
    property string launcherPath: Qt.resolvedUrl("../code/launch-daemon.sh").toString().replace("file://", "")
    property string status: "init"

    preferredRepresentation: fullRepresentation

    // No applet frame/background — the speaker cabinet is the whole visual.
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    // --- Shell command runner ---
    P5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []

        signal commandFinished(string source, string stdout, string stderr)

        onNewData: (sourceName, data) => {
            commandFinished(sourceName, data["stdout"] || "", data["stderr"] || "")
            disconnectSource(sourceName)
        }

        function run(cmd) {
            connectSource(cmd)
        }
    }

    // --- HTTP polling (30fps, in-process, no subprocess overhead) ---
    property var pollXhr: null

    function pollOnce() {
        if (!root.spectrumUrl) return
        if (pollXhr && pollXhr.readyState !== 0 && pollXhr.readyState !== 4) return

        var xhr = new XMLHttpRequest()
        pollXhr = xhr
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            if (xhr.status !== 200) {
                root.spectrumUrl = ""
                portRetry.start()
                return
            }
            var txt = (xhr.responseText || "").trim()
            if (!txt) return

            // Daemon format (12 floats): 6 energies then 6 activities:
            //   Le_bass Le_mid Le_treble Re_bass Re_mid Re_treble
            //   La_bass La_mid La_treble Ra_bass Ra_mid Ra_treble
            var parts = txt.split(/\s+/)
            if (parts.length < 12) return

            // Channel offset into each 6-value group: Left = 0, Right = 3.
            var o = (root.channel === 0) ? 0 : 3
            var eBass = parseFloat(parts[o])     || 0
            var eMid  = parseFloat(parts[o + 1]) || 0
            var eHigh = parseFloat(parts[o + 2]) || 0
            var aBass = parseFloat(parts[6 + o])     || 0
            var aMid  = parseFloat(parts[6 + o + 1]) || 0
            var aHigh = parseFloat(parts[6 + o + 2]) || 0

            // Visual order is [Tweeter, Mid, Woofer] = [high, mid, bass]
            root.audioLevels   = [eHigh, eMid, eBass]
            root.audioActivity = [aHigh, aMid, aBass]
            if (root.status !== "running") root.status = "running"
        }
        xhr.open("GET", root.spectrumUrl)
        xhr.send()
    }

    Timer {
        id: pollTick
        interval: 16  // ~60fps
        running: root.spectrumUrl !== ""
        repeat: true
        onTriggered: root.pollOnce()
    }

    // --- Vibration driver: driven damped spring per band ---
    // A real cone oscillates BOTH WAYS around rest. We model each band as a
    // mass on a spring: audio energy applies a force impulse that kicks the
    // cone, the spring pulls it back toward rest, and damping bleeds the
    // motion so it rings down. `vibe` (displacement) therefore swings positive
    // AND negative around 0 — pushed out then pulled in — at the spring's own
    // fast natural frequency, which reads as physical oscillation, not a slow
    // sway. Louder transients kick harder (bigger swing); silence -> rest.
    property var vibe: [0.0, 0.0, 0.0]      // displacement from rest, ~[-1, 1]
    property var vibeVel: [0.0, 0.0, 0.0]   // velocity
    property var prevEnergy: [0.0, 0.0, 0.0]

    Timer {
        id: vibeTimer
        interval: 16          // ~60fps
        running: root.status === "running"
        repeat: true
        onTriggered: {
            var pos = root.vibe.slice()
            var vel = root.vibeVel.slice()
            var pe = root.prevEnergy.slice()

            // Per-band spring constants. Higher stiffness = faster oscillation;
            // treble rings fastest, bass slowest — like real driver mass.
            var stiffness = [0.55, 0.40, 0.28]   // natural frequency
            var damping   = [0.30, 0.26, 0.22]   // ring-down rate

            for (var i = 0; i < 3; i++) {
                var energy = root.audioLevels[i]
                // Force = spring restoring pull toward 0, minus damping, plus
                // a drive from the audio. The RISE in energy (onset) delivers
                // an impulse kick; steady energy sustains a gentle push.
                var onset = Math.max(0, energy - pe[i])
                var drive = onset * 2.0 + energy * 0.25
                var accel = -stiffness[i] * pos[i] - damping[i] * vel[i] + drive
                vel[i] += accel
                pos[i] += vel[i]
                // Clamp for stability and to keep the swing inside the surround.
                if (pos[i] > 1.0) { pos[i] = 1.0; if (vel[i] > 0) vel[i] = 0 }
                else if (pos[i] < -1.0) { pos[i] = -1.0; if (vel[i] < 0) vel[i] = 0 }
                pe[i] = energy
            }
            root.vibe = pos
            root.vibeVel = vel
            root.prevEnergy = pe
        }
    }

    Timer {
        id: portRetry
        interval: 250
        repeat: false
        onTriggered: root.discoverPort()
    }

    // --- Daemon lifecycle (shared across all instances) ---

    function discoverPort() {
        if (!root.portPath) return
        var cmd = "cat '" + root.portPath + "' 2>/dev/null"
        var handler = function(source, stdout, stderr) {
            if (source !== cmd) return
            shell.commandFinished.disconnect(handler)
            var p = stdout.trim()
            if (!p) {
                portRetry.start()
                return
            }
            root.spectrumUrl = "http://127.0.0.1:" + p + "/"
        }
        shell.commandFinished.connect(handler)
        shell.run(cmd)
    }

    function resolveRuntimeDir() {
        var cmd = "sh -c 'printf %s \"${XDG_RUNTIME_DIR:-/tmp}\"'"
        var handler = function(source, stdout, stderr) {
            if (source !== cmd) return
            shell.commandFinished.disconnect(handler)
            var dir = stdout.trim() || "/tmp"
            root.runtimeDir = dir
            // FIXED path shared by every instance (no PID) so the daemon is a singleton.
            root.dataPath = dir + "/plasma-speaker.dat"
            root.alivePath = root.dataPath + ".alive"
            root.portPath = root.dataPath + ".port"
            root.logPath = dir + "/plasma-speaker.log"
            startDaemon()
        }
        shell.commandFinished.connect(handler)
        shell.run(cmd)
    }

    function getDefaultDevice() {
        var cmd = "sh -c 'pactl get-default-sink 2>/dev/null'"
        var handler = function(source, stdout, stderr) {
            if (source !== cmd) return
            shell.commandFinished.disconnect(handler)
            var sink = stdout.trim()
            if (sink) {
                launchWithDevice(sink + ".monitor")
            } else {
                var cmd2 = "sh -c \"pactl list short sources 2>/dev/null | grep monitor | head -1 | awk '{print \\$2}'\""
                var handler2 = function(source2, stdout2, stderr2) {
                    if (source2 !== cmd2) return
                    shell.commandFinished.disconnect(handler2)
                    var dev = stdout2.trim()
                    if (dev) {
                        launchWithDevice(dev)
                    }
                }
                shell.commandFinished.connect(handler2)
                shell.run(cmd2)
            }
        }
        shell.commandFinished.connect(handler)
        shell.run(cmd)
    }

    function startDaemon() {
        if (!dataPath) return
        root.status = "starting"
        root.spectrumUrl = ""
        // Every instance attempts a launch; the daemon's singleton lock makes
        // all but the first a harmless no-op. Then everyone discovers the port.
        getDefaultDevice()
    }

    function launchWithDevice(device) {
        var cmd = "/bin/bash '" + launcherPath + "' '" + logPath + "' '" + daemonPath + "' '" + device + "' '" + dataPath + "'"
        shell.run(cmd)
        portRetry.start()
    }

    function touchAlive() {
        if (!alivePath) return
        shell.run("touch '" + alivePath + "'")
    }

    Component.onCompleted: resolveRuntimeDir()

    // NOTE: no daemon kill on destruction — other instances may still need it.
    // The daemon self-exits when the shared .alive heartbeat goes stale (30s),
    // which happens only once every instance is gone.

    // Heartbeat: keep the shared daemon alive while at least one instance lives
    Timer {
        id: heartbeat
        interval: 5000
        running: root.alivePath !== ""
        repeat: true
        onTriggered: root.touchAlive()
    }

    // Watchdog: re-discover / relaunch if the stream drops
    Timer {
        interval: 5000
        running: root.dataPath !== ""
        repeat: true
        onTriggered: {
            if (root.status === "running" && root.spectrumUrl === "") {
                root.startDaemon()
            }
        }
    }

    // --- Representations ---
    // Reusable center-out glow cone: a radial gradient (bright core -> dark
    // Reusable conical self-shadow: a real speaker cone is a funnel sloping
    // from the rim down to the central dust cap. Ambient ROOM light hitting
    // that slope lights the near side and shadows the far side; because the
    // surface is conical the shadow reads as a curved band. We model it as an
    // OFF-CENTER radial gradient inside the circular cone: bright lobe biased
    // toward the light (upper-left), fading to shadow on the opposite side.
    // Subtle, and it breathes a little with `level` as the cone pumps toward
    // the light.
    Component {
        id: shadowConeComponent

        Shape {
            id: cone
            anchors.fill: parent
            property real level: 0.0        // 0..1 audio level for this driver
            // Convex parts (cap, surround: inverted=true) catch the light on
            // the face TOWARD the source — highlight at the light corner
            // (top + light side). The concave cone (inverted=false) is a dish:
            // the same overhead light lands on the slope FACING AWAY, so its
            // highlight sits on the OPPOSITE side (bottom + far side). Both
            // share one light source; only the surface curvature flips which
            // slope is lit.
            property bool inverted: false
            // Horizontal light direction. true = light from the LEFT; false =
            // from the right. Set per channel by the caller so an L/R pair is
            // lit symmetrically.
            property bool lightFromLeft: true
            preferredRendererType: Shape.CurveRenderer
            antialiasing: true

            // Light corner: top + the lit horizontal side.
            readonly property real lightX: lightFromLeft ? 0.32 : 0.68
            readonly property real lightY: 0.28
            // Convex keeps the highlight at the light corner; concave flips it
            // to the opposite corner (mirror through center).
            readonly property real litX: inverted ? lightX : (1.0 - lightX)
            readonly property real litY: inverted ? lightY : (1.0 - lightY)

            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: cone.width * cone.litX
                    centerY: cone.height * cone.litY
                    focalX: cone.width * cone.litX
                    focalY: cone.height * cone.litY
                    centerRadius: cone.width * 0.95
                    // Highlight on the lit slope -> neutral -> shadow on the
                    // far slope. White/black over the cone's own colour.
                    GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.22 + cone.level * 0.20) }
                    GradientStop { position: 0.35; color: Qt.rgba(1, 1, 1, 0.04) }
                    GradientStop { position: 0.62; color: Qt.rgba(0, 0, 0, 0.10) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
                }
                PathAngleArc {
                    centerX: cone.width / 2
                    centerY: cone.height / 2
                    radiusX: cone.width / 2
                    radiusY: cone.height / 2
                    startAngle: 0
                    sweepAngle: 360
                }
            }

            Behavior on level { NumberAnimation { duration: 60; easing.type: Easing.OutQuad } }
        }
    }

    // Reusable mounting screw: a metallic disc with a slot head, a bright edge
    // toward the room light (upper-left) and a soft cast shadow on the far
    // side. `size` is set by the caller; corner placement is done at the site.
    Component {
        id: screwComponent

        Item {
            id: screw
            property real size: 10
            property bool lightFromLeft: true
            width: size
            height: size

            // Soft cast shadow, offset away from the light.
            Rectangle {
                width: parent.width
                height: parent.height
                radius: width / 2
                color: "#000000"
                opacity: 0.35
                x: screw.lightFromLeft ? parent.width * 0.12 : -parent.width * 0.12
                y: parent.height * 0.14
            }

            // Screw body — metallic grey with a subtle radial sheen.
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "#3a3a3c"
                border.color: "#1c1c1e"
                border.width: Math.max(1, parent.width * 0.06)

                // Lit edge highlight toward the light source.
                Rectangle {
                    width: parent.width * 0.5
                    height: width
                    radius: width / 2
                    color: "#8a8a8e"
                    opacity: 0.55
                    x: screw.lightFromLeft ? parent.width * 0.12 : parent.width * 0.38
                    y: parent.height * 0.12
                }

                // Slotted head (Phillips-ish cross): two thin dark bars.
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.62
                    height: Math.max(1, parent.width * 0.12)
                    radius: height / 2
                    color: "#141416"
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.max(1, parent.width * 0.12)
                    height: parent.height * 0.62
                    radius: width / 2
                    color: "#141416"
                }
            }
        }
    }

    compactRepresentation: Kirigami.Icon {
        source: "audio-speakers"
    }

    // The speaker renders directly in the applet body — Plasma manages its
    // placement and persists it per-instance natively (no floating windows).
    fullRepresentation: Item {
        id: fullRep

        readonly property real aspect: root.originalWidth / root.originalHeight  // 300/800
        // Desired size from config; width derived from the fixed aspect ratio.
        readonly property int cfgHeight: Plasmoid.configuration.speakerHeight
        readonly property int cfgWidth: Math.round(cfgHeight * aspect)

        implicitWidth: cfgWidth
        implicitHeight: cfgHeight
        Layout.minimumWidth: Kirigami.Units.gridUnit
        Layout.minimumHeight: Kirigami.Units.gridUnit / aspect
        Layout.preferredWidth: cfgWidth
        Layout.preferredHeight: cfgHeight

        // Bidirectional size <-> config sync.
        // The configured size is both a geometry request to Plasma and a hard
        // cap on fitBox below. Plasma may retain an applet's previously larger
        // allocation, so the visual cap is what makes decreases deterministic.
        // Manual desktop resizes still update speakerHeight after settling.
        property bool suppressWriteBack: false

        onCfgHeightChanged: {
            suppressWriteBack = true
            settleTimer.restart()
        }

        // Avoid writing stale applet geometry over a config-driven change.
        Timer {
            id: settleTimer
            interval: 400
            repeat: false
            onTriggered: fullRep.suppressWriteBack = false
        }

        function pushSizeToConfig() {
            if (suppressWriteBack) return
            var h = Math.round(height)
            if (h > 0 && Math.abs(h - cfgHeight) > 2) {
                Plasmoid.configuration.speakerHeight = h
            }
        }

        onHeightChanged: {
            if (suppressWriteBack && Math.abs(Math.round(height) - cfgHeight) <= 2) {
                suppressWriteBack = false
                settleTimer.stop()
            }
            sizeWriteTimer.restart()
        }

        // Debounce: a drag fires many height changes; only persist once it settles.
        Timer {
            id: sizeWriteTimer
            interval: 250
            repeat: false
            onTriggered: fullRep.pushSizeToConfig()
        }

        // Channel badge letter: L / R
        readonly property string channelLabel: root.channel === 0 ? "L" : "R"

        // Preserve 300:800 and center the speaker. The available applet area
        // limits growth, while cfgHeight limits config-driven shrink even when
        // Plasma keeps a larger allocation around the applet.
        Item {
            id: fitBox
            anchors.centerIn: parent
            readonly property real parentAspect: parent.width / parent.height
            readonly property real availableHeight: parentAspect > fullRep.aspect
                                                    ? parent.height
                                                    : parent.width / fullRep.aspect
            height: Math.min(availableHeight, fullRep.cfgHeight)
            width: height * fullRep.aspect

            // Main Speaker Cabinet
            Rectangle {
                id: cabinet
                anchors.fill: parent
                color: "#1a1816"
                border.color: "#0d0c0b"
                border.width: 4
                radius: 4

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.color: "#000000"
                    border.width: 8
                    opacity: 0.6
                    radius: 4
                }

                Column {
                anchors.centerIn: parent
                width: parent.width * 0.85
                height: parent.height * 0.9
                spacing: parent.height * 0.03

                // --- 1. TWEETER (Highs) ---
                Item {
                    width: parent.width * 0.45
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        anchors.fill: parent
                        color: "#2b2b2b"
                        border.color: "#4a4a4a"
                        border.width: 2
                        radius: 4
                    }

                    // Four corner mounting screws on the enclosing housing.
                    Repeater {
                        model: 4
                        Loader {
                            sourceComponent: screwComponent
                            readonly property real sz: parent.width * 0.10
                            readonly property real inset: parent.width * 0.06
                            width: sz; height: sz
                            x: (index % 2 === 0) ? inset : parent.width - sz - inset
                            y: (index < 2) ? inset : parent.height - sz - inset
                            onLoaded: {
                                item.size = sz
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                            }
                        }
                    }

                    // Surround (rim): bonded to the case at its OUTER edge, so
                    // it does NOT move. Convex half-torus -> shaded like the
                    // dust cap (inverted), same light direction. The moving
                    // cone sits inside it.
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.72
                        height: width
                        radius: width / 2
                        color: "#1d1d1d"
                        border.color: "#323232"
                        border.width: 1

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.inverted = true
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                item.level = Qt.binding(function() { return root.audioLevels[0] })
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.65
                        height: width
                        radius: width / 2
                        color: "#2e2e2e"
                        border.color: "#4a4a4a"
                        border.width: 2
                        scale: 1.0 + root.vibe[0] * 0.03

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                item.level = Qt.binding(function() { return root.audioLevels[0] })
                            }
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width * 0.4
                            height: width
                            radius: width / 2
                            color: "#050505"

                            Loader {
                                anchors.fill: parent
                                sourceComponent: shadowConeComponent
                                onLoaded: {
                                    item.inverted = true
                                    item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                    item.level = Qt.binding(function() { return root.audioLevels[0] })
                                }
                            }
                        }
                    }
                }

                // --- 2. MIDRANGE (Mids) ---
                Item {
                    width: parent.width * 0.65
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        anchors.fill: parent
                        color: "#252525"
                        border.color: "#4a4a4a"
                        border.width: 3
                        radius: 6
                    }

                    // Four corner mounting screws on the enclosing housing.
                    Repeater {
                        model: 4
                        Loader {
                            sourceComponent: screwComponent
                            readonly property real sz: parent.width * 0.09
                            readonly property real inset: parent.width * 0.055
                            width: sz; height: sz
                            x: (index % 2 === 0) ? inset : parent.width - sz - inset
                            y: (index < 2) ? inset : parent.height - sz - inset
                            onLoaded: {
                                item.size = sz
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                            }
                        }
                    }

                    // Surround (rim): fixed to the case, convex, cap-lit.
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.82
                        height: width
                        radius: width / 2
                        color: "#1d1d1d"
                        border.color: "#323232"
                        border.width: 1

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.inverted = true
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                item.level = Qt.binding(function() { return root.audioLevels[1] })
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.75
                        height: width
                        radius: width / 2
                        color: "#2e2e2e"
                        border.color: "#4a4a4a"
                        border.width: 4
                        scale: 1.0 + root.vibe[1] * 0.035

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                item.level = Qt.binding(function() { return root.audioLevels[1] })
                            }
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width * 0.45
                            height: width
                            radius: width / 2
                            color: "#0a0a0a"

                            Loader {
                                anchors.fill: parent
                                sourceComponent: shadowConeComponent
                                onLoaded: {
                                    item.inverted = true
                                    item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                    item.level = Qt.binding(function() { return root.audioLevels[1] })
                                }
                            }
                        }
                    }
                }

                // --- 3. WOOFER (Bass) ---
                Item {
                    width: parent.width * 0.95
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        anchors.fill: parent
                        color: "#303030"
                        border.color: "#5e5e5e"
                        border.width: 4
                        radius: 8
                    }

                    // Four corner mounting screws on the enclosing housing.
                    Repeater {
                        model: 4
                        Loader {
                            sourceComponent: screwComponent
                            readonly property real sz: parent.width * 0.08
                            readonly property real inset: parent.width * 0.05
                            width: sz; height: sz
                            x: (index % 2 === 0) ? inset : parent.width - sz - inset
                            y: (index < 2) ? inset : parent.height - sz - inset
                            onLoaded: {
                                item.size = sz
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                            }
                        }
                    }

                    // Surround (rim): fixed to the case, convex, cap-lit.
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.89
                        height: width
                        radius: width / 2
                        color: "#1d1d1d"
                        border.color: "#323232"
                        border.width: 1

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.inverted = true
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                item.level = Qt.binding(function() { return root.audioLevels[2] })
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.82
                        height: width
                        radius: width / 2
                        color: "#2e2e2e"
                        border.color: "#5e5e5e"
                        border.width: 6
                        scale: 1.0 + root.vibe[2] * 0.04

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                item.level = Qt.binding(function() { return root.audioLevels[2] })
                            }
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width * 0.5
                            height: width
                            radius: width / 2
                            color: "#050807"
                            border.color: "#11221f"
                            border.width: 2

                            Loader {
                                anchors.fill: parent
                                sourceComponent: shadowConeComponent
                                onLoaded: {
                                    item.inverted = true
                                    item.lightFromLeft = Qt.binding(function() { return root.lightFromLeft })
                                    item.level = Qt.binding(function() { return root.audioLevels[2] })
                                }
                            }
                        }
                    }
                }

                // --- 4. BRAND LOGO, CHANNEL BADGE & BASS PORT ---
                Item {
                    width: parent.width
                    height: parent.height * 0.12

                    Text {
                        text: "Technics"
                        font.bold: true
                        font.pixelSize: parent.height * 0.35
                        font.family: "Serif"
                        color: "#e6d7b8"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                    }

                    // Channel indicator badge (L / R / M) — click to cycle
                    // channel. Side follows the selection: L hugs the left,
                    // R the right, M sits centered.
                    Rectangle {
                        id: channelBadge
                        // Badge size derived from cabinet height (kept in one
                        // place so the x math below can reuse the expression
                        // instead of the possibly-stale `width` property).
                        readonly property real badgeSize: parent.height * 0.34
                        width: badgeSize
                        height: badgeSize
                        radius: 4
                        color: badgeMouse.containsMouse ? "#153029" : "#0d0c0b"
                        border.color: "#00a887"
                        border.width: 2
                        anchors.verticalCenter: parent.verticalCenter

                        // Slide to the channel's side. The Right position uses
                        // `badgeSize` (not `width`) so it recomputes in lockstep
                        // with the badge size during an aspect resize — using
                        // `width` here raced the resize pass and drifted.
                        x: root.channel === 0
                             ? parent.width * 0.05
                             : parent.width - badgeSize - parent.width * 0.05
                        Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                        Text {
                            anchors.centerIn: parent
                            text: fullRep.channelLabel
                            font.bold: true
                            font.pixelSize: parent.height * 0.6
                            font.family: "Sans"
                            color: "#00d9ae"
                        }

                        MouseArea {
                            id: badgeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Cycle Left <-> Right and persist.
                            onClicked: {
                                Plasmoid.configuration.channel = (root.channel + 1) % 2
                            }
                        }
                    }

                    // Bass reflex port
                    Rectangle {
                        width: parent.height * 0.45
                        height: width
                        radius: width / 2
                        color: "#000000"
                        border.color: "#1a1a1a"
                        border.width: 3
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                    }
                }
            }
        }
    }
    }
}
