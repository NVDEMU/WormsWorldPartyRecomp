# Worms World Party Recompiled — built-in PSXRecomp mods

The release build stages all framework builtin packages automatically. This title-owned catalog intentionally overrides three framework manifests at the same package/version so the launcher can show advanced features that the upstream manifests mark hidden. It does not copy plugin code or change runtime implementations.

All features are **off by default**. Enable only what you intend to test.

## Included built-ins

- **HD Texture Packs** — load compatible PNG/JPEG/WebP replacements and/or dump textures for editing. Replacements display with OpenGL; no WWP artwork is bundled by this catalog.
- **PGXP Precision** — optional sub-pixel geometry and perspective-correct texturing. Coverage varies by build and scene; supersampling is needed for visible effects. Precise culling changes guest-visible results and should remain off unless tested.
- **Bezel Artwork** — show a selected image behind the game in letterbox/pillarbox margins; presentation-only.
- **CD Speed (Advanced)** — alter emulated CD sector timing to shorten some loads. Timing changes can reveal game compatibility issues; increase gradually and disable if a load stalls.
- **8 MB Main RAM (Advanced)** — for patches that specifically require expanded PS1 RAM, not a general performance boost. Leave off for normal WWP play.
- **Fast Loading (Legacy)** — framework's generic host-pacing heuristic. It is not a WWP-specific loading policy and may not help; use only for experiments.

The framework also stages future builtin packages automatically unless the project explicitly excludes them. The list above documents the builtins in the PSXRecomp revision pinned by this repository, not a promise that every optional mode is fully validated with Worms World Party.

## Safety and compatibility

- Keep risky/experimental options disabled for normal play.
- Change mods only while the game is closed, then relaunch so the new session plan is resolved.
- Before trying timing or memory-related options, back up saves and avoid overwriting a known-good save slot.
- Mods do not include the retail disc or retail BIOS. Those remain the player's responsibility.
