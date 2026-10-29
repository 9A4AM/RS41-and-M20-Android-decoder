# RS41-and-M20-Android-decoder

RS41 and M20 radiosonde decoder for Android, written in pure B4A (Basic4Android).
Receive only. No data is uploaded anywhere.

![Screen1](https://github.com/user-attachments/assets/7a13a4d7-2f06-46e4-95b1-4d21bab166e4)
![Screen2](https://github.com/user-attachments/assets/32ee4e5b-ad1f-4938-8057-a7b79c5e13f3)

## Features
- Decodes Vaisala **RS41** and Meteomodem **M20**; the sonde type is detected automatically after the app starts.
- Shows position, altitude, speed, climb rate, heading, UTC time, satellites and decoder diagnostics, plus a signal level bar.
- **Geo App** button opens your map application and transfers the coordinates, with a marker named after the payload ID.
- Sound modes: off, beep on each valid frame, or live FM audio.
- Keeps decoding in the background (foreground service with notification).
- Press **Back** twice to exit, so you do not close the app by accident.
- The last received telemetry is saved when the app is closed. **Long press Stop** (about 3 s) to view it.
- Languages: English and Croatian.

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
- The RS41 class is a port of `rs41.c` from M5-SDR (https://github.com/9a3zi/M5-SDR).
- Built with B4A by Anywhere Software.
- Parts of the code were written with the help of an AI assistant and reviewed by the author.
- "RS41", "M20", "Vaisala" and "Meteomodem" are used only to name the supported sonde types. This project is not affiliated with those companies.

## Disclaimer
Provided as is, without warranty of any kind. Use at your own risk. Respect local regulations when receiving and recovering radiosondes.
