# RS41-and-M20-Android-decoder

RS41 and M20 radiosonde decoder for Android, written in pure B4A (Basic4Android).
Receive only. No data is uploaded anywhere.

<img width="1220" height="2712" alt="1000036929" src="https://github.com/user-attachments/assets/eb46d8ea-fbcc-41a2-ac52-ca9bba4c0154" />

<img width="1220" height="2712" alt="Screen3" src="https://github.com/user-attachments/assets/92cbd3bd-d989-455e-b1f4-3aebcc9efd0b" />


## Features
- Decodes Vaisala **RS41** and Meteomodem **M20**; the sonde type is detected automatically after the app starts.
- Shows position, altitude, speed, climb rate, heading, UTC time, satellites and decoder diagnostics, plus a signal level bar.
- **Geo App** button opens your map application and transfers the coordinates, with a marker named after the payload ID.
- Sound modes: off, beep on each valid frame, or live FM audio.
- Keeps decoding in the background (foreground service with notification).
- Press **Back** twice to exit, so you do not close the app by accident.
- The last received telemetry is saved when the app is closed. **Long press Stop** (about 3 s) to view it.
- Languages: English and Croatian.
- Long pressing the Latitude or Longitude field copies its content to the clipboard, while long pressing the GeoApp button copies the coordinates in the 45.76765,16.76632 format to the clipboard. The same applies to "Copy Coordinate" for a saved position. Added saving of the last received position (if available) upon clicking Stop (previously only on exiting the app by pressing Back twice).

## Requirements
- Android phone with USB OTG
- RTL-SDR dongle (tested with RTL-SDR Blog V3 and V4)
- **SDR driver** app (Signalware Ltd) installed separately. It is not part of this project or its APK; this app only talks to it through a local TCP socket (127.0.0.1:1234).

## Download
The APK is in [Releases](../../releases).

## Build
Built with Basic4Android (B4A) 13.40.
Libraries: Core, Network, RandomAccessFile, JavaObject, Phone, RuntimePermissions.
Modules: `Main`, `DecSvc` (service), `RS41`, `M20`, `RtlSource`, `AudioOut`.
Add the permissions and service attribute for `DecSvc` to the manifest as listed in `Main`.
In manifest add this:
AddPermission(android.permission.FOREGROUND_SERVICE)
AddPermission(android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK)
AddPermission(android.permission.WAKE_LOCK)
AddPermission(android.permission.POST_NOTIFICATIONS)
SetServiceAttribute(DecSvc, android:foregroundServiceType, "mediaPlayback")

## License
Copyright (C) 2026 Mario Ančić (9A4AM)

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License version 3 as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of merchantability or fitness for a particular purpose. See the [LICENSE](LICENSE) file for details.

## Credits
- RS41 and M20 decoding is based on the radiosonde decoders by **rs1729**, https://github.com/rs1729/RS (GPL-3.0).
- The RS41 class is a port of `rs41.c` from M5-SDR (https://github.com/9a3zi/M5-SDR) GPL-3.0.
- Built with B4A by Anywhere Software.
- Parts of the code were written with the help of an AI assistant and reviewed by the author.
- "RS41", "M20", "Vaisala" and "Meteomodem" are used only to name the supported sonde types. This project is not affiliated with those companies.

## Disclaimer
Provided as is, without warranty of any kind. Use at your own risk. Respect local regulations when receiving and recovering radiosondes.
