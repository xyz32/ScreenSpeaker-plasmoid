import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    // Plasma passes these as initial properties when constructing the page.
    property string title: i18n("General")
    property int cfg_channelDefault: 0
    property int cfg_speakerHeightDefault: 500

    // Plasma's cfg_<key> convention binds config key 'channel' to the
    // combo index (0 = Left, 1 = Right).
    property alias cfg_channel: channelCombo.currentIndex
    property alias cfg_speakerHeight: heightSpin.value

    // Top breathing room — Kirigami.FormLayout otherwise puts the first
    // control flush against the dialog header.
    Item {
        Layout.preferredHeight: Kirigami.Units.smallSpacing * 2
    }

    ComboBox {
        id: channelCombo
        Kirigami.FormData.label: i18n("Speaker channel:")
        model: ["Left", "Right"]
    }

    SpinBox {
        id: heightSpin
        Kirigami.FormData.label: i18n("Speaker height (px):")
        from: 120
        to: 2000
        value: 500
        stepSize: 20
    }

    Label {
        Layout.preferredWidth: 420
        wrapMode: Text.WordWrap
        text: i18n("Width is derived from the fixed speaker aspect ratio. Set the same height on both speakers to keep a stereo pair matched.")
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        opacity: 0.75
    }

    Label {
        Layout.preferredWidth: 420
        wrapMode: Text.WordWrap
        text: i18n("Each speaker instance visualizes one channel. Add the widget twice — set one to Left and one to Right — for a stereo pair.")
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        opacity: 0.75
    }
}
