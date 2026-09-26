# Avagato Maintainer Guidance

This document records development invariants and compatibility rules that must be reviewed before changing Avagato. It is maintainer guidance, not end-user documentation.

## Working rule

Before implementing a change, review this document and the current code for conflicts. If a requested change conflicts with an invariant here, stop and resolve the conflict with the maintainer rather than silently changing or removing established behavior.

When a new architectural or compatibility decision is made, update this document in the same development cycle so future work does not depend on chat history or memory alone.

## Theme compatibility

- Avagato must continue recognizing every previously released **canonical Avagato theme JAR** that Avagato may encounter on an existing installation.
- A new theme release must **not** replace or erase recognition of older canonical theme hashes.
- The current SHA-256 for a theme variant is the hash required for downloading/installing the current artifact. Historical canonical hashes are retained separately for identification and compatibility.
- Theme identification must report the **actual installed variant and version**, not assume that a recognized JAR has the current version.
- Known historical canonical themes must remain safe to update, switch, and remove through Avagato's normal management flows.
- Unknown or locally modified JARs must remain untrusted. Do not classify a JAR as Avagato-managed merely because its manifest, filename, or embedded metadata claims to be Avagato.
- Dark and Light theme versions are independent. Updating one variant must not implicitly change the other's version, hash, or artifact.
- When adding a new canonical theme version, extend the historical identity mapping in `lib/theme.sh`; do not simply overwrite the only recognized hash/version pair.
- Theme-management behavior is shared by Docker and native/legacy installations through `lib/theme.sh`. Changes to detection must be checked against both flows.
- When a theme artifact changes, test recognition of the immediately previous canonical version and its upgrade to the new version. Also verify current-version detection after the upgrade.

### Canonical theme history

Keep this table updated whenever a canonical theme artifact is released.

| Variant | Version | SHA-256 | Status |
| --- | --- | --- | --- |
| Dark | 1.0.0 | `59508a8cab71b3ba8c6f84f51d625a6d239021342be54774a973829adca8ff9b` | Historical; must remain recognized |
| Dark | 1.0.1 | `398b1ce02b9e7eee0ad8fdef000e2ba11c0bcfb8623426fe9ed2a94d14179d06` | Current |
| Light | 1.0.0 | `620add8cf6efa9b45526865f19739093b7679091a25d2218f51d7aa30429fb70` | Current |

## Theme management UX

- Docker and native/legacy theme selection flows must provide a clear cancel path.
- A cancellation must return without installing, switching, removing, or restarting anything.
- Existing canonical older themes must not be treated as unknown third-party JARs merely because a newer Avagato theme exists.
- Safety checks that prevent overwriting unknown visual extensions must be preserved.

## Docker and native/legacy parity

Avagato supports both Docker deployments and the native/legacy Guacamole flow. Shared functionality should remain behaviorally consistent where applicable. Before changing shared helpers, verify their callers in both `lib/docker.sh` and `lib/native.sh`. Do not fix one flow by introducing a regression in the other.

## Release discipline

- Patch releases should point to a known, tested commit using an annotated version tag.
- Before tagging a release, syntax-check the repository shell scripts with `bash -n`.
- For behavior changes, test the affected real workflow where practical rather than relying only on syntax validation.
- Release notes should describe user-visible fixes and compatibility changes.
- A GitHub Release is a permanent versioned snapshot; the normal launcher currently tracks `main`, so changes merged to `main` can reach users before a formal release. Keep that distinction in mind when making changes.

## Maintaining this document

This file is intentionally conservative. Do not delete an invariant merely because the current implementation has changed. If an invariant is intentionally superseded, update this document explicitly and record the replacement behavior.

Add newly discovered compatibility requirements, safety assumptions, and easy-to-forget architectural decisions here as Avagato evolves.
