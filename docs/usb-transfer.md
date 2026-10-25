# Direct USB transfer — beta

## Setup

Install `libimobiledevice` with Homebrew (`brew install libimobiledevice`). FFmpeg/ffprobe remain required for ringtone preparation. The app dynamically loads the installed library; third-party device libraries are not bundled. This feature does not require Python, a jailbreak, a developer tunnel, or an iPhone companion app.

1. Connect the iPhone to the Mac with a data-capable USB cable.
2. Unlock the phone. In Devices, click Refresh and select the phone.
3. Choose Check connection. If requested, approve Trust This Computer on the iPhone. The app displays the reported device name and iOS version.
4. Select the tones to send in the library. Choose Review & send to iPhone, review the named device and tone count, and confirm. Up to 200 selected tones can be sent per operation.
5. Check Settings → Sounds & Haptics → Ringtone. If needed, close and reopen Settings. The default ringtone and contact assignments are set manually on the phone.

## Compatibility limits

This is an experimental media-service transfer, not Apple's official synchronization interface. The target iPhone is reported to use iOS 27; no physical iOS 27 device was available for verification. Copying bytes and verifying the ringtone index does not prove that a particular iOS build will expose the tone in Settings. Use Finder or the AirDrop/GarageBand alternative when compatibility transfer is unavailable.

The implementation reads existing ringtone indexes at `/iTunes_Control/Ringtones/Ringtones.plist` or the older `/iTunes_Control/iTunes/Ringtones.plist`. It preserves the detected location and existing root/entry metadata. If no index exists it creates the modern ringtone index. Unsupported index structures are rejected. It does not modify MediaLibrary.sqlitedb, restore firmware, erase media, or set a default ringtone.

## Integrity and recovery

- Exported M4R clips are uploaded under unique filenames, staged, and read back before registration. Existing tone files are not replaced. Sending a tone again may create an additional entry.
- The original index is backed up under `device-backups/<device-ID-hash>/` inside the Mac library directory. Backups contain the index's existing ringtone metadata; device IDs are not used as plain-text folder names.
- After audio upload, the app rereads the original index and aborts if it changed. It stages and verifies the merged index, then commits it with a media-service rename and verifies the result. A device that refuses the required rename reports an error.
- Failures before index commit remove only newly created upload files. An ambiguous disconnect during commit retains the uploaded audio, because the index may already reference it. The app does not automatically retry or restore an old index over newer device data.
- The Show transfer backup button reveals the saved index on the Mac after a completed transfer. A backup is also created before writes on attempts that later fail. Do not restore it blindly after subsequent Finder syncs.

Avoid concurrent Finder/iTunes synchronization during a transfer. If the connection drops, reconnect and inspect the phone before trying again.

## Validation

Real audio encoding/export tests pass. A simulated device store checks preserved existing entries and unknown metadata, exact audio read-back, index backups, modern/legacy index selection, corrupt uploads, concurrent index changes, and ambiguous commit handling. These tests do not validate Apple's firmware behavior or physical USB delivery. No ringtone was sent to a physical phone during implementation.

## Interfaces and credits

USB access uses the independently developed [libimobiledevice](https://libimobiledevice.org/) project, installed separately. The small C bridge calls its public device, lockdown, and AFC interfaces; the app's transaction and SwiftUI code are local source. Ringtone index layouts are private iOS implementation details and can change. This project is independent of Apple.
