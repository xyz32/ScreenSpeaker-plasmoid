import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Shapes
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Per-instance configuration: channel and cabinet skin.
    // channel: 0=Left, 1=Right, 2=Subwoofer; skin: 0=Cherry Wood,
    // 1=Dark Grey, 2=Mahogany.
    readonly property int channel: Plasmoid.configuration.channel
    readonly property int skin: Plasmoid.configuration.skin
    readonly property bool isSubwoofer: root.channel === 2

    // Continuous room-light position across the speaker face. 0.32 and 0.68
    // preserve the accepted left/right shading at a screen edge; 0.5 is a
    // balanced frontal light when the speaker is at the screen centre.
    property real lightSourceX: 0.5
    readonly property real lightBias: Math.max(-1.0, Math.min(1.0,
        (0.5 - lightSourceX) / 0.18))

    function updateLightPosition() {
        if (!root.visible || root.width <= 0 || Screen.width <= 0)
            return
        var globalCenter = root.mapToGlobal(root.width / 2, root.height / 2)
        var screenHalf = Screen.width / 2
        var screenCenter = Screen.virtualX + screenHalf
        var offset = Math.max(-1.0, Math.min(1.0,
            (globalCenter.x - screenCenter) / screenHalf))
        // A speaker left of centre is lit from its right, and vice versa.
        root.lightSourceX = 0.5 - offset * 0.18
    }

    Behavior on lightSourceX {
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }

    // Plasma does not expose a dependable global-position change signal for
    // desktop applets, so cheaply resample while the widget is visible.
    Timer {
        interval: 500
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: root.updateLightPosition()
    }

    // Audio levels for THIS instance: [Tweeter, Mid, Woofer] normalized 0.0-1.0
    // audioLevels = per-band ENERGY (drives vibration amplitude).
    // audioActivity = per-band ACTIVITY, fraction of active bins (drives rate).
    property var audioLevels: [0.0, 0.0, 0.0]
    property var audioActivity: [0.0, 0.0, 0.0]

    readonly property real originalWidth: 300
    readonly property real originalHeight: 800

    function mountingFrameEdgeWidth(frameSize, nominalWidth) {
        return Math.min(nominalWidth, Math.max(0.6, frameSize * 0.035))
    }

    function mountingScrewCenterInset(frameSize, nominalEdgeWidth,
                                      surroundRatio) {
        var edgeWidth = mountingFrameEdgeWidth(frameSize,
            nominalEdgeWidth)
        var span = Math.max(1, frameSize - edgeWidth)
        var cornerScale = Math.min(1, span / 50)
        var diagonalThreshold = edgeWidth
            + span * (0.264 - 0.05) * cornerScale
        var frameInnerRadius = (frameSize - diagonalThreshold)
            / Math.SQRT2 - edgeWidth / 2
        var surroundRadius = frameSize * surroundRatio / 2
        var centeredRadius = (frameInnerRadius + surroundRadius) / 2
        return frameSize / 2 - centeredRadius / Math.SQRT2
    }

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

            // Daemon format: the original 12 energy/activity values followed
            // by dedicated 20-80 Hz stereo energy/activity values:
            //   ... Le_ultra Re_ultra La_ultra Ra_ultra
            var parts = txt.split(/\s+/)
            if (parts.length < 12) return

            var eBass, eMid, eHigh, aBass, aMid, aHigh
            if (root.isSubwoofer) {
                // React only to dedicated 20-80 Hz energy. max() preserves
                // hard-panned ultra-low bass without summing above 1.0. A zero
                // fallback keeps Subwoofer mode silent with an old 12-value daemon.
                eBass = Math.max(parseFloat(parts[12]) || 0,
                                 parseFloat(parts[13]) || 0)
                aBass = Math.max(parseFloat(parts[14]) || 0,
                                 parseFloat(parts[15]) || 0)
                eMid = 0; eHigh = 0
                aMid = 0; aHigh = 0
            } else {
                // Channel offset into each 6-value group: Left = 0, Right = 3.
                var o = (root.channel === 0) ? 0 : 3
                eBass = parseFloat(parts[o])     || 0
                eMid  = parseFloat(parts[o + 1]) || 0
                eHigh = parseFloat(parts[o + 2]) || 0
                aBass = parseFloat(parts[6 + o])     || 0
                aMid  = parseFloat(parts[6 + o + 1]) || 0
                aHigh = parseFloat(parts[6 + o + 2]) || 0
            }

            // Visual order is [Tweeter, Mid, Woofer] = [high, mid, bass].
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
            // v2 appends a dedicated ultra-low stereo band to the payload.
            root.dataPath = dir + "/plasma-speaker-v2.dat"
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

    Component.onCompleted: {
        resolveRuntimeDir()
        updateLightPosition()
    }

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
            // Continuous horizontal light position: 0.32 = left source,
            // 0.5 = centred source, 0.68 = right source.
            property real lightSourceX: 0.5
            preferredRendererType: Shape.CurveRenderer
            antialiasing: true

            readonly property real lightY: 0.28
            // Convex keeps the highlight at the light position; concave flips
            // it through the centre onto the opposite slope.
            readonly property real litX: inverted ? lightSourceX : (1.0 - lightSourceX)
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

    // Reusable mounting plate. The long sides preserve the square housing,
    // while each deep diagonal corner cut blends into them through quadratic
    // fillets (selected corner mockup C). A dark matte radial gradient follows
    // the same moving room-light position as the speaker-cone shading.
    Component {
        id: mountingFrameComponent

        Shape {
            id: mountingFrame
            anchors.fill: parent
            property color frameColor: "#1a1c1d"
            property color edgeColor: "#3d4244"
            property real edgeWidth: 4
            property real lightSourceX: root.lightSourceX
            readonly property real lightSourceY: 0.28
            readonly property real lightBias: Math.max(-1.0,
                Math.min(1.0, (0.5 - lightSourceX) / 0.18))
            readonly property real leftRimAlpha: 0.08
                + Math.max(0, lightBias) * 0.34
            readonly property real rightRimAlpha: 0.08
                + Math.max(0, -lightBias) * 0.34
            preferredRendererType: Shape.CurveRenderer
            antialiasing: true

            readonly property real renderedEdgeWidth:
                root.mountingFrameEdgeWidth(Math.min(width, height),
                    edgeWidth)
            readonly property real inset: renderedEdgeWidth / 2
            readonly property real leftEdge: inset
            readonly property real topEdge: inset
            readonly property real rightEdge: width - inset
            readonly property real bottomEdge: height - inset
            readonly property real span: Math.max(1,
                Math.min(width, height) - renderedEdgeWidth)
            // Preserve mockup C at normal sizes; progressively soften the cut
            // only when the whole frame is too small to clear its screw heads.
            readonly property real cornerScale: Math.min(1, span / 50)
            readonly property real cutDepth: span * 0.264 * cornerScale
            readonly property real fillet: span * 0.05 * cornerScale

            ShapePath {
                strokeColor: mountingFrame.edgeColor
                strokeWidth: mountingFrame.renderedEdgeWidth
                fillGradient: RadialGradient {
                    centerX: mountingFrame.width
                             * mountingFrame.lightSourceX
                    centerY: mountingFrame.height
                             * mountingFrame.lightSourceY
                    focalX: mountingFrame.width
                            * mountingFrame.lightSourceX
                    focalY: mountingFrame.height
                            * mountingFrame.lightSourceY
                    centerRadius: Math.max(mountingFrame.width,
                        mountingFrame.height) * 0.92
                    GradientStop {
                        position: 0.0
                        color: Qt.lighter(mountingFrame.frameColor, 1.65)
                    }
                    GradientStop {
                        position: 0.32
                        color: Qt.lighter(mountingFrame.frameColor, 1.22)
                    }
                    GradientStop {
                        position: 0.62
                        color: mountingFrame.frameColor
                    }
                    GradientStop {
                        position: 1.0
                        color: Qt.darker(mountingFrame.frameColor, 1.55)
                    }
                }
                startX: mountingFrame.leftEdge + mountingFrame.cutDepth
                startY: mountingFrame.topEdge

                // Top side and top-right filleted cut.
                PathLine {
                    x: mountingFrame.rightEdge - mountingFrame.cutDepth
                    y: mountingFrame.topEdge
                }
                PathQuad {
                    controlX: mountingFrame.rightEdge
                              - mountingFrame.cutDepth
                              + mountingFrame.fillet
                    controlY: mountingFrame.topEdge
                    x: mountingFrame.rightEdge
                       - mountingFrame.cutDepth
                       + mountingFrame.fillet * 2
                    y: mountingFrame.topEdge + mountingFrame.fillet
                }
                PathLine {
                    x: mountingFrame.rightEdge - mountingFrame.fillet
                    y: mountingFrame.topEdge
                       + mountingFrame.cutDepth
                       - mountingFrame.fillet * 2
                }
                PathQuad {
                    controlX: mountingFrame.rightEdge
                    controlY: mountingFrame.topEdge
                              + mountingFrame.cutDepth
                              - mountingFrame.fillet
                    x: mountingFrame.rightEdge
                    y: mountingFrame.topEdge + mountingFrame.cutDepth
                }

                // Right side and bottom-right filleted cut.
                PathLine {
                    x: mountingFrame.rightEdge
                    y: mountingFrame.bottomEdge
                       - mountingFrame.cutDepth
                }
                PathQuad {
                    controlX: mountingFrame.rightEdge
                    controlY: mountingFrame.bottomEdge
                              - mountingFrame.cutDepth
                              + mountingFrame.fillet
                    x: mountingFrame.rightEdge - mountingFrame.fillet
                    y: mountingFrame.bottomEdge
                       - mountingFrame.cutDepth
                       + mountingFrame.fillet * 2
                }
                PathLine {
                    x: mountingFrame.rightEdge
                       - mountingFrame.cutDepth
                       + mountingFrame.fillet * 2
                    y: mountingFrame.bottomEdge - mountingFrame.fillet
                }
                PathQuad {
                    controlX: mountingFrame.rightEdge
                              - mountingFrame.cutDepth
                              + mountingFrame.fillet
                    controlY: mountingFrame.bottomEdge
                    x: mountingFrame.rightEdge - mountingFrame.cutDepth
                    y: mountingFrame.bottomEdge
                }

                // Bottom side and bottom-left filleted cut.
                PathLine {
                    x: mountingFrame.leftEdge + mountingFrame.cutDepth
                    y: mountingFrame.bottomEdge
                }
                PathQuad {
                    controlX: mountingFrame.leftEdge
                              + mountingFrame.cutDepth
                              - mountingFrame.fillet
                    controlY: mountingFrame.bottomEdge
                    x: mountingFrame.leftEdge
                       + mountingFrame.cutDepth
                       - mountingFrame.fillet * 2
                    y: mountingFrame.bottomEdge - mountingFrame.fillet
                }
                PathLine {
                    x: mountingFrame.leftEdge + mountingFrame.fillet
                    y: mountingFrame.bottomEdge
                       - mountingFrame.cutDepth
                       + mountingFrame.fillet * 2
                }
                PathQuad {
                    controlX: mountingFrame.leftEdge
                    controlY: mountingFrame.bottomEdge
                              - mountingFrame.cutDepth
                              + mountingFrame.fillet
                    x: mountingFrame.leftEdge
                    y: mountingFrame.bottomEdge - mountingFrame.cutDepth
                }

                // Left side and top-left filleted cut.
                PathLine {
                    x: mountingFrame.leftEdge
                    y: mountingFrame.topEdge + mountingFrame.cutDepth
                }
                PathQuad {
                    controlX: mountingFrame.leftEdge
                    controlY: mountingFrame.topEdge
                              + mountingFrame.cutDepth
                              - mountingFrame.fillet
                    x: mountingFrame.leftEdge + mountingFrame.fillet
                    y: mountingFrame.topEdge
                       + mountingFrame.cutDepth
                       - mountingFrame.fillet * 2
                }
                PathLine {
                    x: mountingFrame.leftEdge
                       + mountingFrame.cutDepth
                       - mountingFrame.fillet * 2
                    y: mountingFrame.topEdge + mountingFrame.fillet
                }
                PathQuad {
                    controlX: mountingFrame.leftEdge
                              + mountingFrame.cutDepth
                              - mountingFrame.fillet
                    controlY: mountingFrame.topEdge
                    x: mountingFrame.leftEdge + mountingFrame.cutDepth
                    y: mountingFrame.topEdge
                }
            }

            // A thin highlight follows the upper-left outline when the room
            // light is on the left. Rounded caps make the crossfade seamless.
            ShapePath {
                strokeColor: Qt.rgba(0.48, 0.51, 0.53,
                    mountingFrame.leftRimAlpha)
                strokeWidth: Math.max(0.5,
                    mountingFrame.renderedEdgeWidth * 0.42)
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: mountingFrame.leftEdge
                startY: mountingFrame.height / 2
                PathLine {
                    x: mountingFrame.leftEdge
                    y: mountingFrame.topEdge + mountingFrame.cutDepth
                }
                PathQuad {
                    controlX: mountingFrame.leftEdge
                    controlY: mountingFrame.topEdge
                              + mountingFrame.cutDepth
                              - mountingFrame.fillet
                    x: mountingFrame.leftEdge + mountingFrame.fillet
                    y: mountingFrame.topEdge
                       + mountingFrame.cutDepth
                       - mountingFrame.fillet * 2
                }
                PathLine {
                    x: mountingFrame.leftEdge
                       + mountingFrame.cutDepth
                       - mountingFrame.fillet * 2
                    y: mountingFrame.topEdge + mountingFrame.fillet
                }
                PathQuad {
                    controlX: mountingFrame.leftEdge
                              + mountingFrame.cutDepth
                              - mountingFrame.fillet
                    controlY: mountingFrame.topEdge
                    x: mountingFrame.leftEdge + mountingFrame.cutDepth
                    y: mountingFrame.topEdge
                }
                PathLine {
                    x: mountingFrame.width / 2
                    y: mountingFrame.topEdge
                }
            }

            // Mirror the same highlight on the upper-right outline as the
            // light source moves across the speaker face.
            ShapePath {
                strokeColor: Qt.rgba(0.48, 0.51, 0.53,
                    mountingFrame.rightRimAlpha)
                strokeWidth: Math.max(0.5,
                    mountingFrame.renderedEdgeWidth * 0.42)
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: mountingFrame.width / 2
                startY: mountingFrame.topEdge
                PathLine {
                    x: mountingFrame.rightEdge - mountingFrame.cutDepth
                    y: mountingFrame.topEdge
                }
                PathQuad {
                    controlX: mountingFrame.rightEdge
                              - mountingFrame.cutDepth
                              + mountingFrame.fillet
                    controlY: mountingFrame.topEdge
                    x: mountingFrame.rightEdge
                       - mountingFrame.cutDepth
                       + mountingFrame.fillet * 2
                    y: mountingFrame.topEdge + mountingFrame.fillet
                }
                PathLine {
                    x: mountingFrame.rightEdge - mountingFrame.fillet
                    y: mountingFrame.topEdge
                       + mountingFrame.cutDepth
                       - mountingFrame.fillet * 2
                }
                PathQuad {
                    controlX: mountingFrame.rightEdge
                    controlY: mountingFrame.topEdge
                              + mountingFrame.cutDepth
                              - mountingFrame.fillet
                    x: mountingFrame.rightEdge
                    y: mountingFrame.topEdge + mountingFrame.cutDepth
                }
                PathLine {
                    x: mountingFrame.rightEdge
                    y: mountingFrame.height / 2
                }
            }
        }
    }

    // Reusable hex socket cap screw: a metallic circular cap with a recessed
    // six-sided drive, a bright edge toward the room light, and a soft cast
    // shadow on the far side. `size` and socket angle are set by the caller.
    Component {
        id: screwComponent

        Item {
            id: screw
            property real size: 10
            property real lightSourceX: 0.5
            property real socketAngle: 0
            readonly property real lightBias: Math.max(-1.0, Math.min(1.0,
                (0.5 - lightSourceX) / 0.18))
            width: size
            height: size

            // Soft cast shadow, offset away from the light.
            Rectangle {
                width: parent.width
                height: parent.height
                radius: width / 2
                color: "#000000"
                opacity: 0.35
                x: screw.lightBias * parent.width * 0.12
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
                    x: parent.width * (0.25 - screw.lightBias * 0.13)
                    y: parent.height * 0.12
                }

                // Recessed hex socket. The caller supplies a stable
                // pseudo-random angle so neighboring caps do not line up.
                Item {
                    id: hexSocket
                    anchors.centerIn: parent
                    width: parent.width * 0.52
                    height: width
                    rotation: screw.socketAngle

                    Shape {
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer
                        antialiasing: true

                        ShapePath {
                            strokeColor: "#08090a"
                            strokeWidth: Math.max(0.6,
                                hexSocket.width * 0.09)
                            fillColor: "#121416"
                            startX: hexSocket.width * 0.5
                            startY: 0
                            PathLine {
                                x: hexSocket.width * 0.933
                                y: hexSocket.height * 0.25
                            }
                            PathLine {
                                x: hexSocket.width * 0.933
                                y: hexSocket.height * 0.75
                            }
                            PathLine {
                                x: hexSocket.width * 0.5
                                y: hexSocket.height
                            }
                            PathLine {
                                x: hexSocket.width * 0.067
                                y: hexSocket.height * 0.75
                            }
                            PathLine {
                                x: hexSocket.width * 0.067
                                y: hexSocket.height * 0.25
                            }
                            PathLine {
                                x: hexSocket.width * 0.5
                                y: 0
                            }
                        }
                    }
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

        // L/R speakers remain tall; Subwoofer uses a balanced vertical rectangle.
        readonly property real aspect: root.isSubwoofer
                                       ? 0.82
                                       : root.originalWidth / root.originalHeight
        // L/R share one height; Subwoofer has an independent rectangular size
        // whose default height is half the stereo speaker height.
        readonly property int cfgHeight: root.isSubwoofer
                                         ? Plasmoid.configuration.subwooferHeight
                                         : Plasmoid.configuration.speakerHeight
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
        // Manual desktop resizes update the active channel's size after settling.
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
                if (root.isSubwoofer)
                    Plasmoid.configuration.subwooferHeight = h
                else
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

        // Channel badge letter and accessible full name.
        readonly property string channelLabel: ["L", "R", "S"][root.channel]
        readonly property string channelName: [i18n("Left"), i18n("Right"), i18n("Subwoofer")][root.channel]

        // Preserve 300:800 for L/R and 0.82:1 for Subwoofer. The available
        // applet area limits growth, while cfgHeight caps config-driven shrink.
        // Plasma owns the outer resize geometry and does not reliably enforce
        // an applet aspect ratio, so keep any excess space above the speaker
        // by pinning the fitted drawing to the bottom centre.
        Item {
            id: fitBox
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            readonly property real parentAspect: parent.width / parent.height
            readonly property real availableHeight: parentAspect > fullRep.aspect
                                                    ? parent.height
                                                    : parent.width / fullRep.aspect
            height: Math.min(availableHeight, fullRep.cfgHeight)
            width: height * fullRep.aspect

            // The reusable skin owns the cabinet surface and feet. The driver
            // stack remains here so every skin shares identical audio visuals.
            Item {
                id: cabinet
                anchors.top: parent.top
                readonly property real reservedFootHeight: fitBox.height
                    * (root.isSubwoofer ? 0.044 : 0.022)
                width: parent.width
                height: parent.height - reservedFootHeight

                Loader {
                    id: skinLoader
                    width: fitBox.width
                    height: fitBox.height
                    source: root.skin === 1
                            ? Qt.resolvedUrl("DarkGreySkin.qml")
                            : root.skin === 2
                              ? Qt.resolvedUrl("MahoganySkin.qml")
                              : Qt.resolvedUrl("CherryWoodSkin.qml")
                    onLoaded: {
                        item.isSubwoofer = Qt.binding(function() {
                            return root.isSubwoofer
                        })
                        item.lightSourceX = Qt.binding(function() {
                            return root.lightSourceX
                        })
                    }
                }

                Column {
                id: driverColumn
                visible: !root.isSubwoofer
                anchors.centerIn: parent
                width: parent.width * 0.85
                height: parent.height * 0.9
                spacing: parent.height * 0.03
                readonly property real mountingScrewSize: width * 0.0585

                // --- 1. TWEETER (Highs) ---
                Item {
                    visible: !root.isSubwoofer
                    width: parent.width * 0.45
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    readonly property real frameEdgeWidth: 2
                    readonly property real surroundRatio: 0.72

                    Loader {
                        anchors.fill: parent
                        sourceComponent: mountingFrameComponent
                        onLoaded: {
                            item.frameColor = "#1b1d1e"
                            item.edgeColor = "#222527"
                            item.edgeWidth = 2
                        }
                    }

                    // Four corner mounting screws on the enclosing housing.
                    Repeater {
                        model: 4
                        Loader {
                            sourceComponent: screwComponent
                            readonly property real sz: driverColumn.mountingScrewSize
                            readonly property real centerInset:
                                root.mountingScrewCenterInset(parent.width,
                                    parent.frameEdgeWidth,
                                    parent.surroundRatio)
                            readonly property real socketAngle:
                                ((index + 1) * 37
                                 + Math.round(parent.surroundRatio * 100))
                                % 60
                            width: sz; height: sz
                            x: (index % 2 === 0)
                               ? centerInset - sz / 2
                               : parent.width - centerInset - sz / 2
                            y: (index < 2)
                               ? centerInset - sz / 2
                               : parent.height - centerInset - sz / 2
                            onLoaded: {
                                item.size = sz
                                item.socketAngle = socketAngle
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                    item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
                                    item.level = Qt.binding(function() { return root.audioLevels[0] })
                                }
                            }
                        }
                    }
                }

                // --- 2. MIDRANGE (Mids) ---
                Item {
                    visible: !root.isSubwoofer
                    width: parent.width * 0.65
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    readonly property real frameEdgeWidth: 3
                    readonly property real surroundRatio: 0.82

                    Loader {
                        anchors.fill: parent
                        sourceComponent: mountingFrameComponent
                        onLoaded: {
                            item.frameColor = "#17191a"
                            item.edgeColor = "#1f2224"
                            item.edgeWidth = 3
                        }
                    }

                    // Four corner mounting screws on the enclosing housing.
                    Repeater {
                        model: 4
                        Loader {
                            sourceComponent: screwComponent
                            readonly property real sz: driverColumn.mountingScrewSize
                            readonly property real centerInset:
                                root.mountingScrewCenterInset(parent.width,
                                    parent.frameEdgeWidth,
                                    parent.surroundRatio)
                            readonly property real socketAngle:
                                ((index + 1) * 37
                                 + Math.round(parent.surroundRatio * 100))
                                % 60
                            width: sz; height: sz
                            x: (index % 2 === 0)
                               ? centerInset - sz / 2
                               : parent.width - centerInset - sz / 2
                            y: (index < 2)
                               ? centerInset - sz / 2
                               : parent.height - centerInset - sz / 2
                            onLoaded: {
                                item.size = sz
                                item.socketAngle = socketAngle
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                    item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
                                    item.level = Qt.binding(function() { return root.audioLevels[1] })
                                }
                            }
                        }
                    }
                }

                // --- 3. WOOFER (Bass) ---
                Item {
                    visible: !root.isSubwoofer
                    width: parent.width * 0.95
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    readonly property real frameEdgeWidth: 4
                    readonly property real surroundRatio: 0.89

                    Loader {
                        anchors.fill: parent
                        sourceComponent: mountingFrameComponent
                        onLoaded: {
                            item.frameColor = "#1a1c1d"
                            item.edgeColor = "#282c2e"
                            item.edgeWidth = 4
                        }
                    }

                    // Four corner mounting screws on the enclosing housing.
                    Repeater {
                        model: 4
                        Loader {
                            sourceComponent: screwComponent
                            readonly property real sz: driverColumn.mountingScrewSize
                            readonly property real centerInset:
                                root.mountingScrewCenterInset(parent.width,
                                    parent.frameEdgeWidth,
                                    parent.surroundRatio)
                            readonly property real socketAngle:
                                ((index + 1) * 37
                                 + Math.round(parent.surroundRatio * 100))
                                % 60
                            width: sz; height: sz
                            x: (index % 2 === 0)
                               ? centerInset - sz / 2
                               : parent.width - centerInset - sz / 2
                            y: (index < 2)
                               ? centerInset - sz / 2
                               : parent.height - centerInset - sz / 2
                            onLoaded: {
                                item.size = sz
                                item.socketAngle = socketAngle
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
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
                                    item.lightSourceX = Qt.binding(function() { return root.lightSourceX })
                                    item.level = Qt.binding(function() { return root.audioLevels[2] })
                                }
                            }
                        }
                    }
                }


                // --- 4. BRAND LOGO, CHANNEL BADGE & BASS PORT ---
                Item {
                    id: footerControls
                    width: parent.width
                    height: parent.height * 0.12

                    Text {
                        text: "Technics"
                        font.bold: true
                        font.pixelSize: parent.height * 0.35
                        font.family: "Serif"
                        color: "#e6d7b8"
                        anchors.horizontalCenter: parent.horizontalCenter
                        // The footer starts one Column spacing below the woofer.
                        // Center the logo in the full gap from that woofer edge
                        // to the top edge of the air port.
                        y: (-driverColumn.spacing + bassPort.y - height) / 2
                    }

                    // Passive channel indicator for stereo speakers. Channel
                    // selection is handled exclusively by the configuration menu.
                    Rectangle {
                        id: channelBadge
                        readonly property real badgeSize: parent.height * 0.34
                        width: badgeSize
                        height: badgeSize
                        radius: 4
                        color: "#0d0c0b"
                        border.color: "#00a887"
                        border.width: 2
                        anchors.verticalCenter: bassPort.verticalCenter

                        // Keep Left on the left and Right on the right.
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
                    }

                    // Circular bass reflex port for L/R speakers.
                    Rectangle {
                        id: bassPort
                        width: parent.height * 0.70
                        height: width
                        radius: width / 2
                        color: "#000000"
                        border.color: "#1a1a1a"
                        border.width: 3
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: -parent.height * 0.12
                    }
                }

            }

            // Balanced subwoofer layout. One reference margin controls the
            // driver top/side clearances and the vent's bottom clearance.
            Item {
                id: subwooferLayout
                visible: root.isSubwoofer
                anchors.fill: parent
                readonly property real referenceMargin: width * 0.06
                readonly property real driverSize: width - referenceMargin * 2
                readonly property real mountingScrewSize: driverSize * 0.05
                readonly property real lowerGapTop: subwooferDriver.y + subwooferDriver.height
                readonly property real lowerGapBottom: subwooferVent.y
                readonly property real lowerGapHeight: Math.max(0,
                    lowerGapBottom - lowerGapTop)

                // One oversized driver fed by the true L+R subwoofer signal.
                Item {
                    id: subwooferDriver
                    anchors.top: parent.top
                    anchors.topMargin: subwooferLayout.referenceMargin
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: subwooferLayout.driverSize
                    height: width
                    readonly property real frameEdgeWidth: 4
                    readonly property real surroundRatio: 0.91

                    Loader {
                        anchors.fill: parent
                        sourceComponent: mountingFrameComponent
                        onLoaded: {
                            item.frameColor = "#1a1c1d"
                            item.edgeColor = "#282c2e"
                            item.edgeWidth = 4
                        }
                    }

                    Repeater {
                        model: 4
                        Loader {
                            sourceComponent: screwComponent
                            readonly property real sz: subwooferLayout.mountingScrewSize
                            readonly property real centerInset:
                                root.mountingScrewCenterInset(parent.width,
                                    parent.frameEdgeWidth,
                                    parent.surroundRatio)
                            readonly property real socketAngle:
                                ((index + 1) * 37
                                 + Math.round(parent.surroundRatio * 100))
                                % 60
                            width: sz; height: sz
                            x: (index % 2 === 0)
                               ? centerInset - sz / 2
                               : parent.width - centerInset - sz / 2
                            y: (index < 2)
                               ? centerInset - sz / 2
                               : parent.height - centerInset - sz / 2
                            onLoaded: {
                                item.size = sz
                                item.socketAngle = socketAngle
                                item.lightSourceX = Qt.binding(function() {
                                    return root.lightSourceX
                                })
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.91
                        height: width
                        radius: width / 2
                        color: "#1d1d1d"
                        border.color: "#323232"
                        border.width: 2

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.inverted = true
                                item.lightSourceX = Qt.binding(function() {
                                    return root.lightSourceX
                                })
                                item.level = Qt.binding(function() {
                                    return root.audioLevels[2]
                                })
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.84
                        height: width
                        radius: width / 2
                        color: "#2e2e2e"
                        border.color: "#666666"
                        border.width: 7
                        scale: 1.0 + root.vibe[2] * 0.04

                        Loader {
                            anchors.fill: parent
                            sourceComponent: shadowConeComponent
                            onLoaded: {
                                item.lightSourceX = Qt.binding(function() {
                                    return root.lightSourceX
                                })
                                item.level = Qt.binding(function() {
                                    return root.audioLevels[2]
                                })
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
                                    item.lightSourceX = Qt.binding(function() {
                                        return root.lightSourceX
                                    })
                                    item.level = Qt.binding(function() {
                                        return root.audioLevels[2]
                                    })
                                }
                            }
                        }
                    }
                }

                Text {
                    text: "Technics"
                    font.bold: true
                    font.family: "Serif"
                    font.pixelSize: Math.min(subwooferLayout.driverSize * 0.065,
                        subwooferLayout.lowerGapHeight * 0.58)
                    color: "#e6d7b8"
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: subwooferLayout.lowerGapTop
                       + (subwooferLayout.lowerGapHeight - height) / 2
                }

                Rectangle {
                    id: subwooferVent
                    width: subwooferLayout.driverSize * 0.78
                    height: subwooferLayout.driverSize * 0.085
                    radius: height / 2
                    color: "#000000"
                    border.color: "#1a1a1a"
                    border.width: 3
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: subwooferLayout.referenceMargin
                }
            }
        }
    }
    }
}
