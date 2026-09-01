import QtQuick

// Bright cherry cabinet with directional satin sheen and chrome feet.
Item {
    id: root

    property real lightSourceX: 0.5
    property bool isSubwoofer: false
    readonly property real lightBias: Math.max(-1.0, Math.min(1.0,
        (0.5 - lightSourceX) / 0.18))
    readonly property real footHeightRatio: isSubwoofer ? 0.044 : 0.022
    readonly property real bodyHeight: height * (1.0 - footHeightRatio)

    Rectangle {
        id: body
        anchors.top: parent.top
        width: parent.width
        height: root.bodyHeight
        radius: 4
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#c56549" }
            GradientStop { position: 0.28; color: "#aa4234" }
            GradientStop { position: 0.55; color: "#c35a41" }
            GradientStop { position: 0.78; color: "#9b352d" }
            GradientStop { position: 1.0; color: "#b94d37" }
        }

        Canvas {
            anchors.fill: parent
            anchors.margins: 1
            opacity: 0.34
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.clearRect(0, 0, width, height)

                var fibres = 25
                for (var i = 0; i < fibres; ++i) {
                    var baseX = (i + 0.5) * width / fibres
                    ctx.beginPath()
                    for (var y = 0; y <= height; y += 5) {
                        var bend = Math.sin(y * 0.028 + i * 1.73) * width * 0.010
                                 + Math.sin(y * 0.009 + i * 0.61) * width * 0.016
                        if (y === 0)
                            ctx.moveTo(baseX + bend, y)
                        else
                            ctx.lineTo(baseX + bend, y)
                    }
                    ctx.strokeStyle = (i % 4 === 0) ? "#ffd0aa" : "#5e1818"
                    ctx.lineWidth = Math.max(0.55, width * (i % 4 === 0 ? 0.002 : 0.0035))
                    ctx.stroke()
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            rotation: root.lightBias >= 0 ? 0 : 180
            opacity: Math.abs(root.lightBias)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#35ffffff" }
                GradientStop { position: 0.16; color: "#08ffffff" }
                GradientStop { position: 0.58; color: "#00ffffff" }
                GradientStop { position: 1.0; color: "#35611d1a" }
            }
        }
    }

    Repeater {
        model: 2
        Item {
            // Default subwoofer feet match the stereo feet in absolute size.
            width: root.height * (root.isSubwoofer ? 0.12 : 0.06)
            height: root.height * root.footHeightRatio
            x: index === 0
               ? root.width * 0.12
               : root.width - width - root.width * 0.12
            y: root.bodyHeight

            Rectangle {
                // Light from the left casts right; light from the right casts left.
                x: root.lightBias * parent.width * 0.05
                y: parent.height * 0.18
                width: parent.width
                height: parent.height
                radius: height * 0.28
                color: "#000000"
                opacity: 0.30
            }

            Rectangle {
                anchors.fill: parent
                radius: height * 0.28
                rotation: root.lightBias >= 0 ? 0 : 180
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "#596166" }
                    GradientStop { position: 0.18; color: "#f7fdff" }
                    GradientStop { position: 0.38; color: "#b8c1c5" }
                    GradientStop { position: 0.72; color: "#747d82" }
                    GradientStop { position: 1.0; color: "#34393c" }
                }
            }
        }
    }
}
