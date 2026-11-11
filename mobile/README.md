# SixthSense mobile app

The Android-first Flutter client. From this folder, run `flutter pub get`,
`flutter analyze`, and `flutter test`. To run on an Android emulator or USB
device, use `flutter run -d <device-id>`.

## Demo API and network access

The app connects to the Core API at `http://10.0.2.2:8000` by default on the
Android emulator. Set `API_BASE_URL` for another server and `RELAY_BASE_URL`
for the location WebSocket, for example:

```bash
flutter run -d <device-id> \
  --dart-define=API_BASE_URL=http://<server-ip>:8000 \
  --dart-define=RELAY_BASE_URL=ws://<server-ip>:8000/relay/ws
```

For a physical phone, use the laptop's reachable LAN or ZeroTier Managed IP.
The phone must join the same ZeroTier network and be approved by its owner; the
emulator reaches the network through the laptop where it runs. The Core API
must listen on `0.0.0.0:8000`; its health check is `/healthz`. Local sign-in
codes arrive in Mailpit at `http://<server-ip>:8025`.

Plain HTTP is enabled only in `src/debug/AndroidManifest.xml` for local demo
builds. Keep release builds on HTTPS/WSS.

Email OTP and device-key sign-in, contact invite creation/sharing, Telegram
link creation, and journey start/heartbeat/check-in/SOS/end use the demo API.
Telegram linking requires the server's bot token and username. Contact names
and phone numbers stay on the phone; the API receives only the invite label.
The visible journey screen, local timer and opted-in offline SMS remain usable
when the server cannot be reached, but remote contacts will not be alerted.

## Journey timer on Android

Starting a journey runs an ongoing Android foreground service and schedules a
one-shot exact alarm for the next check-in. Android may ask for notification
permission and **Alarms & reminders** access. If exact-alarm access is missing,
the app explains why it is needed and opens the relevant system settings; tap
**Start journey** again after granting it. The **Battery settings** action in
the journey app bar offers the optional battery-optimization exemption. It may
increase battery use.

The service notification does not include the destination. Android stores the
active flag and next check-in deadline for service recovery. If SMS fallback is
enabled, its one journey contact is encrypted with an Android Keystore key and
removed when the journey ends; journey PINs remain in memory. A due alarm
displays a local reminder and, if internet is unavailable, submits an SMS to
the configured contact. The Flutter journey screen is not restored after a
force stop.

## Offline SMS and low-battery mode

Before starting a journey, turn on **Enable offline SMS fallback** and enter one
trusted contact number. Android asks for SMS and location permission. SOS,
covert SOS/duress, and a missed check-in submit an SMS when internet is
unavailable. At 10% battery or lower, the app submits one location SMS and
routes later safety alerts through SMS for that journey. The message uses a
Google Maps link only when Android has a last-known location newer than 30
minutes; otherwise it says location is unavailable. SMS depends on an active
carrier service and plan, and carrier charges may apply. The app cannot confirm
delivery. Ending the journey clears the saved contact and battery state.

## End-to-end location encryption (client layer)

`lib/core/crypto/live_location_cipher.dart` defines version-1 per-recipient
location envelopes. X25519 derives a fresh per-point shared secret, HKDF-SHA256
derives the AES-256-GCM key, and Ed25519 signs the authenticated envelope
header and ciphertext. Coordinates, accuracy, sequence, and timestamp are
inside the ciphertext; the relay-facing JSON contains only session/key IDs and
cryptographic fields. Decryption checks the signature, session/recipient
context, AEAD tag, and caller-provided sequence watermark.

This client crypto layer is not connected to live GPS updates or a relay yet.
Key provisioning and authenticated public-key lookup depend on P2 identity and
trusted-contact APIs; forwarding ciphertext depends on the P2 WebSocket relay.
Callers must verify keys through that trusted directory and keep private keys
in platform secure storage. Never accept a public key supplied only by the
relay.

## Walk With Me screens (prototype)

During an active journey, open **Walk With Me** from the walking-person icon in
the app bar. The traveller preview lets you select a public meeting point, view
a clearly marked sample profile, see a four-digit demo handshake code, and use
a local masked-chat screen. Long phone-number-shaped messages are rejected.
Ending the demo clears chat and selfie bytes from memory, and the completed
screen shows no partner profile or route. Sensitive Walk With Me screens set
Android's `FLAG_SECURE` while they are open.

