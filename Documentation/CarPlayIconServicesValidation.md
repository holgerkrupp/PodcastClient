# CarPlay IconServices validation

The October 19, 2026 `com.apple.CarPlayApp` reports contain simulated, lightweight `com.apple.iconservices: Failed to create placeholder image` diagnostics. They do not identify an Up Next image or prove an Up Next crash. The application-side check validates the primary icon and every alternate icon declared in the iOS target:

```sh
Scripts/validate-app-icons.py
```

The script checks declared names against `.icon` bundles, verifies referenced layer assets, rasterizes image layers, and asks `actool` to compile the primary and alternate icons for iOS Simulator. This confirms asset consistency and renderability; it does not establish whether these assets caused Apple's diagnostic.

## Reproduction matrix

Record the app build, exact iOS build, iPhone model, vehicle/head-unit model, wired or wireless connection, selected icon, and whether Up Next was running. Record visible symptoms and timestamps without podcast titles, feed URLs, or account data.

| Run | Up Next | Icon | CarPlay sequence |
| --- | --- | --- | --- |
| 1 | Not installed or not running | N/A | Connect, launch another audio app, disconnect, reconnect, lock and unlock iPhone |
| 2 | Installed, not running | Primary | Connect, launch another audio app, disconnect, reconnect, lock and unlock iPhone |
| 3 | Running | Primary | Cold launch, connect, browse Inbox and Up Next, play, disconnect, reconnect |
| 4 | Running | Each alternate icon | Repeat run 3 after selecting each icon while parked |
| 5 | Running | Primary and alternates | Repeat with rows that have artwork and rows without artwork |

Run on the current stable iOS release and the latest beta on the same device/head unit when available. Compare log timestamps with icon selection, CarPlay connection changes, and whether Up Next is running. The current asset validator confirms all 9 configured alternate icons compile; simulator and vehicle testing is still required to evaluate the system diagnostic.

If the same fault reproduces with Up Next absent, file Apple Feedback Assistant with the original `.ips` reports, a sysdiagnose, exact app/iOS build and device versions, head-unit/car model, connection type, and reproducible steps. Record the Feedback ID here or in issue #364. Do not claim an application fix based only on the asset check.
