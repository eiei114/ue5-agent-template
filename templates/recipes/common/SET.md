# Shared set contract

The environment is authored once. Gameplay and capture reference the same
environment map/layer; the recipe may add separate entry maps or startup
settings, but it must not clone the set's Content directory. Keep camera,
exposure, quality and HUD differences in their respective use-mode notes.

This is a workflow contract, not a generated map or an Unreal asset. Create the
actual level in the new project's installed-editor template, then record the
resulting path in `template-lock.json`'s project differences with the one
supported command. Run it from the ue5-agent-template source checkout, never by
editing the lock by hand and never by regenerating into the same directory:

```powershell
.\scripts\Update-UETemplateProjectDifference.ps1 -LockPath <this project>\template-lock.json -Difference 'Map: /Game/<Name>/Maps/<Level>'
```

The script `scripts/Update-UETemplateProjectDifference.ps1` is source checkout relative and not bundled into this project. A value is `<label>: <value>`: 200 characters at most, no newline or tab, no host path (`C:\...`, a leading `/` or `\`, UNC) and no `..` segment. The script changes only `project_differences` and stops, leaving the lock untouched, on anything else.