The companion preview has a local **Go on duty** toggle, a sample request, a
random pose prompt, and an actual camera capture. The captured bytes stay in
memory and the camera plugin's temporary image is deleted after reading it.
This does not perform face matching or liveness verification. Matching,
verified profiles, shared handshake codes, and remote masked chat are not
connected; every preview is labeled as a demo and must not be used to arrange a
real walk. Those services belong to the P3 trust work.

Manual check: start a journey, tap the walking-person icon, try the traveller
preview through the handshake and chat, and confirm an entered phone number is
rejected. Return to Walk With Me, choose companion, turn on duty, open the
sample request, capture the requested pose, and confirm the UI still says no
liveness check is connected. End the demo and confirm the completed page does
not show profile or chat data.

## Map, routes, and anonymous reports (prototype)

From an active journey, tap the map icon to open an OpenFreeMap/MapLibre map.
Location permission is requested only when **Center on my location** is tapped;
the fix remains in app memory. Map tile requests go to OpenFreeMap and reveal
the viewed map area to that provider. Until the P4 routing and risk APIs are
connected, the screen shows **Insufficient data** and gives no route
recommendation. It never labels a place safe.

The report form uses only a fixed list of place conditions; it has no free-text
field for names, phone numbers, or vehicle plates. After the user chooses a
condition and taps **Prepare anonymized preview**, the phone applies planar
Laplace noise (100 m expected radial offset) to the precise fix and rounds the
local time to a two-hour bucket. Only the noisy coordinates, category, and time
bucket are available in the preview payload. The P4 report endpoint is not
connected, so the preview is not uploaded or saved. The P4 service must still
apply its distinct-device/report-count publication threshold before showing
any cluster.

Manual check: start a journey and tap the map icon. Confirm the screen says
**Insufficient data** and does not claim to provide a safe route. Tap **Report a
place issue**, choose a condition, allow location when asked, and prepare the
preview. Confirm it shows a coarse area and two-hour bucket, says nothing was
uploaded, and offers no text input.

## Android SOS shortcuts (prototype)

The Android app supports a foreground volume sequence (Volume Up → Volume Down
→ Volume Up within four seconds), a user-added **SixthSense SOS** Quick Settings
tile, and a user-added **SOS** home-screen widget. The volume sequence is
recognized while the app screen is open; Android may still change the volume
while the sequence is entered. The tile and widget post a local **SOS
requested** notification and can submit an SMS when an opted-in journey is
offline. On Android 13 and later, allow notifications for the confirmation to
appear.

To add the tile, open Quick Settings, choose **Edit**, and drag **SixthSense
SOS** into the active tiles. To add the widget, long-press the launcher home
screen, open **Widgets**, find SixthSense, and place the **SOS** widget.

Sign-in uses **email, not SMS**, because email codes are free (PLANNER §3b).
The first sign-in registers an Android Keystore P-256 key; later launches use
the signed device challenge without another email code. The access token is
encrypted with an Android Keystore AES key. Trusted contacts can be skipped
with **Do this later**. Invite acceptance on a contact's device remains a
separate part of the contact-side flow.

### Manual Android verification

1. Start the app, open the journey flow, enter a destination and two different
   four-digit PINs, then start a one-minute journey.
2. Allow notifications. If prompted, allow **Alarms & reminders**, return to the
   app, and tap **Start journey** again.
3. Confirm the ongoing journey notification appears. Send the app to the
   background and wait one minute; confirm **Journey check-in due** appears.
4. Return to the app and check in. Confirm the timer resets and the old due
   reminder is cancelled. End the journey and confirm the ongoing notification
   disappears.
5. Optionally use **Battery settings** to request the battery exemption, then
   repeat the background check-in while battery saver is enabled.
6. Repeat steps 1–5 on Xiaomi, Oppo, Vivo, Realme, or Samsung hardware to check
   vendor-specific battery restrictions. The emulator cannot validate those.
7. With the app open, press Volume Up, Volume Down, then Volume Up within four
   seconds. Confirm **SOS requested** appears. Add and tap the Quick Settings
   tile, then add and tap the home-screen widget; each should show the same
   local notification. Dismiss it between triggers if needed.
8. On a phone with an active SIM, start a journey with SMS fallback enabled,
   grant SMS and location permission, then disable Wi-Fi and mobile data while
   leaving cellular service available. Trigger SOS and confirm the chosen
   contact receives an SMS. The emulator has no carrier SMS service.
9. For low-battery verification, repeat with the phone battery at 10% or lower;
   confirm the contact receives one low-battery SMS and the journey notification
   reports low-battery mode. This requires a physical phone and SIM.
