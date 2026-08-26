# ============================================================
# ReAnote — Graphical interface (PowerShell + Windows Forms)
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- Force UTF-8 when reading the output of external processes (wsl.exe) ----
# Windows PowerShell 5.1 has TWO independent encoding properties:
# [Console]::OutputEncoding (what PowerShell WRITES to the console) and
# [Console]::InputEncoding (what PowerShell READS from a child process like
# wsl.exe). By default both use the system's "ANSI" code page (here, CP850),
# NOT UTF-8 — and InputEncoding is the one that matters for capturing the
# output of "wsl.exe bash -lc ...". Without setting InputEncoding, any
# multi-byte UTF-8 character coming from WSL gets decoded incorrectly with
# CP850 and the string in memory ends up corrupted, even though the log's
# original bytes were correct — confirmed with a real test: the captured
# bytes were valid UTF-8, but PowerShell was interpreting them with the
# wrong encoding. Both properties are set for completeness (Output too, in
# case something needs it later).
try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # Not critical on its own: log parsing reads UTF-8 explicitly anyway
    # (see Invoke-WslUtf8) regardless of whether this succeeds.
}

# ---- Disable Windows console "Quick Edit Mode" ----
# With Quick Edit Mode on (the Windows default), a single click inside the
# console window puts the buffer into selection mode and FREEZES all new
# output until Esc is pressed or you click again — the process keeps
# running underneath, but the log's "tail -f" looks stuck ("doesn't update
# until I touch it"). This is disabled at the user level (HKCU, no admin
# rights needed) the first time this window is opened; from then on ALL new
# Windows consoles on this computer stop suffering from the problem, not
# just the ones ReAnote opens.
function Disable-QuickEditMode {
    try {
        $key = "HKCU:\Console"
        $current = Get-ItemProperty -Path $key -Name "QuickEdit" -ErrorAction SilentlyContinue
        if ($null -eq $current -or $current.QuickEdit -ne 0) {
            Set-ItemProperty -Path $key -Name "QuickEdit" -Value 0 -Type DWord -Force
        }
    } catch {
        # If for some reason the registry can't be touched (permissions,
        # company policy...) it's not fatal: the pipeline still works fine,
        # the log window may just look frozen if clicked.
    }
}
Disable-QuickEditMode

# ---- Automatically locate the ReAnote disk ----
function Find-ReAnoteDrive {
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.IsReady) {
            $candidate = Join-Path $d.RootDirectory.FullName "ReAnote"
            if (Test-Path (Join-Path $candidate "reanotar.sh")) {
                return $d.Name.Substring(0,1)  # "F"
            }
        }
    }
    return $null
}

$driveLetter = Find-ReAnoteDrive

# ---- Converts any Windows path ("F:\folder\file") to a WSL path ("/mnt/f/folder/file") ----
function Convert-ToWslPath {
    param([string]$WinPath)
    if ([string]::IsNullOrWhiteSpace($WinPath)) { return $WinPath }
    if ($WinPath -match '^([A-Za-z]):\\(.*)$') {
        $letra = $Matches[1].ToLower()
        $resto = $Matches[2] -replace '\\', '/'
        return "/mnt/$letra/$resto"
    }
    return $WinPath -replace '\\', '/'
}

# ---- Main window ----
$form = New-Object System.Windows.Forms.Form
$form.Text = "ReAnote — Variant re-annotation"
$form.Size = New-Object System.Drawing.Size(640, 696)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# ---- Custom window/taskbar icon ----
# Generated in memory from a small bitmap (without depending on an external
# .ico file that could get lost when copying the folder) so the window
# doesn't use PowerShell's generic icon in the taskbar.
function New-ReAnoteIcon {
    try {
        $bmp = New-Object System.Drawing.Bitmap(32, 32)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(44, 110, 155))
        $g.FillEllipse($bgBrush, 1, 1, 30, 30)
        $font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString("R", $font, $textBrush, (New-Object System.Drawing.RectangleF(0,0,32,32)), $fmt)
        $g.Dispose()
        $hIcon = $bmp.GetHicon()
        return [System.Drawing.Icon]::FromHandle($hIcon)
    } catch {
        return $null
    }
}
$reanoteIcon = New-ReAnoteIcon
if ($reanoteIcon) { $form.Icon = $reanoteIcon }

$y = 15

# ---- Disk letter notice ----
$lblDrive = New-Object System.Windows.Forms.Label
$lblDrive.Location = New-Object System.Drawing.Point(15, $y)
$lblDrive.Size = New-Object System.Drawing.Size(380, 20)
if ($driveLetter) {
    $lblDrive.Text = "ReAnote disk detected at: $driveLetter`:\"
    $lblDrive.ForeColor = [System.Drawing.Color]::DarkGreen
} else {
    $lblDrive.Text = "The ReAnote disk was not detected automatically. Connect it and reopen this window."
    $lblDrive.ForeColor = [System.Drawing.Color]::DarkRed
}
$form.Controls.Add($lblDrive)

# ---- Sequencing type: exome (wes) or whole genome (wgs) ----
# Placed to the right of the disk notice (free space on that row) so it's
# always visible from the start without taking up its own row. Only applies
# to the modes that call variants from scratch (full/call); the rest
# (annotate/liftover/vep/filter) start from an already-generated VCF/gVCF,
# where the sequencing type was already fixed in an earlier step.
$comboTipo = New-Object System.Windows.Forms.ComboBox
$comboTipo.Location = New-Object System.Drawing.Point(400, ($y - 2))
$comboTipo.Size = New-Object System.Drawing.Size(215, 24)
$comboTipo.DropDownStyle = "DropDownList"
$comboTipo.Items.AddRange(@("wgs (whole genome)", "wes (exome)"))
$comboTipo.SelectedIndex = 0
$form.Controls.Add($comboTipo)
$y += 30

