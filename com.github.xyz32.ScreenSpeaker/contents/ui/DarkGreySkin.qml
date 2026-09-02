import QtQuick

// Original dark-grey cabinet with inset frame and dark rubber feet.
Item {
    id: root

    property bool isSubwoofer: false
    property real lightSourceX: 0.5
    readonly property real lightBias: Math.max(-1.0, Math.min(1.0,
        (0.5 - lightSourceX) / 0.18))
    readonly property real footWidth: height * (isSubwoofer ? 0.12 : 0.06)
    readonly property real footHeight: height * (isSubwoofer ? 0.044 : 0.022)
    readonly property real bodyHeight: height - footHeight

    Rectangle {
        id: body
        anchors.top: parent.top
        width: parent.width
        height: root.bodyHeight
        radius: 4
        border.color: "#0d0c0b"
        border.width: 4
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#242424" }
            GradientStop { position: 0.28; color: "#1d1d1d" }
            GradientStop { position: 0.55; color: "#1a1816" }
            GradientStop { position: 0.78; color: "#161514" }
            GradientStop { position: 1.0; color: "#11100f" }
        }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            rotation: root.lightBias >= 0 ? 0 : 180
            opacity: Math.abs(root.lightBias)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#20ffffff" }
                GradientStop { position: 0.16; color: "#0affffff" }
                GradientStop { position: 0.58; color: "#00ffffff" }
                GradientStop { position: 1.0; color: "#30000000" }
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "transparent"
            border.color: "#000000"
            border.width: 8
            opacity: 0.45
            radius: parent.radius
        }
    }

    Repeater {
        model: 2
        Item {
            // Subwoofer defaults to half the stereo height, so doubled ratios
            // keep its feet the same absolute size as the L/R cabinet feet.
            width: root.footWidth
            height: root.footHeight
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
                opacity: 0.22
            }

            Rectangle {
                anchors.fill: parent
                radius: height * 0.28
                rotation: root.lightBias >= 0 ? 0 : 180
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "#111111" }
                    GradientStop { position: 0.18; color: "#4a4a4a" }
                    GradientStop { position: 0.38; color: "#2b2b2b" }
                    GradientStop { position: 0.72; color: "#181818" }
                    GradientStop { position: 1.0; color: "#080808" }
                }
            }
        }
    }
}
