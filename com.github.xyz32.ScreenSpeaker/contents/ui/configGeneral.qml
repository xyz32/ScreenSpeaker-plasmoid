import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    // Plasma passes these as initial properties when constructing the page.
    property string title: i18n("General")
    property int cfg_channelDefault: 0
    property int cfg_skinDefault: 0
    property bool cfg_showGrilleDefault: true
    property int cfg_speakerHeightDefault: 500
    property int cfg_subwooferHeightDefault: 250

    // Plasma's cfg_<key> convention binds each control to KConfig.
    property alias cfg_channel: channelCombo.currentIndex
    property alias cfg_skin: skinCombo.currentIndex
    property alias cfg_showGrille: showGrilleCheck.checked
    property alias cfg_speakerHeight: speakerHeightSpin.value
    property alias cfg_subwooferHeight: subwooferHeightSpin.value

    Label {
        Layout.topMargin: Kirigami.Units.smallSpacing * 2
        Layout.preferredWidth: 420
        Layout.maximumWidth: 420
        wrapMode: Text.WordWrap
        text: channelCombo.currentIndex === 2
            ? i18n("The subwoofer keeps its own rectangular enclosure size.")
            : i18n("Add another widget set to %1 for a stereo pair.",
                channelCombo.currentIndex === 0 ? i18n("Right")
                                                : i18n("Left"))
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        opacity: 0.75
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Channel / size:")
        spacing: Kirigami.Units.smallSpacing

        ComboBox {
            id: channelCombo
            Layout.preferredWidth: Kirigami.Units.gridUnit * 9
            Layout.maximumWidth: Kirigami.Units.gridUnit * 9
            model: [i18n("Left"), i18n("Right"), i18n("Subwoofer")]
        }

        StackLayout {
            currentIndex: channelCombo.currentIndex === 2 ? 1 : 0
            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
            Layout.maximumWidth: Kirigami.Units.gridUnit * 5

            SpinBox {
                id: speakerHeightSpin
                Layout.fillWidth: true
                from: 120
                to: 2000
                value: 500
                stepSize: 20
            }

            SpinBox {
                id: subwooferHeightSpin
                Layout.fillWidth: true
                from: 120
                to: 2000
                value: 250
                stepSize: 10
            }
        }
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Appearance:")
        spacing: Kirigami.Units.smallSpacing

        ComboBox {
            id: skinCombo
            Layout.preferredWidth: Kirigami.Units.gridUnit * 9
            Layout.maximumWidth: Kirigami.Units.gridUnit * 9
            model: [i18n("Cherry Wood"), i18n("Dark Grey"),
                i18n("Mahogany")]
        }

        CheckBox {
            id: showGrilleCheck
            text: i18n("Shroud")
            checked: true
        }
    }
}