# ---- Mode (annotate / liftover / full / single steps) ----
$lblModo = New-Object System.Windows.Forms.Label
$lblModo.Text = "What do you have?"
$lblModo.Location = New-Object System.Drawing.Point(15, $y)
$lblModo.Size = New-Object System.Drawing.Size(520, 20)
$form.Controls.Add($lblModo)
$y += 22

$comboModo = New-Object System.Windows.Forms.ComboBox
$comboModo.Location = New-Object System.Drawing.Point(15, $y)
$comboModo.Size = New-Object System.Drawing.Size(520, 24)
$comboModo.DropDownStyle = "DropDownList"
$comboModo.Items.AddRange(@(
    "VCF already in hg38 (annotate)",
    "VCF in hg19/hg37 (liftover)",
    "Raw FASTQ (full, all 4 steps)",
    "-- Single step only --",
    "FASTQ -> BAM (align only)",
    "BAM -> gVCF (call variants only)",
    "gVCF -> filtered VCF (filter only)",
    "Filtered VCF + BAM -> annotated VCF (VEP only)"
))
$comboModo.SelectedIndex = 0
$form.Controls.Add($comboModo)
$y += 34

# Indices of the single-step subcommands, and prevent the non-selectable
# visual separator "-- Single step only --" from being picked.
$SOLO_PASO_ALINEAR = 4
$SOLO_PASO_LLAMAR = 5
$SOLO_PASO_FILTRAR = 6
$SOLO_PASO_VEP = 7

# ---- Input file / folder ----
$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text = "Input file or folder (any location):"
$lblInput.Location = New-Object System.Drawing.Point(15, $y)
$lblInput.Size = New-Object System.Drawing.Size(520, 20)
$form.Controls.Add($lblInput)
$y += 22

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Location = New-Object System.Drawing.Point(15, $y)
$txtInput.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($txtInput)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Browse..."
$btnBrowse.Location = New-Object System.Drawing.Point(435, $y)
$btnBrowse.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($btnBrowse)
$y += 34

# ---- Sample name ----
$lblSample = New-Object System.Windows.Forms.Label
$lblSample.Text = "Sample name:"
$lblSample.Location = New-Object System.Drawing.Point(15, $y)
$lblSample.Size = New-Object System.Drawing.Size(520, 20)
$form.Controls.Add($lblSample)
$y += 22

$txtSample = New-Object System.Windows.Forms.TextBox
$txtSample.Location = New-Object System.Drawing.Point(15, $y)
$txtSample.Size = New-Object System.Drawing.Size(520, 24)
$form.Controls.Add($txtSample)
$y += 34

# ---- Optional BAM (only for "annotate"/"liftover", for phasing with WhatsHap) ----
$lblBam = New-Object System.Windows.Forms.Label
$lblBam.Text = "Associated BAM (optional, for phasing with WhatsHap):"
$lblBam.Location = New-Object System.Drawing.Point(15, $y)
$lblBam.Size = New-Object System.Drawing.Size(520, 20)
$form.Controls.Add($lblBam)
$y += 22

$txtBam = New-Object System.Windows.Forms.TextBox
$txtBam.Location = New-Object System.Drawing.Point(15, $y)
$txtBam.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($txtBam)

$btnBrowseBam = New-Object System.Windows.Forms.Button
$btnBrowseBam.Text = "Browse..."
$btnBrowseBam.Location = New-Object System.Drawing.Point(435, $y)
$btnBrowseBam.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($btnBrowseBam)
$y += 26

$lblBamHint = New-Object System.Windows.Forms.Label
$lblBamHint.Text = "The .bai file must be in the same folder as the .bam, with the same name."
$lblBamHint.Location = New-Object System.Drawing.Point(15, $y)
$lblBamHint.Size = New-Object System.Drawing.Size(520, 18)
$lblBamHint.ForeColor = [System.Drawing.Color]::DimGray
$lblBamHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($lblBamHint)
$y += 28

# ---- Target regions BED file (only required if type is wes) ----
$lblBed = New-Object System.Windows.Forms.Label
$lblBed.Text = "Regions BED file (required if exome):"
$lblBed.Location = New-Object System.Drawing.Point(15, $y)
$lblBed.Size = New-Object System.Drawing.Size(520, 20)
$form.Controls.Add($lblBed)
$y += 22

$txtBed = New-Object System.Windows.Forms.TextBox
$txtBed.Location = New-Object System.Drawing.Point(15, $y)
$txtBed.Size = New-Object System.Drawing.Size(410, 24)
$txtBed.Enabled = $false
$form.Controls.Add($txtBed)

$btnBrowseBed = New-Object System.Windows.Forms.Button
$btnBrowseBed.Text = "Browse..."
$btnBrowseBed.Location = New-Object System.Drawing.Point(435, $y)
$btnBrowseBed.Size = New-Object System.Drawing.Size(100, 24)
$btnBrowseBed.Enabled = $false
$form.Controls.Add($btnBrowseBed)
$y += 34

$btnBrowseBed.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "BED files (*.bed;*.bed.gz)|*.bed;*.bed.gz|All files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq "OK") { $txtBed.Text = $dlg.FileName }
})

