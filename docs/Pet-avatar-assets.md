# Pet avatar assets

The nine unmodified WebP sprite sheets in `Sources/Filicon/Resources/PetAvatars`
were copied from the installed Codex/ChatGPT desktop application's bundled
resources at the user's request on 2026-09-17. Character artwork belongs to its
respective rights holders; this repository does not grant a license to that art.
Verify redistribution rights before publishing these assets with a release.

The avatar renderer displays only the first idle frame of the 8-column,
11-row sheet (192 × 208 pixels per frame). It caches decoded avatar frames,
not full sheets. Names are proper names and remain untranslated.

Mini is a compact toolbar presentation, not a character, and is not included.
Existing character/custom-image avatars remain unchanged. Pet choices are
persisted as stable IDs, not machine-specific paths.
