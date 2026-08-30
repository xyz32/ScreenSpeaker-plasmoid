APP_ID = "com.github.xyz32.ScreenSpeaker"

view:
			plasmoidviewer --size 650x600 --applet $(APP_ID)
qml:
			qmlscene ./$(APP_ID)/contents/ui/Main.qml
install:
			kpackagetool6 -t Plasma/Applet --install $(APP_ID)
upgrade:
			kpackagetool6 -t Plasma/Applet --upgrade $(APP_ID)
remove:
			kpackagetool6 -t Plasma/Applet --remove $(APP_ID)
ls:
			kpackagetool6 --list --type Plasma/Applet

plasmoid:
			rm ScreenSpeaker.plasmoid; cd $(APP_ID); zip -9 -r ../ScreenSpeaker.plasmoid *

clean:
			find . -type f -name '*.qmlc' -delete
			find . -type f -name '*.jsc'  -delete
