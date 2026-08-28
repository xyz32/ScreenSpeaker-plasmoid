#!/bin/bash

rm -rf /home/xyz/.local/share/plasma/plasmoids/com.github.xyz32.ScreenSpeaker
cp -r ./com.github.xyz32.ScreenSpeaker /home/xyz/.local/share/plasma/plasmoids/

# plasmawindowed com.github.xyz32.ScreenSpeaker
plasmoidviewer --applet com.github.xyz32.ScreenSpeaker
