# Origin

Omi Local is developed independently at [skywinder/omi-local](https://github.com/skywinder/omi-local). Next builds from the Omi Flutter revision pinned in [clients/next/upstream.json](clients/next/upstream.json). Third-party dependencies and original license notices remain part of the project.

Original project: [BasedHardware/omi](https://github.com/BasedHardware/omi).
Upstream baseline: `2ce52f13f4724eee989158da6318dc6f27aa744e`.

Selective backports are tracked in [upstream-sync.json](upstream-sync.json).
See [the synchronization procedure](docs/UPSTREAM_SYNC.md) for comparison scope,
accepted changes, pending candidates and validation. The original baseline below
remains provenance; an observed newer upstream head does not replace it.

This snapshot includes the local Personal Team/offline changes
(`8bbf848d905b32de395e8ee2fc9840e96ff9d0ee`) and WAV recording
(`bae122dbb48d0fe46bcab384736dee239328234f`). These identify the original local
commits for comparison; they are not ancestors of the new history.

Snapshot preparation removed components outside the MVP, demonstration materials,
and deployment workflows, and updated the README and top-level commands.
Embedded upstream Team IDs were replaced with `OMI_APPLE_TEAM_ID`, and Firebase
presets with local emulator fixtures. The upstream deployment verification token
and generated Custom.xcconfig were excluded. CV1 reception, WAV recording, and
network restrictions were preserved.

The [MIT license and Based Hardware Contributors notice](LICENSE), along with
the original component agent guides, are retained. Dependency and third-party
asset licenses continue to apply to their respective components.
