# Shared set contract

The environment is authored once. Gameplay and capture reference the same
environment map/layer; the recipe may add separate entry maps or startup
settings, but it must not clone the set's Content directory. Keep camera,
exposure, quality and HUD differences in their respective use-mode notes.

This is a workflow contract, not a generated map or an Unreal asset. Create the
actual level in the new project's installed-editor template and record the
resulting path in `template-lock.json`'s project differences.