# The BED field is only enabled when the selected type is "wes" (index 1).
$comboTipo.Add_SelectedIndexChanged({
    $esWes = $comboTipo.SelectedIndex -eq 1
    $txtBed.Enabled = $esWes
    $btnBrowseBed.Enabled = $esWes
    if (-not $esWes) { $txtBed.Text = "" }
})

# ---- Optional output folder (defaults to outputs\ on the disk) ----
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = "Output folder (optional, e.g. your desktop - if left blank, outputs\ on the disk is used):"
$lblOutput.Location = New-Object System.Drawing.Point(15, $y)
$lblOutput.Size = New-Object System.Drawing.Size(600, 20)
$form.Controls.Add($lblOutput)
$y += 22

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = New-Object System.Drawing.Point(15, $y)
$txtOutput.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($txtOutput)

$btnBrowseOutput = New-Object System.Windows.Forms.Button
$btnBrowseOutput.Text = "Browse..."
$btnBrowseOutput.Location = New-Object System.Drawing.Point(435, $y)
$btnBrowseOutput.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($btnBrowseOutput)
$y += 34

# ============================================================
# Remember the last values used (mode and output folder)
# ============================================================
# Saved to a simple config file under logs/, on the disk itself — this way
# it "remembers" what was last used on THAT disk, regardless of which
# computer it's opened on (unlike saving it to the Windows registry, which
# would be per-computer and wouldn't travel with the portable disk).
$configPathWin = if ($driveLetter) { Join-Path "$driveLetter`:\ReAnote\logs" "config_gui.txt" } else { $null }

function Save-GuiConfig {
    if (-not $configPathWin) { return }
    try {
        $logsDir = Split-Path $configPathWin -Parent
        if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
        Set-Content -Path $configPathWin -Value @(
            "modo=$($comboModo.SelectedIndex)",
            "salida=$($txtOutput.Text.Trim())"
        ) -Encoding UTF8
    } catch {
        # Not critical: at worst, the values won't be pre-loaded next time.
    }
}

function Load-GuiConfig {
    if (-not $configPathWin -or -not (Test-Path $configPathWin)) { return }
    try {
        $lines = Get-Content -Path $configPathWin -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ($line -match '^modo=(\d+)$') {
                $savedIdx = [int]$Matches[1]
                # Index 3 is the non-selectable separator "-- Single step only --"
                if ($savedIdx -ge 0 -and $savedIdx -lt $comboModo.Items.Count -and $savedIdx -ne 3) {
                    $comboModo.SelectedIndex = $savedIdx
                }
            } elseif ($line -match '^salida=(.*)$') {
                $txtOutput.Text = $Matches[1]
            }
        }
    } catch {
        # Not critical: falls back to the default values.
    }
}

# ---- Browse button (output) ----
$btnBrowseOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select where to save the results"
    if ($dlg.ShowDialog() -eq "OK") { $txtOutput.Text = $dlg.SelectedPath }
})

# Adjusts labels, enabled fields, and "Browse..." filters based on the
# selected mode, since each subcommand expects a different input type (VCF,
# FASTQ folder, BAM, or gVCF) and the BAM is optional/required/not
# applicable depending on the case.
function Update-FormForMode {
    $idx = $comboModo.SelectedIndex
    switch ($idx) {
        2 { # full: FASTQ, no BAM
            $lblInput.Text = "Folder with the input FASTQ files:"
            $txtBam.Enabled = $false; $btnBrowseBam.Enabled = $false; $txtBam.Text = ""
            $lblBam.Text = "Associated BAM (not applicable to this mode):"
        }
        $SOLO_PASO_ALINEAR { # align: FASTQ, no BAM
            $lblInput.Text = "Folder with the input FASTQ files:"
            $txtBam.Enabled = $false; $btnBrowseBam.Enabled = $false; $txtBam.Text = ""
            $lblBam.Text = "Associated BAM (not applicable to this mode):"
        }
        $SOLO_PASO_LLAMAR { # call: BAM as the main INPUT, no separate BAM field
            $lblInput.Text = "Input BAM file (already aligned):"
            $txtBam.Enabled = $false; $btnBrowseBam.Enabled = $false; $txtBam.Text = ""
            $lblBam.Text = "Associated BAM (not applicable to this mode):"
        }
        $SOLO_PASO_FILTRAR { # filter: gVCF as input, no BAM
            $lblInput.Text = "Input gVCF file:"
            $txtBam.Enabled = $false; $btnBrowseBam.Enabled = $false; $txtBam.Text = ""
            $lblBam.Text = "Associated BAM (not applicable to this mode):"
        }
        $SOLO_PASO_VEP { # vep: filtered VCF as input, BAM REQUIRED
            $lblInput.Text = "Input filtered VCF file:"
            $txtBam.Enabled = $true; $btnBrowseBam.Enabled = $true
            $lblBam.Text = "Associated BAM (REQUIRED for phasing):"
        }
        default { # annotate (0) / liftover (1): VCF, optional BAM
            $lblInput.Text = "Input file or folder (any location):"
            $txtBam.Enabled = $true; $btnBrowseBam.Enabled = $true
            $lblBam.Text = "Associated BAM (optional, for phasing with WhatsHap):"
        }
    }

    # Sequencing type (wgs/wes) and the BED only apply to the modes that
    # call variants from scratch: "full" and "call".
    $aplicaTipo = ($idx -eq 2 -or $idx -eq $SOLO_PASO_LLAMAR)
    $comboTipo.Enabled = $aplicaTipo
    if (-not $aplicaTipo) {
        $comboTipo.SelectedIndex = 0
        $txtBed.Enabled = $false; $btnBrowseBed.Enabled = $false; $txtBed.Text = ""
    } else {
        $esWes = $comboTipo.SelectedIndex -eq 1
        $txtBed.Enabled = $esWes; $btnBrowseBed.Enabled = $esWes
    }
}

