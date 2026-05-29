# TeleglitchDME Mod Manager — minimal WinForms GUI.
#
# Lists every folder under <GamePath>/mods/ as a checkbox. Reading
# manifest.lua (if present) for name/version/description. Reads/writes
# <GamePath>/modloader/enabled.txt on Save.
#
# Run from inside the installed modloader/ folder so paths resolve to the
# game directory above it. Or pass -GamePath explicitly.
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\manager.ps1
#         .\manager.ps1 -GamePath "E:\SteamLibrary\steamapps\common\TeleglitchDME"

param(
    [string]$GamePath
)

$ErrorActionPreference = "Stop"

# Resolve game path: prefer arg, fall back to parent of this script's folder.
if (-not $GamePath) {
    $GamePath = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path (Join-Path $GamePath "Teleglitch.exe"))) {
    Write-Error "Doesn't look like a TeleglitchDME folder: $GamePath"
}

$modsDir    = Join-Path $GamePath "mods"
$enabledTxt = Join-Path $GamePath "modloader\enabled.txt"

# --- Read mod folders and manifests ---------------------------------------
function Read-ManifestField {
    param([string]$path, [string]$field)
    if (-not (Test-Path $path)) { return $null }
    $content = Get-Content $path -Raw
    # Naive parse: look for `field = "value"` or `field = 'value'`
    if ($content -match "$field\s*=\s*[`"']([^`"']+)[`"']") { return $Matches[1] }
    return $null
}

$mods = @()
if (Test-Path $modsDir) {
    foreach ($dir in (Get-ChildItem $modsDir -Directory | Sort-Object Name)) {
        $manifest = Join-Path $dir.FullName "manifest.lua"
        $mods += [PSCustomObject]@{
            Folder      = $dir.Name
            Name        = (Read-ManifestField $manifest "name")        ?? $dir.Name
            Version     = (Read-ManifestField $manifest "version")     ?? "?"
            Description = (Read-ManifestField $manifest "description") ?? ""
        }
    }
}

# --- Read currently-enabled list ------------------------------------------
$enabled = @{}
if (Test-Path $enabledTxt) {
    foreach ($line in (Get-Content $enabledTxt)) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith("#")) { $enabled[$t] = $true }
    }
}

# --- WinForms UI ----------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text          = "TeleglitchDME Mod Manager"
$form.Size          = New-Object System.Drawing.Size(620, 480)
$form.StartPosition = "CenterScreen"
$form.MinimumSize   = New-Object System.Drawing.Size(500, 320)

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text     = "Game: $GamePath"
$pathLabel.Location = New-Object System.Drawing.Point(10, 10)
$pathLabel.Size     = New-Object System.Drawing.Size(600, 18)
$pathLabel.Anchor   = "Top,Left,Right"
$form.Controls.Add($pathLabel)

$list = New-Object System.Windows.Forms.CheckedListBox
$list.Location      = New-Object System.Drawing.Point(10, 35)
$list.Size          = New-Object System.Drawing.Size(580, 320)
$list.Anchor        = "Top,Left,Right,Bottom"
$list.CheckOnClick  = $true
$list.Font          = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($list)

$detail = New-Object System.Windows.Forms.Label
$detail.Location    = New-Object System.Drawing.Point(10, 365)
$detail.Size        = New-Object System.Drawing.Size(580, 38)
$detail.Anchor      = "Bottom,Left,Right"
$form.Controls.Add($detail)

foreach ($mod in $mods) {
    $label = "{0,-22} v{1,-8} {2}" -f $mod.Folder, $mod.Version, $mod.Name
    [void]$list.Items.Add($label, [bool]$enabled[$mod.Folder])
}

$list.Add_SelectedIndexChanged({
    $i = $list.SelectedIndex
    if ($i -ge 0 -and $i -lt $mods.Count) {
        $detail.Text = "$($mods[$i].Folder) — $($mods[$i].Description)"
    } else {
        $detail.Text = ""
    }
})

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text       = "Save"
$btnSave.Location   = New-Object System.Drawing.Point(420, 410)
$btnSave.Size       = New-Object System.Drawing.Size(80, 26)
$btnSave.Anchor     = "Bottom,Right"
$form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text     = "Close"
$btnCancel.Location = New-Object System.Drawing.Point(510, 410)
$btnCancel.Size     = New-Object System.Drawing.Size(80, 26)
$btnCancel.Anchor   = "Bottom,Right"
$btnCancel.DialogResult = "Cancel"
$form.Controls.Add($btnCancel)

$btnSave.Add_Click({
    $lines = @("# TeleglitchDME enabled mods — managed by manager.ps1")
    for ($i = 0; $i -lt $list.Items.Count; $i++) {
        if ($list.GetItemChecked($i)) { $lines += $mods[$i].Folder }
    }
    Set-Content -Path $enabledTxt -Value $lines -Encoding utf8
    [System.Windows.Forms.MessageBox]::Show(
        "Saved $($lines.Count - 1) enabled mod(s) to:`n$enabledTxt",
        "Saved", "OK", "Information") | Out-Null
})

[void]$form.ShowDialog()
