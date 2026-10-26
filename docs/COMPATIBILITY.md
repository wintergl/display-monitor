# Compatibility and limitations

| Capability | Requirements and limits |
| --- | --- |
| App deployment target | macOS 13. Not all versions have received native acceptance testing. |
| Published binary | Apple Silicon / arm64, version 0.1.1 build 59. |
| Menu bar collapse and ordering | macOS 27+; collapse also needs runtime-resolvable system APIs and a launch from `/Applications`. Required permissions are checked before use. |
| Native hiding implementation | Uses the private MenuBarClientCore framework through a runtime bridge. Future system versions can break it. No general App Store compatibility claim. |
| Clock / Notification Center | Clicking the system clock may temporarily reveal hidden icons. |
| Screenshots and recording | Screen Recording permission. Capture paths depend on available OS APIs. Protected content may be black. |
| Recording output | MP4 video; audio is not implemented. |
| Long screenshots | Scrolling/stitching can depend on the target application's rendering. Review the seam and final result. |
| Concurrent Monitor + capture | Gated against runtime-specific evidence. An unknown combination may be refused; turn Monitor off before recording. |
| Extended displays | Must be exposed by macOS as shareable. Mirrored displays are not independent sources. AirPlay, Sidecar, DisplayLink, and virtual displays are best effort. |
| Direct pointer control | Accessibility permission, distinct source/target displays, and a visible, unobscured preview. Hold the selected modifier over the preview to control. |
| GIF | Experimental, disabled by default. |
| Interface language | Primarily Simplified Chinese. English localization contributions welcome. |
| Intel / old OS versions | Source compatibility is not native acceptance; not validated as downloadable releases. |

The published build and local checks do not establish 4K, 30-minute recording, every multi-display arrangement, or every macOS version as accepted. When reporting a problem, include only the OS version, app build, hardware family (not a serial number), and reproduction steps.