$comboModo.Add_SelectedIndexChanged({
    if ($comboModo.SelectedIndex -eq 3) { $comboModo.SelectedIndex = 0; return }
    Update-FormForMode
})

Load-GuiConfig
Update-FormForMode

# ---- Browse button (input) ----
$btnBrowse.Add_Click({
    $idx = $comboModo.SelectedIndex
    if ($idx -eq 2 -or $idx -eq $SOLO_PASO_ALINEAR) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select the folder with the FASTQ files"
        if ($dlg.ShowDialog() -eq "OK") { $txtInput.Text = $dlg.SelectedPath }
    } elseif ($idx -eq $SOLO_PASO_LLAMAR) {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "BAM files (*.bam)|*.bam|All files (*.*)|*.*"
        if ($dlg.ShowDialog() -eq "OK") { $txtInput.Text = $dlg.FileName }
    } elseif ($idx -eq $SOLO_PASO_FILTRAR) {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "gVCF files (*.g.vcf.gz;*.g.vcf)|*.g.vcf.gz;*.g.vcf|All files (*.*)|*.*"
        if ($dlg.ShowDialog() -eq "OK") { $txtInput.Text = $dlg.FileName }
    } else {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "VCF files (*.vcf;*.vcf.gz)|*.vcf;*.vcf.gz|All files (*.*)|*.*"
        if ($dlg.ShowDialog() -eq "OK") { $txtInput.Text = $dlg.FileName }
    }
})

# ---- Browse button (BAM) ----
$btnBrowseBam.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "BAM files (*.bam)|*.bam|All files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq "OK") { $txtBam.Text = $dlg.FileName }
})

# ---- Generated command box (read-only, for transparency) ----
$lblCmd = New-Object System.Windows.Forms.Label
$lblCmd.Text = "Command that will run:"
$lblCmd.Location = New-Object System.Drawing.Point(15, $y)
$lblCmd.Size = New-Object System.Drawing.Size(520, 20)
$form.Controls.Add($lblCmd)
$y += 20

$txtCmd = New-Object System.Windows.Forms.TextBox
$txtCmd.Location = New-Object System.Drawing.Point(15, $y)
$txtCmd.Size = New-Object System.Drawing.Size(600, 60)
$txtCmd.Multiline = $true
$txtCmd.ScrollBars = "Vertical"
$txtCmd.ReadOnly = $true
$txtCmd.BackColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($txtCmd)
$y += 72

# ---- Run / view log / cancel buttons ----
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Start"
$btnRun.Location = New-Object System.Drawing.Point(15, $y)
$btnRun.Size = New-Object System.Drawing.Size(260, 36)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(44, 110, 155)
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnRun.FlatStyle = "Flat"
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(64, 130, 175)
$form.Controls.Add($btnRun)

$btnViewLog = New-Object System.Windows.Forms.Button
$btnViewLog.Text = "View log"
$btnViewLog.Location = New-Object System.Drawing.Point(285, $y)
$btnViewLog.Size = New-Object System.Drawing.Size(125, 36)
$btnViewLog.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$btnViewLog.ForeColor = [System.Drawing.Color]::White
$btnViewLog.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
# FlatStyle "Flat" (with the border removed) is needed so the button
# respects ForeColor even when Enabled=$false — with Windows Forms' default
# style, a disabled button ignores the configured text color and paints it
# with a system gray, barely legible on a dark background.
$btnViewLog.FlatStyle = "Flat"
$btnViewLog.FlatAppearance.BorderSize = 0
$btnViewLog.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$btnViewLog.Enabled = $false
$form.Controls.Add($btnViewLog)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancel"
$btnCancel.Location = New-Object System.Drawing.Point(420, $y)
$btnCancel.Size = New-Object System.Drawing.Size(115, 36)
$btnCancel.BackColor = [System.Drawing.Color]::FromArgb(178, 58, 58)
$btnCancel.ForeColor = [System.Drawing.Color]::White
$btnCancel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnCancel.FlatStyle = "Flat"
$btnCancel.FlatAppearance.BorderSize = 0
$btnCancel.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(198, 78, 78)
$btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)
$y += 46

# ---- Step progress bar ----
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, $y)
$progressBar.Size = New-Object System.Drawing.Size(600, 18)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$progressBar.Style = "Continuous"
$form.Controls.Add($progressBar)
$y += 24

$lblRunStatus = New-Object System.Windows.Forms.Label
$lblRunStatus.Text = ""
$lblRunStatus.Location = New-Object System.Drawing.Point(15, $y)
$lblRunStatus.Size = New-Object System.Drawing.Size(600, 20)
$lblRunStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblRunStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($lblRunStatus)

# Windows path of the .pid file, and WSL path of the log, for the last
# process launched from this window — used to cancel it or reopen its log
# if the tracking window is closed by mistake. Script-scope because
# $btnRun, $btnViewLog and $btnCancel need to read/write them from their
# own closures.
$script:lastPidFile = $null
$script:lastLogPathWsl = $null
$script:lastTotalFases = 0
$script:procesoEnCurso = $false

