# Avagato Maintainer Guidance

This document records development invariants and compatibility rules that must be reviewed before changing Avagato. It is maintainer guidance, not end-user documentation.

## Working rule

Before implementing a change, review this document and the current code for conflicts. If a requested change conflicts with an invariant here, stop and resolve the conflict with the maintainer rather than silently changing or removing established behavior.

When a new architectural or compatibility decision is made, update this document in the same development cycle so future work does not depend on chat history or memory alone.

## Scope and environment boundaries

These are intentional product boundaries, not missing features.

- Docker is the recommended path for new Avagato installations. The Docker deployment is not Proxmox-specific and may run on a suitable Linux Docker host.
- Native/legacy support exists specifically for the tested Proxmox VE Community Scripts Guacamole 1.6.0 layout. It is not a general-purpose Guacamole or Tomcat modifier.
- Avagato does **not** migrate Guacamole databases between native and Docker deployments. A compatible existing native installation may be enhanced in place; a new installation should normally use Docker. Treat native-to-Docker or Docker-to-native migration as out of scope unless the maintainer explicitly revisits this product decision.
- Avagato must refuse to run directly on a Proxmox VE host.
- Avagato must refuse ambiguous mixed environments containing both a supported native installation and a Docker Guacamole deployment rather than choosing one automatically.
- Avagato must not take over an unknown/non-Avagato Docker Guacamole stack.
- Avagato must refuse unsupported native layouts or versions rather than guessing how to modify them.
- Avagato intentionally provides HTTP only. Reverse proxy and TLS management are outside its scope.
- The Docker deployment currently uses Guacamole/guacd 1.6.0 and PostgreSQL 17. Native compatibility checks are intentionally tied to the tested Guacamole 1.6.0 Community Scripts layout.

## Conservative modification policy

Avagato should modify only resources and settings it clearly owns or has positively identified.

- Prefer refusal over guessing when state is ambiguous.
- Docker Compose edits must be limited to Avagato-managed settings. Preserve unrelated user configuration, including unrelated existing `guacd` volume mappings.
- Validate candidate Compose configuration before replacing the live configuration.
- The reconcile action applies the current Avagato-managed configuration and starts/reconciles the deployment; it is not a reinstall.
- Do not overwrite, remove, or reinterpret an unknown artifact merely because it occupies a filename or location normally managed by Avagato.
- Destructive behavior must require positive identification of Avagato-owned state where practical.

## RDP drive sharing and storage ownership

RDP drive storage is optional and is deliberately separated from Proxmox host storage management.

- Avagato manages the Docker mapping from `/opt/avagato/data/drive` on the Docker host/LXC to `/drive` inside `guacd`.
- Avagato does **not** create or manage a Proxmox host bind mount. External storage and any Proxmox/LXC UID/GID mapping remain the user's responsibility.
- For a **new ordinary local drive directory created by Avagato**, create/configure it for the pinned `guacd` runtime identity (currently UID/GID `1000:1000`) so drive sharing works out of the box.
- For a **pre-existing drive directory or externally supplied/bind-mounted path**, do **not** automatically `chown`, `chmod`, or recursively alter ownership/permissions. Existing storage may have requirements Avagato cannot safely infer.
- If an existing drive path does not appear writable by `guacd`, warn and provide actionable guidance instead of silently changing it.
- Never blindly perform a recursive ownership change on externally managed storage.
- Disabling RDP drive sharing removes only Avagato's Docker mapping. It must **not delete the host drive directory or its data**.
- Preserve unrelated existing `guacd` volume mappings when enabling or disabling Avagato's drive mapping.
- RDP drive sharing is configured per Guacamole connection after the storage mapping is available; Avagato does not force it on every connection.

## Native/legacy preservation and restore

The native path is intentionally reversible for the changes Avagato manages.

- Before native changes, user-facing guidance must recommend a full Proxmox backup or snapshot. Avagato's preservation/restore behavior is not a substitute for a complete backup.
- The Tomcat root change must preserve the original ROOT application and replace `/` only with the Avagato redirect to `/guacamole/`; do not change Guacamole's `/guacamole/` context path.
- Tomcat stock applications that Avagato disables/removes from active `webapps` must be preserved for restoration rather than destroyed.
- Native restore must refuse ambiguous collisions, such as both a preserved and live Tomcat application being present, rather than choosing which copy to overwrite.
- Native theme restore/removal must continue requiring a recognized canonical Avagato artifact.
- Native TOTP uses the official Apache Guacamole TOTP extension matching the supported Guacamole version.
- Removing or disabling TOTP support must **not** delete users' TOTP enrollment data from the Guacamole database. Avagato does not directly purge users' TOTP secrets.

## Installation and deployment safety

- Installation and management actions should use explicit user selection/confirmation for consequential changes.
- Do not automatically install Docker merely because it is absent. Environment detection and deployment selection must remain deliberate.
- Generated database credentials and other deployment secrets are installation state and must not be exposed unnecessarily.
- Avagato's Docker deployment is self-contained under `/opt/avagato`; the current installer does not offer an arbitrary installation root. Changing that is a product/design decision, not a casual refactor.

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
