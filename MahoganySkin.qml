import QtQuick

// Classic mahogany cabinet with polished-brass conical feet.
Item {
    id: root

    property real lightSourceX: 0.5
    readonly property real lightBias: Math.max(-1.0, Math.min(1.0,
        (0.5 - lightSourceX) / 0.18))
    readonly property bool squareCabinet: width >= height * 0.8
    readonly property real footHeightRatio: squareCabinet ? 0.044 : 0.022
    readonly property real bodyHeight: height * (1.0 - footHeightRatio)

    Rectangle {
        id: body
        anchors.top: parent.top
        width: parent.width
        height: root.bodyHeight
        radius: 4
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#7d2118" }
            GradientStop { position: 0.28; color: "#59130f" }
            GradientStop { position: 0.55; color: "#8b2c1d" }
            GradientStop { position: 0.78; color: "#651812" }
            GradientStop { position: 1.0; color: "#46100d" }
        }

        Canvas {
            anchors.fill: parent
            anchors.margins: 1
            opacity: 0.38
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.clearRect(0, 0, width, height)

                var fibres = 23
                for (var i = 0; i < fibres; ++i) {
                    var baseX = (i + 0.5) * width / fibres
                    ctx.beginPath()
                    for (var y = 0; y <= height; y += 5) {
                        var bend = Math.sin(y * 0.024 + i * 1.47) * width * 0.012
                                 + Math.sin(y * 0.007 + i * 0.73) * width * 0.020
                        if (y === 0)
                            ctx.moveTo(baseX + bend, y)
                        else
                            ctx.lineTo(baseX + bend, y)
                    }
                    ctx.strokeStyle = (i % 4 === 0) ? "#d27845" : "#2b0707"
                    ctx.lineWidth = Math.max(0.6, width * (i % 4 === 0 ? 0.0022 : 0.0038))
                    ctx.stroke()
                }
            }
        }

        // Highlight follows the same room-light direction as the cones.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            rotation: root.lightBias >= 0 ? 0 : 180
            opacity: Math.abs(root.lightBias)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#32ffd6b0" }
                GradientStop { position: 0.18; color: "#0cffffff" }
                GradientStop { position: 0.58; color: "#00ffffff" }
                GradientStop { position: 1.0; color: "#40230403" }
            }
        }
    }

    Repeater {
        model: 2
        Item {
            // The subwoofer defaults to half the stereo speaker height, so
            // doubled ratios give both cabinets the same absolute foot size.
            width: root.height * (root.squareCabinet ? 0.12 : 0.06)
            height: root.height * root.footHeightRatio
            x: index === 0
               ? root.width * 0.12
               : root.width - width - root.width * 0.12
            y: root.bodyHeight

            // Match the tapered foot silhouette and cast away from the light.
            Canvas {
                anchors.fill: parent
                property real currentLightSourceX: root.lightSourceX
                onCurrentLightSourceXChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.clearRect(0, 0, width, height)

                    var dx = root.lightBias * width * 0.05
                    var dy = height * 0.16
                    ctx.beginPath()
                    ctx.moveTo(width * 0.10 + dx, dy)
                    ctx.lineTo(width * 0.90 + dx, dy)
                    ctx.lineTo(width * 0.64 + dx, height)
                    ctx.lineTo(width * 0.36 + dx, height)
                    ctx.closePath()
                    ctx.fillStyle = "rgba(0, 0, 0, 0.30)"
                    ctx.fill()
                }
            }

            // Canvas clips the polish gradient to a short tapered cone.
            Canvas {
                id: goldFoot
                anchors.fill: parent
                property real currentLightSourceX: root.lightSourceX
                onCurrentLightSourceXChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.clearRect(0, 0, width, height)

                    var fromX = root.lightBias >= 0 ? 0 : width
                    var toX = root.lightBias >= 0 ? width : 0
                    var gold = ctx.createLinearGradient(fromX, 0, toX, 0)
                    gold.addColorStop(0.0, "#6e4308")
                    gold.addColorStop(0.20, "#fff1a6")
                    gold.addColorStop(0.42, "#d9a629")
                    gold.addColorStop(0.72, "#8c570a")
                    gold.addColorStop(1.0, "#4b2b04")

                    ctx.beginPath()
                    ctx.moveTo(width * 0.10, 0)
                    ctx.lineTo(width * 0.90, 0)
                    ctx.lineTo(width * 0.64, height)
                    ctx.lineTo(width * 0.36, height)
                    ctx.closePath()
                    ctx.fillStyle = gold
                    ctx.fill()
                }
            }
        }
    }
}