# ---- Persisting the last launched process, to survive closing the ENTIRE
# window (not just the log one) and reopening the .bat ----
# Without this, accidentally closing the whole PowerShell window (not just
# the "tail -f" console) leaves a process running in WSL with no way to see
# it or cancel it from the GUI: $script:lastPidFile only lives in the
# memory of THAT PowerShell instance, which disappears with the window.
$lastRunPointerWin = if ($driveLetter) { Join-Path "$driveLetter`:\ReAnote\logs" "ultimo.txt" } else { $null }

function Save-LastRunPointer {
    param([string]$PidFileWin, [string]$LogPathWsl, [int]$TotalFases)
    if (-not $lastRunPointerWin) { return }
    try {
        Set-Content -Path $lastRunPointerWin -Value @($PidFileWin, $LogPathWsl, $TotalFases) -Encoding UTF8
    } catch {
        # Not critical: at worst, it won't be recoverable after closing the whole window.
    }
}

function Clear-LastRunPointer {
    if ($lastRunPointerWin -and (Test-Path $lastRunPointerWin)) {
        Remove-Item -Path $lastRunPointerWin -ErrorAction SilentlyContinue
    }
}

# Captures the output of "wsl.exe bash -lc <command>" decoded as real UTF-8.
# This is DELIBERATELY different from "& wsl.exe ..." / "$(wsl.exe ...)":
# that PowerShell 5.1 invocation operator routes the output through
# Windows console's default text-capture pipeline (here, CP850), which
# corrupts any accented character BEFORE the script can do anything about
# it — confirmed with a byte-level test: the wsl.exe pipe delivers correct
# UTF-8, but "& wsl.exe" already returns it corrupted. Reading the raw
# BaseStream and decoding it ourselves as UTF-8 avoids that layer, and is
# the only approach that gave correct results in testing.
function Invoke-WslUtf8 {
    param([string]$BashCommand)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "bash -lc `"$BashCommand`""
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $ms = New-Object System.IO.MemoryStream
        $proc.StandardOutput.BaseStream.CopyTo($ms)
        $proc.WaitForExit()
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    } catch {
        return ""
    }
}

function Test-RemotePidAlive {
    param([string]$PidValue)
    if ([string]::IsNullOrWhiteSpace($PidValue)) { return $false }
    # "kill -0" doesn't send any real signal, it just checks whether the PID
    # exists and is reachable — the standard way to probe a process without
    # affecting it.
    $result = Invoke-WslUtf8 -BashCommand "kill -0 -$PidValue 2>/dev/null && echo ALIVE || echo DEAD"
    return ($result -match "ALIVE")
}

# Reads the last lines of the log (via WSL) to: (a) detect which step the
# pipeline is on and update the progress bar, (b) know whether it already
# finished successfully or the process died without completing — so a
# failure can be reported instead of leaving the user to discover it on
# their own.
function Get-LogTail {
    param([string]$LogPathWsl, [int]$Lines = 40)
    if ([string]::IsNullOrWhiteSpace($LogPathWsl)) { return $null }
    $texto = Invoke-WslUtf8 -BashCommand "tail -n $Lines '$LogPathWsl' 2>/dev/null"
    if ([string]::IsNullOrEmpty($texto)) { return $null }
    return ($texto -split "`n")
}

# Checks whether a log's text indicates the pipeline finished successfully.
function Test-LogIndicaExito {
    param([string]$Texto)
    if ([string]::IsNullOrEmpty($Texto)) { return $false }
    return ($Texto -match "COMPLETED SUCCESSFULLY" -or $Texto -match "completed:")
}

function Update-ProgressFromLog {
    param([string[]]$LogLines, [int]$TotalFases)
    if (-not $LogLines) { return }

    $texto = $LogLines -join "`n"

    if (Test-LogIndicaExito -Texto $texto) {
        $progressBar.Value = 100
        return
    }

    # Matches "Step X/4:" (full/align/call/filter/vep) or "Step X/2:"
    # (liftover) — the LAST occurrence in the log is used, which is the
    # furthest step reached so far.
    $stepMatches = [regex]::Matches($texto, 'Step (\d+)/(\d+):')

    $actual = 0; $total = [Math]::Max($TotalFases, 1)
    if ($stepMatches.Count -gt 0) {
        $last = $stepMatches[$stepMatches.Count - 1]
        $actual = [int]$last.Groups[1].Value
        $total = [int]$last.Groups[2].Value
    } elseif ($TotalFases -le 1) {
        # Single-step runs (annotate/call/filter/align without a "Step X/Y"
        # marker): with no clear intermediate signal, progress is shown as
        # "halfway" while running, and only reaches 100% once
        # COMPLETED/success is detected above, or once the process is
        # confirmed to have ended.
        $progressBar.Value = [Math]::Max($progressBar.Value, 15)
        return
    }

    if ($total -gt 0) {
        $pct = [int](($actual / $total) * 100)
        $progressBar.Value = [Math]::Min([Math]::Max($pct, $progressBar.Value), 99)
    }
}

# ---- Monitoring timer: polls every 3s whether the launched process is
# still alive, updates the progress bar by reading the log, and reports
# when it finishes (success or failure) — without the user having to check
# manually. ----
$monitorTimer = New-Object System.Windows.Forms.Timer
$monitorTimer.Interval = 3000
$monitorTimer.Add_Tick({
    if (-not $script:procesoEnCurso -or -not $script:lastPidFile) { return }
    if (-not (Test-Path $script:lastPidFile)) { return }

    $pidValue = (Get-Content -Path $script:lastPidFile -Raw -ErrorAction SilentlyContinue)
    if ($pidValue) { $pidValue = $pidValue.Trim() }

    $logLines = Get-LogTail -LogPathWsl $script:lastLogPathWsl
    Update-ProgressFromLog -LogLines $logLines -TotalFases $script:lastTotalFases

    $vivo = Test-RemotePidAlive -PidValue $pidValue
    if ($vivo) { return }

    # The process is no longer alive: stop polling and determine whether it
    # finished well or badly from the log itself. IMPORTANT: the log is
    # re-read HERE, the $logLines from above is NOT reused — that one was
    # read BEFORE checking whether the process was still alive, so it may
    # correspond to a moment where the pipeline hadn't written its last
    # line yet, or hadn't finished flushing its buffer to disk. With a
    # small delay and a re-read once the process is confirmed dead, a false
    # "it failed" is avoided when it actually finished successfully.
    Start-Sleep -Milliseconds 800
    $logLines = Get-LogTail -LogPathWsl $script:lastLogPathWsl

    $monitorTimer.Stop()
    $script:procesoEnCurso = $false
    $btnCancel.Enabled = $false
    Clear-LastRunPointer

    $texto = if ($logLines) { $logLines -join "`n" } else { "" }
    if (Test-LogIndicaExito -Texto $texto) {
        $progressBar.Value = 100
        $lblRunStatus.Text = "Process finished successfully."
        $lblRunStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        [System.Windows.Forms.MessageBox]::Show(
            "The process finished correctly. You can now check the results in the output folder.",
            "Process completed", "OK", "Information")
    } else {
        $lblRunStatus.Text = "The process stopped before completing all steps."
        $lblRunStatus.ForeColor = [System.Drawing.Color]::FromArgb(178, 58, 58)
        [System.Windows.Forms.MessageBox]::Show(
            "The process stopped before completing all steps - it probably failed." +
            " The final file may not exist or may be incomplete." +
            "`n`nClick 'View log' to review the error details.",
            "The process did not finish correctly", "OK", "Error")
    }
})

# When the window opens, check whether a process from a previous run (from
# this or another opening of the .bat) is still running in WSL, and if so,
# reactivate "View log"/"Cancel" pointing at it automatically.
if ($lastRunPointerWin -and (Test-Path $lastRunPointerWin)) {
    $pointerLines = Get-Content -Path $lastRunPointerWin -ErrorAction SilentlyContinue
    if ($pointerLines -and $pointerLines.Count -ge 2) {
        $recoveredPidFile = $pointerLines[0]
        $recoveredLogWsl = $pointerLines[1]
        $recoveredTotalFases = if ($pointerLines.Count -ge 3) { [int]$pointerLines[2] } else { 1 }
        if (Test-Path $recoveredPidFile) {
            $recoveredPidValue = (Get-Content -Path $recoveredPidFile -Raw -ErrorAction SilentlyContinue)
            if ($recoveredPidValue) { $recoveredPidValue = $recoveredPidValue.Trim() }
            if (Test-RemotePidAlive -PidValue $recoveredPidValue) {
                $script:lastPidFile = $recoveredPidFile
                $script:lastLogPathWsl = $recoveredLogWsl
                $script:lastTotalFases = $recoveredTotalFases
                $script:procesoEnCurso = $true
                $btnCancel.Enabled = $true
                $btnViewLog.Enabled = $true
                $lblRunStatus.Text = "A process from a previous run was detected and is still active."
                $lblRunStatus.ForeColor = [System.Drawing.Color]::DarkGreen
                $monitorTimer.Start()
            } else {
                Clear-LastRunPointer
            }
        }
    }
}

# ---- Build the WSL command from the form fields ----
function Build-Command {
    if (-not $driveLetter) { return $null }
    $letra = $driveLetter.ToLower()
    $sample = $txtSample.Text.Trim()
    $inputPath = $txtInput.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($sample) -or [string]::IsNullOrWhiteSpace($inputPath)) {
        return $null
    }

    $idx = $comboModo.SelectedIndex
    $bamPath = $txtBam.Text.Trim()
    if ($idx -eq $SOLO_PASO_VEP -and [string]::IsNullOrWhiteSpace($bamPath)) {
        return $null
    }

    $aplicaTipo = ($idx -eq 2 -or $idx -eq $SOLO_PASO_LLAMAR)
    $esWes = $aplicaTipo -and ($comboTipo.SelectedIndex -eq 1)
    $bedPath = $txtBed.Text.Trim()
    if ($esWes -and [string]::IsNullOrWhiteSpace($bedPath)) {
        return $null
    }

    $inputWsl = Convert-ToWslPath $inputPath

    switch ($idx) {
        0 { $sub = "annotate"; $outSuffix = "annotated" }
        1 { $sub = "liftover"; $outSuffix = "liftover" }
        2 { $sub = "full";     $outSuffix = "full" }
        $SOLO_PASO_ALINEAR { $sub = "align";  $outSuffix = "aligned" }
        $SOLO_PASO_LLAMAR  { $sub = "call";   $outSuffix = "gvcf" }
        $SOLO_PASO_FILTRAR { $sub = "filter"; $outSuffix = "filtered" }
        $SOLO_PASO_VEP     { $sub = "vep";    $outSuffix = "annotated" }
    }

    $outputPath = $txtOutput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        $outArg = "outputs/${sample}_${outSuffix}"
    } else {
        $outWsl = Convert-ToWslPath $outputPath
        $outArg = "$outWsl/${sample}_${outSuffix}"
    }

    $cmd = "cd /mnt/$letra/ReAnote && ./reanotar.sh $sub -i `"$inputWsl`" -o `"$outArg`" -s `"$sample`""

    if ($aplicaTipo) {
        $tipo = if ($esWes) { "wes" } else { "wgs" }
        $cmd += " -t $tipo"
        if ($esWes) {
            $bedWsl = Convert-ToWslPath $bedPath
            $cmd += " -e `"$bedWsl`""
        }
    } elseif ($idx -eq $SOLO_PASO_VEP) {
        $bamWsl = Convert-ToWslPath $bamPath
        $cmd += " -b `"$bamWsl`""
    } elseif (($idx -eq 0 -or $idx -eq 1) -and -not [string]::IsNullOrWhiteSpace($bamPath)) {
        $bamWsl = Convert-ToWslPath $bamPath
        $cmd += " -b `"$bamWsl`""
    }
    return $cmd
}

# Number of "Step X/Y" expected in the log for this mode, used to calibrate
# the progress bar (1 = no step markers, as in align/call/filter).
function Get-TotalFasesForMode {
    param([int]$Idx)
    switch ($Idx) {
        2 { return 4 }               # full: Step 1/4..4/4
        1 { return 2 }               # liftover: Step 1/2..2/2
        default { return 1 }
    }
}

# Refresh the command preview every time something changes
$refresh = { $txtCmd.Text = Build-Command }
$txtInput.Add_TextChanged($refresh)
$txtSample.Add_TextChanged($refresh)
$txtBam.Add_TextChanged($refresh)
$txtOutput.Add_TextChanged($refresh)
$txtBed.Add_TextChanged($refresh)
$comboModo.Add_SelectedIndexChanged($refresh)
$comboTipo.Add_SelectedIndexChanged($refresh)

$btnRun.Add_Click({
    $cmd = Build-Command
    if (-not $cmd) {
        $msg = "Fill in at least the input file/folder and the sample name."
        $idxErr = $comboModo.SelectedIndex
        if ($idxErr -eq $SOLO_PASO_VEP) {
            $msg = "This mode also needs the associated BAM (required for phasing)."
        } elseif (($idxErr -eq 2 -or $idxErr -eq $SOLO_PASO_LLAMAR) -and $comboTipo.SelectedIndex -eq 1 -and [string]::IsNullOrWhiteSpace($txtBed.Text.Trim())) {
            $msg = "Since the sequencing type is 'wes (exome)', you also need to provide the regions BED file."
        }
        [System.Windows.Forms.MessageBox]::Show($msg, "Missing data", "OK", "Warning")
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will run:`n`n$cmd`n`nThe process may take a while. If you close the" +
        " terminal window by mistake, the process will keep running anyway - only the log view closes." +
        "`n`nContinue?",
        "Confirm", "YesNo", "Question")
    if ($confirm -ne "Yes") { return }

    Save-GuiConfig

    # The actual command runs DECOUPLED from the terminal window (with
    # setsid + nohup, in the background inside WSL) and its output is
    # written to a log file. The visible window just does "tail -f" on that
    # log: if the user closes it, the real pipeline keeps running in WSL,
    # it isn't interrupted. To avoid quoting headaches between PowerShell /
    # wsl.exe / bash, everything is written to two real .sh scripts on disk.
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logsDir = Join-Path "$driveLetter`:\ReAnote" "logs"
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

    $jobScriptWin = Join-Path $logsDir "job_$stamp.sh"
    $viewScriptWin = Join-Path $logsDir "view_$stamp.sh"
    $logPathWsl = "/mnt/$($driveLetter.ToLower())/ReAnote/logs/log_$stamp.txt"
    $pidPathWsl = "/mnt/$($driveLetter.ToLower())/ReAnote/logs/pid_$stamp.txt"
    $pidPathWin = Join-Path $logsDir "pid_$stamp.txt"

    # The job saves its OWN PID ($$, not $! from the outside) before
    # launching the real pipeline with "exec": "setsid script &" from
    # another shell does NOT leave $! matching the PID of setsid's orphaned
    # child (confirmed: they differ), so the only reliable way to later kill
    # the whole group with "kill -TERM -PID" is for the script itself to
    # identify itself and replace itself (exec) with the pipeline, keeping
    # its PID.
    $jobScriptContent = "#!/bin/bash`necho `$`$ > `"$pidPathWsl`"`nexec bash -c '$($cmd -replace "'", "'\''")' > `"$logPathWsl`" 2>&1`n"
    $viewScriptContent = @"
#!/bin/bash
setsid bash "/mnt/$($driveLetter.ToLower())/ReAnote/logs/job_$stamp.sh" >/dev/null 2>&1 < /dev/null &
disown
sleep 1
echo "Process launched in the background (group PID: `$(cat "$pidPathWsl" 2>/dev/null))."
echo "You can close this window without worry: the process will keep running anyway."
echo "To cancel it, use the Cancel button in the ReAnote window, or close it and reopen it."
echo "Log: $logPathWsl"
echo
tail -n +1 -f "$logPathWsl"
"@

    # Important: the scripts are written WITHOUT a BOM (the "#!/bin/bash"
    # shebang isn't recognized on Linux if the file starts with the UTF-8
    # BOM marker that "Set-Content -Encoding UTF8" adds by default on
    # Windows PowerShell).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jobScriptWin, ($jobScriptContent -replace "`r`n", "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText($viewScriptWin, ($viewScriptContent -replace "`r`n", "`n"), $utf8NoBom)

    $viewScriptWsl = "/mnt/$($driveLetter.ToLower())/ReAnote/logs/view_$stamp.sh"

    Start-Process -FilePath "wsl.exe" -ArgumentList "bash", $viewScriptWsl

    $script:lastPidFile = $pidPathWin
    $script:lastLogPathWsl = $logPathWsl
    $script:lastTotalFases = Get-TotalFasesForMode -Idx $comboModo.SelectedIndex
    $script:procesoEnCurso = $true
    $btnCancel.Enabled = $true
    $btnViewLog.Enabled = $true
    $progressBar.Value = 0
    $lblRunStatus.Text = "Process running (started $(Get-Date -Format 'HH:mm:ss'))."
    $lblRunStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    $monitorTimer.Start()

    # This is persisted to disk (not just in memory) so "View log"/"Cancel"
    # can be recovered if the ENTIRE window is closed (the whole .bat, not
    # just the tracking one) and reopened later.
    Save-LastRunPointer -PidFileWin $pidPathWin -LogPathWsl $logPathWsl -TotalFases $script:lastTotalFases
})

# Reopens a window with "tail -f" on the log of the last process launched
# from this GUI — useful if the tracking window was closed by mistake (the
# process itself is still alive in WSL, only the live view was lost).
$btnViewLog.Add_Click({
    if (-not $script:lastLogPathWsl) {
        [System.Windows.Forms.MessageBox]::Show(
            "No process has been launched from this window yet.",
            "Nothing to view", "OK", "Information")
        return
    }
    $tailCmd = "echo 'Reopening the log of the last launched process.'; echo 'If the process already finished, you will see the full result as it ended.'; echo; tail -n +1 -f `"$($script:lastLogPathWsl)`""
    Start-Process -FilePath "wsl.exe" -ArgumentList "bash", "-lc", $tailCmd
})

$btnCancel.Add_Click({
    if (-not $script:lastPidFile) {
        [System.Windows.Forms.MessageBox]::Show(
            "There is no process launched from this window that can be cancelled.",
            "Nothing to cancel", "OK", "Information")
        return
    }

    # The .pid file is written by the WSL window in the background right
    # after starting; if the user clicks Cancel in the very first instant
    # it might not exist yet — a few short retries cover that margin
    # without noticeably blocking the interface.
    $intentos = 0
    while (-not (Test-Path $script:lastPidFile) -and $intentos -lt 5) {
        Start-Sleep -Milliseconds 400
        $intentos++
    }
    if (-not (Test-Path $script:lastPidFile)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The process was just launched and there isn't a PID to cancel yet." +
            " Wait a few seconds and try again.",
            "Nothing to cancel yet", "OK", "Information")
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This stops the re-annotation process that is currently running." +
        " The result will be left incomplete and you'll have to relaunch it from the start." +
        "`n`nAre you sure you want to cancel it?",
        "Confirm cancellation", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    $pidValue = (Get-Content -Path $script:lastPidFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($pidValue)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read the process PID (empty file). It may still be starting up" +
            " - wait a few seconds and try again.",
            "Could not cancel", "OK", "Warning")
        return
    }

    # "kill -TERM -PID" (with the dash) kills the whole process GROUP, not
    # just the setsid process itself — needed because reanotar.sh in turn
    # launches gatk/vep/whatshap as children, and killing only the parent
    # would leave them running as orphans.
    $killCmd = "kill -TERM -$pidValue 2>/dev/null; sleep 1; kill -KILL -$pidValue 2>/dev/null; echo done"
    & wsl.exe bash -lc $killCmd | Out-Null

    $monitorTimer.Stop()
    $script:procesoEnCurso = $false
    $btnCancel.Enabled = $false
    Clear-LastRunPointer
    $progressBar.Value = 0
    $lblRunStatus.Text = "Process cancelled."
    $lblRunStatus.ForeColor = [System.Drawing.Color]::FromArgb(178, 58, 58)
    [System.Windows.Forms.MessageBox]::Show(
        "Process cancelled. You can now fix the data and click Start again.",
        "Cancelled", "OK", "Information")
})

# ---- Confirmation when closing the window if a process is running ----
# Closing the entire window does NOT stop the process (it stays alive in
# WSL thanks to the setsid decoupling), but it DOES lose sight of the "View
# log"/"Cancel" buttons until the .bat is reopened — better to warn
# explicitly instead of letting it happen unnoticed.
$form.Add_FormClosing({
    param($eventSender, $e)
    if (-not $script:procesoEnCurso) { return }
    $confirmClose = [System.Windows.Forms.MessageBox]::Show(
        "A re-annotation process is currently running." +
        "`n`nIf you close this window, the process will KEEP running in the background" +
        " (it won't be interrupted), but you'll lose track of it until you" +
        " reopen ReAnote — from there you can resume it with 'View log' or stop it with 'Cancel'." +
        "`n`nAre you sure you want to close the window?",
        "A process is running", "YesNo", "Warning")
    if ($confirmClose -ne "Yes") {
        $e.Cancel = $true
    }
})

[void]$form.ShowDialog()
