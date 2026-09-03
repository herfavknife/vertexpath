#requires -Version 5.1
<#
==============================================================================
 VertexPath v1.0.0
 Simple step-by-step checklist from your idea.
 Flat list, progress bar, hide completed -- focused and clean.
==============================================================================
#>

param([switch]$Debug)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$script:DebugMode = $false
if ($Debug) { $script:DebugMode = $true }
if ($env:VERTEXPATH_DEBUG -eq '1') { $script:DebugMode = $true }

function Write-DebugLog {
    param([string]$Message)
    if (-not $script:DebugMode) { return }
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    Write-Host ("[VertexPath {0}] {1}" -f $ts, $Message) -ForegroundColor DarkCyan
}

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    if ($script:DebugMode) { $argsList += '-Debug' }
    Start-Process -FilePath $psExe -ArgumentList $argsList | Out-Null
    return
}

try {
    $dwmCode = @'
using System;
using System.Runtime.InteropServices;
public class DwmHelper {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
'@
    Add-Type -TypeDefinition $dwmCode -ErrorAction SilentlyContinue
} catch { }

$script:AppName      = "VertexPath"
$script:AppVersion   = "1.0.0"
$script:DataDir      = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "VertexPath"
$script:SettingsPath = Join-Path $script:DataDir "settings.json"
$script:AutosavePath = Join-Path $script:DataDir "autosave.json"

if (-not (Test-Path -LiteralPath $script:DataDir)) {
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
}

$script:Checklist        = $null
$script:CurrentFilePath  = $null
$script:Dirty            = $false
$script:HideChecked      = $false
$script:SuppressAutosave = $false
$script:Keybinds = @{ New = 'N'; Open = 'O'; Save = 'S'; Export = 'E' }

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:IconPath  = Join-Path $script:ScriptDir "icon.png"
$script:BgPath    = Join-Path $script:ScriptDir "background.jpg"
if (-not (Test-Path -LiteralPath $script:BgPath)) {
    $alt = Join-Path $script:ScriptDir "bg.jpg"
    if (Test-Path -LiteralPath $alt) { $script:BgPath = $alt }
}
$script:GitHubUrl = "https://github.com/herfavknife"
$script:RepoUrl   = "https://github.com/herfavknife/vertexpath"

function New-IdString { [guid]::NewGuid().ToString() }

function New-ItemNode {
    param([string]$Text, [bool]$Checked = $false)
    @{ Id = (New-IdString); Text = $Text; Checked = $Checked }
}

function New-EmptyChecklist {
    param([string]$Title = "Untitled", [string]$Idea = "")
    @{
        Title       = $Title
        Idea        = $Idea
        CreatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        ModifiedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Items       = @()
    }
}

function Get-ChecklistStats {
    param($Checklist)
    $total = 0; $done = 0
    if ($Checklist -and $Checklist.Items) {
        $total = $Checklist.Items.Count
        $done  = ($Checklist.Items | Where-Object { $_.Checked }).Count
    }
    $pct = if ($total -gt 0) { [math]::Round(($done / $total) * 100) } else { 0 }
    @{ Total = $total; Done = $done; Percent = $pct }
}

function ConvertTo-HashtableDeep {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-HashtableDeep $item)) }
        return ,@($list)
    }
    if ($InputObject -is [PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-HashtableDeep $prop.Value
        }
        return $hash
    }
    return $InputObject
}

function Get-IdeaLabel {
    param([string]$Idea)
    $t = $Idea.Trim()
    if ($t.Length -le 48) { return $t }
    $t.Substring(0, 45) + "..."
}

function Test-Has {
    param([string]$Text, [string[]]$Words)
    foreach ($w in $Words) {
        if ($Text -match [regex]::Escape($w)) { return $true }
    }
    $false
}


function Clean-ChecklistLine {
    param([string]$s)
    if (-not $s) { return '' }
    $s = $s -replace '^[\s\-\**--]+', ''
    $s = $s -replace '^\d+[.)]\s*', ''
    $s = $s -replace '^[a-zA-Z][.)]\s*', ''
    $s = ($s -replace '\s+', ' ').Trim()
    $s = $s.TrimEnd('.', ';', ',', ':')
    return $s.Trim()
}

function Test-IsNoiseLine {
    param([string]$s)
    if (-not $s -or $s.Length -lt 2) { return $true }
    if ($s -match '^(and|or|also|then|so|but|the|a|an|to|for|of|in|on|with|it|this|that|just|like|really|very|now)$') { return $true }
    return $false
}

function Test-IsExplanationOnly {
    param([string]$s)
    if (-not $s) { return $true }
    $low = $s.ToLowerInvariant()
    # Pure rationale / filler - not a task
    if ($low -match '^(why|because|cuz|cause|since|so that|in order to|the reason|this is necessary|this is needed|for example|e\.g\.|eg\b|aka\b)') { return $true }
    if ($low -match '^(it will be|it could be|it would be|i think|i want|i need|we need|you need|they need)\b' -and $s.Length -gt 80) { return $true }
    if ($low -match '\b(why is this|why this is|necessary cuz|necessary because)\b') { return $true }
    return $false
}

function Test-LooksLikeListPiece {
    param([string]$s)
    if (-not $s) { return $false }
    if ($s.Length -lt 2 -or $s.Length -gt 72) { return $false }
    # Prefer short noun/feature phrases over long clauses
    if ($s -match '\b(which|where|when|while|although|however|because|cuz)\b') { return $false }
    return $true
}

function ConvertTo-TitleCaseFirst {
    param([string]$s)
    if (-not $s) { return $s }
    if ($s.Length -eq 1) { return $s.ToUpperInvariant() }
    return $s.Substring(0,1).ToUpperInvariant() + $s.Substring(1)
}

function Split-OnListSeparators {
    param([string]$s)
    # Split on commas, semicolons, pipes, " / ", " + ", " & ", and " and " between short pieces
    $parts = [regex]::Split($s, '\s*[,;|/]\s*|\s+\+\s*|\s+&\s*|\s+/\s+')
    $result = New-Object System.Collections.ArrayList
    foreach ($p in $parts) {
        $c = Clean-ChecklistLine $p
        if (-not $c) { continue }
        # Further split trailing " and X" only if both sides look like list pieces
        if ($c -match '\sand\s' -and $c.Length -le 90) {
            $andParts = [regex]::Split($c, '\s+and\s+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $ok = $true
            $cleaned = @()
            foreach ($ap in $andParts) {
                $ac = Clean-ChecklistLine $ap
                if (-not (Test-LooksLikeListPiece $ac)) { $ok = $false; break }
                $cleaned += $ac
            }
            if ($ok -and $cleaned.Count -ge 2) {
                foreach ($ac in $cleaned) { [void]$result.Add($ac) }
                continue
            }
        }
        [void]$result.Add($c)
    }
    return ,@($result)
}

function Extract-ItemsFromText {
    param([string]$Raw)
    $text = ($Raw -replace "`r`n", "`n").Trim()
    if (-not $text) { return @() }

    $rawChunks = New-Object System.Collections.ArrayList
    $lines = $text -split "`n+"

    foreach ($line in $lines) {
        $line = $line.Trim()
        if (-not $line) { continue }

        # Strip leading bullet/number
        $base = Clean-ChecklistLine $line
        if (-not $base) { continue }

        # If line has commas / separators and multiple short pieces -> list
        $pieces = @(Split-OnListSeparators $base)
        $shortCount = 0
        foreach ($p in $pieces) {
            if (Test-LooksLikeListPiece $p) { $shortCount++ }
        }

        if ($pieces.Count -ge 2 -and $shortCount -ge 2) {
            foreach ($p in $pieces) {
                if (Test-IsNoiseLine $p) { continue }
                if (Test-IsExplanationOnly $p) { continue }
                if ($p.Length -ge 2) { [void]$rawChunks.Add($p) }
            }
            continue
        }

        # Sentence split for long prose lines
        if ($base.Length -gt 100 -or $base -match '[.!?].+\w') {
            $sents = [regex]::Split($base, '(?<=[.!?])\s+')
            foreach ($sent in $sents) {
                $sc = Clean-ChecklistLine $sent
                if (Test-IsNoiseLine $sc) { continue }
                if (Test-IsExplanationOnly $sc) { continue }
                # Try comma split inside sentence if it looks like a list of features
                $inner = @(Split-OnListSeparators $sc)
                $innerShort = 0
                foreach ($ip in $inner) { if (Test-LooksLikeListPiece $ip) { $innerShort++ } }
                if ($inner.Count -ge 2 -and $innerShort -ge 2) {
                    foreach ($ip in $inner) {
                        if (Test-IsNoiseLine $ip -or Test-IsExplanationOnly $ip) { continue }
                        if ($ip.Length -ge 2) { [void]$rawChunks.Add($ip) }
                    }
                } else {
                    if ($sc.Length -ge 2) { [void]$rawChunks.Add($sc) }
                }
            }
            continue
        }

        # Soft split on then / also for action chains
        if ($base.Length -gt 40 -and $base -match '\bthen\b|\balso\b') {
            $bits = [regex]::Split($base, '\s+(?:then|also)\s+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $okBits = @()
            foreach ($b in $bits) {
                $bc = Clean-ChecklistLine $b
                if (-not (Test-IsNoiseLine $bc) -and -not (Test-IsExplanationOnly $bc) -and $bc.Length -ge 3) {
                    $okBits += $bc
                }
            }
            if ($okBits.Count -ge 2) {
                foreach ($b in $okBits) { [void]$rawChunks.Add($b) }
                continue
            }
        }

        if (-not (Test-IsExplanationOnly $base) -and -not (Test-IsNoiseLine $base)) {
            [void]$rawChunks.Add($base)
        }
    }

    # Dedupe preserving order
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($c in $rawChunks) {
        $c = Clean-ChecklistLine $c
        if (Test-IsNoiseLine $c) { continue }
        if (Test-IsExplanationOnly $c) { continue }
        # Drop very long pure description blobs that still slipped through
        if ($c.Length -gt 140 -and $c -match '\b(because|which will|so that|in order)\b') { continue }
        $key = $c.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$out.Add((ConvertTo-TitleCaseFirst $c))
    }
    return ,@($out)
}

function Generate-LocalChecklist {
    param([string]$Idea)

    $texts = Extract-ItemsFromText -Raw $Idea
    if (-not $texts -or $texts.Count -eq 0) {
        throw "Could not find clear checklist items. Use short lines, bullets, or commas between tasks."
    }

    $title = if ($texts.Count -eq 1) {
        if ($texts[0].Length -le 48) { $texts[0] } else { $texts[0].Substring(0, 45) + '...' }
    } else {
        $firstLine = ($Idea.Trim() -split "`n")[0]
        $firstLine = Clean-ChecklistLine $firstLine
        if ($firstLine.Length -ge 3 -and $firstLine.Length -le 48 -and -not (Test-IsExplanationOnly $firstLine)) { $firstLine }
        elseif ($texts[0].Length -le 40) { $texts[0] }
        elseif ($firstLine.Length -gt 48) { $firstLine.Substring(0, 45) + '...' }
        else { 'Checklist' }
    }

    $cl = New-EmptyChecklist -Title $title -Idea $Idea
    $list = New-Object System.Collections.ArrayList
    foreach ($t in $texts) {
        [void]$list.Add((New-ItemNode -Text $t))
    }
    $cl.Items = @($list)
    return $cl
}


function Get-AISystemPrompt {
    return @"
You turn a product idea into a simple ordered checklist.
Rules:
- Output ONLY raw JSON, no markdown fences.
- Schema: { "title": "short title", "items": ["step 1", "step 2", ...] }
- Order simple / foundational first, harder later.
- 12 to 30 concrete actionable steps.
- No vague items. Each line is one clear action.
- Tailor steps to the idea; do not pad with generic filler.
"@
}

function ConvertFrom-AIChecklistJson {
    param([string]$JsonText, [string]$OriginalIdea)
    $cleaned = $JsonText.Trim()
    $cleaned = $cleaned -replace '(?s)^```[a-zA-Z]*\s*', ''
    $cleaned = $cleaned -replace '(?s)\s*```\s*$', ''
    $parsed = $cleaned | ConvertFrom-Json -ErrorAction Stop
    $title = if ($parsed.title) { [string]$parsed.title } else { Get-IdeaLabel -Idea $OriginalIdea }
    $cl = New-EmptyChecklist -Title $title -Idea $OriginalIdea
    $list = New-Object System.Collections.ArrayList
    foreach ($t in @($parsed.items)) {
        [void]$list.Add((New-ItemNode -Text ([string]$t)))
    }
    $cl.Items = @($list)
    return $cl
}

function Invoke-AIChecklistGeneration {
    param([string]$Idea, [string]$BaseUrl, [string]$ApiKey, [string]$Model)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { throw "AI base URL is empty." }
    if ([string]::IsNullOrWhiteSpace($ApiKey))  { throw "AI API key is empty." }
    if ([string]::IsNullOrWhiteSpace($Model))   { $Model = "gpt-4o-mini" }
    if ($Idea.Length -gt 4000) { $Idea = $Idea.Substring(0, 4000) }

    $bu = $BaseUrl.Trim()
    $isLocal = $bu -match '^https?://(localhost|127\.0\.0\.1)(:\d+)?'
    if (-not $isLocal -and $bu -notmatch '^https://') {
        throw "AI base URL must use HTTPS (or http://localhost)."
    }

    $sysPrompt  = Get-AISystemPrompt
    $userPrompt = "Idea: $Idea"

    if ($bu -match 'anthropic\.com') {
        $body = @{
            model = $Model; max_tokens = 4096; system = $sysPrompt
            messages = @(@{ role = 'user'; content = $userPrompt })
        } | ConvertTo-Json -Depth 10
        $headers = @{
            'x-api-key' = $ApiKey; 'anthropic-version' = '2023-06-01'; 'content-type' = 'application/json'
        }
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -Headers $headers -Body $body -TimeoutSec 90
        $text = $resp.content[0].text
    } else {
        $trimmedBase = $bu.TrimEnd('/')
        if ($trimmedBase -match 'chat/completions$') { $uri = $trimmedBase }
        elseif ($trimmedBase -match '/v1$') { $uri = "$trimmedBase/chat/completions" }
        else { $uri = "$trimmedBase/v1/chat/completions" }
        $body = @{
            model = $Model; temperature = 0.35
            messages = @(
                @{ role = 'system'; content = $sysPrompt },
                @{ role = 'user'; content = $userPrompt }
            )
        } | ConvertTo-Json -Depth 10
        $headers = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -TimeoutSec 90
        $text = $resp.choices[0].message.content
    }
    return ConvertFrom-AIChecklistJson -JsonText $text -OriginalIdea $Idea
}

function Save-ChecklistToFile {
    param($Checklist, [string]$Path)
    $Checklist.ModifiedUtc = (Get-Date).ToUniversalTime().ToString('o')
    ($Checklist | ConvertTo-Json -Depth 20) | Set-Content -Path $Path -Encoding UTF8
    $script:Dirty = $false
}

function Load-ChecklistFromFile {
    param([string]$Path)
    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $h = ConvertTo-HashtableDeep $obj
    if ($h.Phases -and -not $h.Items) {
        $flat = New-Object System.Collections.ArrayList
        foreach ($p in $h.Phases) {
            foreach ($c in @($p.Categories)) {
                foreach ($t in @($c.Tasks)) {
                    [void]$flat.Add((New-ItemNode -Text ([string]$t.Title) -Checked ([bool]$t.Checked)))
                    foreach ($s in @($t.SubTasks)) {
                        [void]$flat.Add((New-ItemNode -Text ("  " + [string]$s.Title) -Checked ([bool]$s.Checked)))
                    }
                }
            }
        }
        $h.Items = @($flat)
        $h.Remove('Phases')
    }
    if (-not $h.Items) { $h.Items = @() }
    return $h
}

function Save-AppSettings {
    param([string]$BaseUrl, [string]$ApiKey, [string]$Model, [bool]$AiEnabled, [hashtable]$Keybinds)
    $settings = @{
        BaseUrl = $BaseUrl; ApiKey = $ApiKey; Model = $Model
        AiEnabled = $AiEnabled; Keybinds = $Keybinds
    }
    ($settings | ConvertTo-Json -Depth 5) | Set-Content -Path $script:SettingsPath -Encoding UTF8
}

function Load-AppSettings {
    $defaults = @{
        BaseUrl = 'https://api.anthropic.com'; ApiKey = ''; Model = 'claude-sonnet-4-6'
        AiEnabled = $false
        Keybinds = @{ New = 'N'; Open = 'O'; Save = 'S'; Export = 'E' }
    }
    if (Test-Path $script:SettingsPath) {
        try {
            $raw = Get-Content -Path $script:SettingsPath -Raw | ConvertFrom-Json
            $kb = $defaults.Keybinds.Clone()
            if ($raw.Keybinds) {
                if ($raw.Keybinds.New)    { $kb.New = [string]$raw.Keybinds.New }
                if ($raw.Keybinds.Open)   { $kb.Open = [string]$raw.Keybinds.Open }
                if ($raw.Keybinds.Save)   { $kb.Save = [string]$raw.Keybinds.Save }
                if ($raw.Keybinds.Export) { $kb.Export = [string]$raw.Keybinds.Export }
            }
            return @{
                BaseUrl = [string]$raw.BaseUrl; ApiKey = [string]$raw.ApiKey
                Model = [string]$raw.Model; AiEnabled = [bool]$raw.AiEnabled; Keybinds = $kb
            }
        } catch { }
    }
    return $defaults
}

function Export-ChecklistMarkdown {
    param($Checklist, [string]$Path)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# $($Checklist.Title)")
    [void]$sb.AppendLine("")
    if ($Checklist.Idea) {
        [void]$sb.AppendLine("_Idea: $($Checklist.Idea)_")
        [void]$sb.AppendLine("")
    }
    $stats = Get-ChecklistStats -Checklist $Checklist
    [void]$sb.AppendLine("**Progress: $($stats.Done)/$($stats.Total) ($($stats.Percent)%)**")
    [void]$sb.AppendLine("")
    foreach ($it in $Checklist.Items) {
        $mark = if ($it.Checked) { 'x' } else { ' ' }
        [void]$sb.AppendLine("- [$mark] $($it.Text)")
    }
    Set-Content -Path $Path -Value $sb.ToString() -Encoding UTF8
}

function Invoke-Autosave {
    if ($script:SuppressAutosave -or -not $script:Checklist) { return }
    try {
        $target = if ($script:CurrentFilePath) { $script:CurrentFilePath } else { $script:AutosavePath }
        Save-ChecklistToFile -Checklist $script:Checklist -Path $target
    } catch { }
}

function Confirm-DiscardIfDirty {
    if (-not $script:Dirty -or -not $script:Checklist) { return $true }
    $r = [System.Windows.MessageBox]::Show(
        "You have unsaved changes. Discard them?",
        "VertexPath",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    $r -eq [System.Windows.MessageBoxResult]::Yes
}

[xml]$xamlDoc = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VertexPath"
        Width="720" Height="820" MinWidth="520" MinHeight="560"
        WindowStartupLocation="CenterScreen"
        AllowDrop="True"
        Background="#0E0E0E"
        FontFamily="Segoe UI"
        TextElement.Foreground="#F0F0F0">

  <Window.Resources>
    <SolidColorBrush x:Key="Surface" Color="#1C1C1C"/>
    <SolidColorBrush x:Key="Surface2" Color="#252525"/>
    <SolidColorBrush x:Key="Line" Color="#333333"/>
    <SolidColorBrush x:Key="Accent" Color="#5B8DEF"/>
    <SolidColorBrush x:Key="AccentHover" Color="#6B9BFF"/>
    <SolidColorBrush x:Key="Muted" Color="#8A8A8A"/>
    <SolidColorBrush x:Key="Text" Color="#F0F0F0"/>
    <SolidColorBrush x:Key="Error" Color="#F87171"/>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Background" Value="#2A2A2A"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#353535"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TabBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="BorderThickness" Value="0,0,0,2"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TabBtnOn" TargetType="Button" BasedOn="{StaticResource TabBtn}">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
    </Style>

    <Style x:Key="DarkBox" TargetType="TextBox">
      <Setter Property="Background" Value="#1A1A1A"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="#333333"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BindBox" TargetType="TextBox" BasedOn="{StaticResource DarkBox}">
      <Setter Property="Width" Value="44"/>
      <Setter Property="MaxLength" Value="1"/>
      <Setter Property="CharacterCasing" Value="Upper"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Padding" Value="4,6"/>
    </Style>

    <Style x:Key="ModernCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Grid Width="20" Height="20" Margin="0,0,10,0">
                <Border x:Name="box" Background="#2A2A2A" BorderBrush="#444444" BorderThickness="1.5" CornerRadius="5"/>
                <Path x:Name="check" Data="M4,10 L8,14 L16,5" Stroke="#FFFFFF" StrokeThickness="2.2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="check" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ToggleSwitch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid>
              <Border x:Name="track" Width="38" Height="20" CornerRadius="10" Background="#2A2A2A" BorderBrush="#444" BorderThickness="1"/>
              <Ellipse x:Name="thumb" Width="14" Height="14" Fill="#8A8A8A" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="track" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="thumb" Property="Fill" Value="#FFFFFF"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Image x:Name="ImgBg" Stretch="UniformToFill" Opacity="0.42" IsHitTestVisible="False">
      <Image.Effect>
        <BlurEffect Radius="8"/>
      </Image.Effect>
    </Image>
    <Rectangle IsHitTestVisible="False">
      <Rectangle.Fill>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#CC0E0E0E" Offset="0"/>
          <GradientStop Color="#F20E0E0E" Offset="1"/>
        </LinearGradientBrush>
      </Rectangle.Fill>
    </Rectangle>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border Grid.Row="0" Padding="16,12" BorderBrush="#222" BorderThickness="0,0,0,1">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border Background="#2A2A2A" CornerRadius="8" Padding="8,3" VerticalAlignment="Center">
              <TextBlock x:Name="TxtVersion" Text="v1.0.0" FontSize="11" Foreground="#8A8A8A"/>
            </Border>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnNew" Content="New" Style="{StaticResource GhostBtn}" Margin="0,0,6,0"/>
            <Button x:Name="BtnOpen" Content="Open" Style="{StaticResource GhostBtn}" Margin="0,0,6,0"/>
            <Button x:Name="BtnSave" Content="Save" Style="{StaticResource GhostBtn}" Margin="0,0,6,0"/>
            <Button x:Name="BtnExport" Content="Export" Style="{StaticResource GhostBtn}"/>
          </StackPanel>
        </Grid>
      </Border>

      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="12,0">
        <Button x:Name="TabList" Content="Checklist" Style="{StaticResource TabBtnOn}"/>
        <Button x:Name="TabFaq" Content="FAQ" Style="{StaticResource TabBtn}"/>
        <Button x:Name="TabSettings" Content="Settings" Style="{StaticResource TabBtn}"/>
      </StackPanel>

      <Grid Grid.Row="2" Margin="16,12,16,8">
        <Grid x:Name="PageList">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Border Grid.Row="0" Background="#181818" CornerRadius="12" Padding="14" Margin="0,0,0,12" BorderBrush="#3A5A8A" BorderThickness="1">
            <StackPanel>
              <TextBlock Text="What do you need to do?" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,8"/>
              <Grid>
                <TextBox x:Name="TxtIdea" Style="{StaticResource DarkBox}" Height="88" AcceptsReturn="True"
                         TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                <TextBlock x:Name="TxtIdeaPh" Text="Type or paste notes. Each point, sentence, or bullet becomes a checklist item."
                           Foreground="#666" Margin="12,10,12,0" IsHitTestVisible="False" TextWrapping="Wrap"/>
              </Grid>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="BtnGenerate" Content="Make checklist" Style="{StaticResource PrimaryBtn}"/>
                <TextBlock x:Name="TxtGenHint" Text="From your words - or drop a .txt / .json" FontSize="12" Foreground="#8A8A8A"
                           VerticalAlignment="Center" Margin="12,0,0,0"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border Grid.Row="1" Background="#181818" CornerRadius="12" Padding="14" BorderBrush="#3A5A8A" BorderThickness="1">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>

              <Grid Grid.Row="0" Margin="0,0,0,8">
                <StackPanel Orientation="Horizontal">
                  <CheckBox x:Name="ChkTitleAll" Style="{StaticResource ModernCheck}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="TxtTitle" Text="No checklist yet" FontSize="16" FontWeight="SemiBold"
                             VerticalAlignment="Center" Margin="4,0,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button x:Name="BtnHideChecked" Content="Hide checked" Style="{StaticResource GhostBtn}" Margin="0,0,6,0"/>
                  <Button x:Name="BtnDeleteChecked" Content="Delete checked" Style="{StaticResource GhostBtn}"/>
                </StackPanel>
              </Grid>

              <Grid Grid.Row="1" Margin="0,0,0,4">
                <TextBlock x:Name="TxtPct" Text="0%" FontSize="12" Foreground="#8A8A8A"/>
              </Grid>
              <Border Grid.Row="2" Height="6" Background="#2A2A2A" CornerRadius="3" Margin="0,0,0,12">
                <Border x:Name="BarFill" Height="6" Background="{StaticResource Accent}" CornerRadius="3"
                        HorizontalAlignment="Left" Width="0"/>
              </Border>

              <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="PanelItems"/>
              </ScrollViewer>
            </Grid>
          </Border>
        </Grid>

                        <Border x:Name="PageFaq" Visibility="Collapsed" Background="#181818" CornerRadius="12" Padding="18"
                BorderBrush="#3A5A8A" BorderThickness="1">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Text="FAQ" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <TextBlock Text="Simple answers." FontSize="13" Foreground="#8A8A8A" Margin="0,0,0,16"/>

              <TextBlock Text="What does this do?" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
              <TextBlock Text="You type stuff you need to do. Hit Make checklist. You get checkboxes. Check them when you finish."
                         FontSize="13" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,14"/>

              <TextBlock Text="How do I write my list?" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
              <TextBlock Text="One thing per line is best.&#10;&#10;Buy milk&#10;Call mom&#10;Fix the camera&#10;&#10;Commas work too: milk, eggs, bread."
                         FontSize="13" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,14"/>

              <TextBlock Text="Can I drop a file in?" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
              <TextBlock Text="Yes. Drag a .txt or .json file onto the window.&#10;&#10;TXT = turns each line into a checkbox.&#10;JSON = opens a list you saved before."
                         FontSize="13" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,14"/>

              <TextBlock Text="What are the buttons?" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
              <TextBlock Text="Make checklist = build the list.&#10;Hide checked = hide finished stuff.&#10;Delete checked = remove finished stuff.&#10;New / Open / Save / Export = start over, load, save, or share as Markdown."
                         FontSize="13" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,14"/>

              <TextBlock Text="Where is my list saved?" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
              <TextBlock Text="It autosaves on this PC in Documents\VertexPath. You can also hit Save for a file you pick."
                         FontSize="13" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,14"/>

              <TextBlock Text="Do I need AI or the internet?" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
              <TextBlock Text="No. It works offline. AI in Settings is optional and off by default."
                         FontSize="13" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,14"/>

              <TextBlock Text="Shortcuts" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
              <TextBlock Text="Ctrl+N New, Ctrl+O Open, Ctrl+S Save, Ctrl+E Export. Change them in Settings if you want."
                         FontSize="13" Foreground="#8A8A8A" TextWrapping="Wrap"/>
            </StackPanel>
          </ScrollViewer>
        </Border>

<Border x:Name="PageSettings" Visibility="Collapsed" Background="#181818" CornerRadius="12" Padding="18"
                BorderBrush="#3A5A8A" BorderThickness="1">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Text="Settings" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <TextBlock Text="Updates, AI, keybinds, and links." FontSize="13" Foreground="#8A8A8A" Margin="0,0,0,16"/>

              <TextBlock Text="Updater" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <TextBlock Text="Downloads the latest VertexPath from GitHub into this folder and restarts the app."
                         FontSize="12.5" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,10"/>
              <Button x:Name="BtnCheckUpdate" Content="Update from GitHub" Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Left" Margin="0,0,0,8"/>
              <TextBlock x:Name="TxtUpdateHint" Text="" FontSize="12" Foreground="#8A8A8A" Margin="0,0,0,18" TextWrapping="Wrap"/>

              <TextBlock Text="AI generation" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <TextBlock Text="Optional. Leave off for the offline engine. Keys stay in Documents\VertexPath\settings.json."
                         FontSize="12.5" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,0,0,8"/>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                <TextBlock Text="Enable AI" FontSize="13" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <CheckBox x:Name="ToggleAI" Style="{StaticResource ToggleSwitch}"/>
              </StackPanel>
              <TextBlock Text="Base URL" FontSize="11" Foreground="#8A8A8A" Margin="0,0,0,4"/>
              <TextBox x:Name="TxtBaseUrl" Style="{StaticResource DarkBox}" Text="https://api.anthropic.com" Margin="0,0,0,8"/>
              <TextBlock Text="Model" FontSize="11" Foreground="#8A8A8A" Margin="0,0,0,4"/>
              <TextBox x:Name="TxtModel" Style="{StaticResource DarkBox}" Text="claude-sonnet-4-6" Margin="0,0,0,8"/>
              <TextBlock Text="API Key" FontSize="11" Foreground="#8A8A8A" Margin="0,0,0,4"/>
              <PasswordBox x:Name="TxtApiKey" Height="36" Padding="10,8" Margin="0,0,0,16"
                           Background="#1A1A1A" Foreground="#F0F0F0" BorderBrush="#333" BorderThickness="1"/>
              <TextBlock Text="Keyboard shortcuts" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <TextBlock Text="Ctrl + letter. Saved when you leave the field." FontSize="12.5" Foreground="#8A8A8A" Margin="0,0,0,10"/>
              <Grid Margin="0,0,0,16">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="90"/><ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="28"/>
                  <ColumnDefinition Width="90"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="New" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal">
                  <TextBlock Text="Ctrl+" Foreground="#8A8A8A" VerticalAlignment="Center" Margin="0,0,4,0"/>
                  <TextBox x:Name="TxtBindNew" Style="{StaticResource BindBox}" Text="N"/>
                </StackPanel>
                <TextBlock Grid.Row="0" Grid.Column="3" Text="Open" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="0" Grid.Column="4" Orientation="Horizontal">
                  <TextBlock Text="Ctrl+" Foreground="#8A8A8A" VerticalAlignment="Center" Margin="0,0,4,0"/>
                  <TextBox x:Name="TxtBindOpen" Style="{StaticResource BindBox}" Text="O"/>
                </StackPanel>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="Save" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="2" Grid.Column="1" Orientation="Horizontal">
                  <TextBlock Text="Ctrl+" Foreground="#8A8A8A" VerticalAlignment="Center" Margin="0,0,4,0"/>
                  <TextBox x:Name="TxtBindSave" Style="{StaticResource BindBox}" Text="S"/>
                </StackPanel>
                <TextBlock Grid.Row="2" Grid.Column="3" Text="Export" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="2" Grid.Column="4" Orientation="Horizontal">
                  <TextBlock Text="Ctrl+" Foreground="#8A8A8A" VerticalAlignment="Center" Margin="0,0,4,0"/>
                  <TextBox x:Name="TxtBindExport" Style="{StaticResource BindBox}" Text="E"/>
                </StackPanel>
              </Grid>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnGitHub" Content="GitHub" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnRepo" Content="Repo" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnDataFolder" Content="Data folder" Style="{StaticResource GhostBtn}"/>
              </StackPanel>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </Grid>

      <Border Grid.Row="3" Padding="16,8" BorderBrush="#222" BorderThickness="0,1,0,0">
        <Grid>
          <TextBlock x:Name="TxtStatus" Text="Ready." FontSize="11.5" Foreground="#8A8A8A"/>
          <TextBlock x:Name="TxtFile" Text="Unsaved" FontSize="11.5" Foreground="#8A8A8A" HorizontalAlignment="Right"/>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
"@

$Window = $null
try {
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    $Window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Host "VertexPath failed to load UI: $($_.Exception.Message)" -ForegroundColor Red
    try { [System.Windows.MessageBox]::Show("Could not create window.`n$($_.Exception.Message)", "VertexPath") | Out-Null } catch {}
    exit 1
}

try {
    $ImgBg = $Window.FindName("ImgBg")
    if ($ImgBg -and (Test-Path -LiteralPath $script:BgPath)) {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = [Uri]$script:BgPath
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $ImgBg.Source = $bmp
    }
} catch {}

try {
    $ico = Join-Path $script:ScriptDir "icon.png"
    if (Test-Path -LiteralPath $ico) {
        $ib = New-Object System.Windows.Media.Imaging.BitmapImage
        $ib.BeginInit(); $ib.UriSource = [Uri]$ico; $ib.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $ib.EndInit()
        $Window.Icon = $ib
    }
} catch {}

$Window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        $useDark = 1
        [DwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$useDark, 4) | Out-Null
    } catch {}
})

function U([string]$Name) { $Window.FindName($Name) }

$TxtIdea = U 'TxtIdea'; $TxtIdeaPh = U 'TxtIdeaPh'; $BtnGenerate = U 'BtnGenerate'
$TxtGenHint = U 'TxtGenHint'; $TxtTitle = U 'TxtTitle'; $TxtPct = U 'TxtPct'
$BarFill = U 'BarFill'; $PanelItems = U 'PanelItems'
$ChkTitleAll = U 'ChkTitleAll'; $BtnHideChecked = U 'BtnHideChecked'; $BtnDeleteChecked = U 'BtnDeleteChecked'
$TxtStatus = U 'TxtStatus'; $TxtFile = U 'TxtFile'
$PageList = U 'PageList'; $PageFaq = U 'PageFaq'; $PageSettings = U 'PageSettings'
$TabList = U 'TabList'; $TabFaq = U 'TabFaq'; $TabSettings = U 'TabSettings'
$BtnNew = U 'BtnNew'; $BtnOpen = U 'BtnOpen'; $BtnSave = U 'BtnSave'; $BtnExport = U 'BtnExport'
$ToggleAI = U 'ToggleAI'; $TxtBaseUrl = U 'TxtBaseUrl'; $TxtModel = U 'TxtModel'; $TxtApiKey = U 'TxtApiKey'
$TxtBindNew = U 'TxtBindNew'; $TxtBindOpen = U 'TxtBindOpen'; $TxtBindSave = U 'TxtBindSave'; $TxtBindExport = U 'TxtBindExport'
$BtnGitHub = U 'BtnGitHub'; $BtnRepo = U 'BtnRepo'; $BtnDataFolder = U 'BtnDataFolder'
$BtnCheckUpdate = U 'BtnCheckUpdate'
$TxtUpdateHint = U 'TxtUpdateHint'
$TxtVersion = U 'TxtVersion'
$TxtVersion.Text = "v$script:AppVersion"

$settings = Load-AppSettings
$TxtBaseUrl.Text = $settings.BaseUrl
$TxtApiKey.Password = $settings.ApiKey
$TxtModel.Text = $settings.Model
if ($settings.AiEnabled) { $ToggleAI.IsChecked = $true }
$script:Keybinds = $settings.Keybinds
$TxtBindNew.Text = $script:Keybinds.New
$TxtBindOpen.Text = $script:Keybinds.Open
$TxtBindSave.Text = $script:Keybinds.Save
$TxtBindExport.Text = $script:Keybinds.Export

function Set-Status([string]$Msg, [bool]$Err = $false) {
    $TxtStatus.Text = $Msg
    $TxtStatus.Foreground = if ($Err) { $Window.FindResource('Error') } else { $Window.FindResource('Muted') }
}

function Update-FileLabel {
    $mark = if ($script:Dirty -and $script:Checklist) { ' *' } else { '' }
    if ($script:CurrentFilePath) {
        $TxtFile.Text = ([IO.Path]::GetFileName($script:CurrentFilePath)) + $mark
        $TxtFile.ToolTip = $script:CurrentFilePath
    } else {
        $TxtFile.Text = "Unsaved$mark"
        $TxtFile.ToolTip = $script:AutosavePath
    }
}

function Mark-Dirty {
    $script:Dirty = $true
    Update-FileLabel
}

function Update-GenHint {
    if ($ToggleAI.IsChecked) {
        $TxtGenHint.Text = "AI on - else extracts from your text"
    } else {
        $TxtGenHint.Text = "From your words - or drop a .txt / .json"
    }
}
Update-GenHint

function Start-PageFade {
    param($Element)
    if (-not $Element) { return }
    $Element.Opacity = 0
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0
    $anim.To = 1
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220))
    $anim.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase -Property @{ EasingMode = 'EaseOut' }
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
}

function Set-ActiveTab([string]$Name) {
    $PageList.Visibility = 'Collapsed'
    $PageFaq.Visibility = 'Collapsed'
    $PageSettings.Visibility = 'Collapsed'
    $TabList.Style = $Window.FindResource('TabBtn')
    $TabFaq.Style = $Window.FindResource('TabBtn')
    $TabSettings.Style = $Window.FindResource('TabBtn')
    $target = $null
    switch ($Name) {
        'List' {
            $PageList.Visibility = 'Visible'
            $TabList.Style = $Window.FindResource('TabBtnOn')
            $target = $PageList
        }
        'FAQ' {
            $PageFaq.Visibility = 'Visible'
            $TabFaq.Style = $Window.FindResource('TabBtnOn')
            $target = $PageFaq
        }
        'Settings' {
            $PageSettings.Visibility = 'Visible'
            $TabSettings.Style = $Window.FindResource('TabBtnOn')
            $target = $PageSettings
        }
    }
    if ($target) { Start-PageFade -Element $target }
}

$TabList.Add_Click({ Set-ActiveTab 'List' })
$TabFaq.Add_Click({ Set-ActiveTab 'FAQ' })
$TabSettings.Add_Click({ Set-ActiveTab 'Settings' })

$TxtIdea.Add_TextChanged({
    $TxtIdeaPh.Visibility = if ($TxtIdea.Text.Length -eq 0) { 'Visible' } else { 'Collapsed' }
})

function Normalize-Bind([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $c = $Raw.Trim().ToUpperInvariant()
    if ($c.Length -eq 1 -and $c -match '^[A-Z0-9]$') { return $c }
    $null
}

function Save-CurrentSettings {
    $kb = @{
        New    = (Normalize-Bind $TxtBindNew.Text)
        Open   = (Normalize-Bind $TxtBindOpen.Text)
        Save   = (Normalize-Bind $TxtBindSave.Text)
        Export = (Normalize-Bind $TxtBindExport.Text)
    }
    if (-not $kb.New)    { $kb.New = 'N'; $TxtBindNew.Text = 'N' }
    if (-not $kb.Open)   { $kb.Open = 'O'; $TxtBindOpen.Text = 'O' }
    if (-not $kb.Save)   { $kb.Save = 'S'; $TxtBindSave.Text = 'S' }
    if (-not $kb.Export) { $kb.Export = 'E'; $TxtBindExport.Text = 'E' }
    $script:Keybinds = $kb
    Save-AppSettings -BaseUrl $TxtBaseUrl.Text -ApiKey $TxtApiKey.Password -Model $TxtModel.Text `
        -AiEnabled ([bool]$ToggleAI.IsChecked) -Keybinds $kb
}

$ToggleAI.Add_Checked({ Save-CurrentSettings; Update-GenHint })
$ToggleAI.Add_Unchecked({ Save-CurrentSettings; Update-GenHint })
$TxtBaseUrl.Add_LostFocus({ Save-CurrentSettings })
$TxtModel.Add_LostFocus({ Save-CurrentSettings })
$TxtApiKey.Add_LostFocus({ Save-CurrentSettings })
$TxtBindNew.Add_LostFocus({ Save-CurrentSettings })
$TxtBindOpen.Add_LostFocus({ Save-CurrentSettings })
$TxtBindSave.Add_LostFocus({ Save-CurrentSettings })
$TxtBindExport.Add_LostFocus({ Save-CurrentSettings })

$Window.Add_KeyDown({
    param($s, $e)
    if ($e.KeyboardDevice.Modifiers -ne [System.Windows.Input.ModifierKeys]::Control) { return }
    $k = $e.Key.ToString().ToUpperInvariant()
    if ($k -match '^D([0-9])$') { $k = $Matches[1] }
    if ($k -eq $script:Keybinds.New)    { Do-New; $e.Handled = $true }
    elseif ($k -eq $script:Keybinds.Open)   { Do-Open; $e.Handled = $true }
    elseif ($k -eq $script:Keybinds.Save)   { Do-Save; $e.Handled = $true }
    elseif ($k -eq $script:Keybinds.Export) { Do-Export; $e.Handled = $true }
})

function Open-Url([string]$Url) {
    if ($Url -notmatch '^https?://') { Set-Status "Blocked unsafe link." $true; return }
    try { Start-Process $Url } catch { Set-Status "Could not open browser." $true }
}

$BtnGitHub.Add_Click({ Open-Url $script:GitHubUrl })
$BtnRepo.Add_Click({ Open-Url $script:RepoUrl })
$BtnDataFolder.Add_Click({
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList $script:DataDir
    } catch { Set-Status "Could not open folder." $true }
})

$BtnCheckUpdate.Add_Click({
    $BtnCheckUpdate.IsEnabled = $false
    if ($TxtUpdateHint) { $TxtUpdateHint.Text = "Downloading from GitHub..." }
    Set-Status "Updating from GitHub..."
    try {
        $baseRaw = "https://raw.githubusercontent.com/herfavknife/vertexpath/main"
        $files = @(
            @{ Name = "VertexPath.ps1"; Url = "$baseRaw/VertexPath.ps1" },
            @{ Name = "VertexPath.cmd"; Url = "$baseRaw/VertexPath.cmd" }
        )
        $updated = @()
        foreach ($f in $files) {
            $dest = Join-Path $script:ScriptDir $f.Name
            $tmp  = Join-Path $env:TEMP ("vertexpath_" + $f.Name + ".tmp")
            try {
                Invoke-WebRequest -Uri $f.Url -OutFile $tmp -UseBasicParsing -TimeoutSec 60
                # basic sanity: non-empty
                if (-not (Test-Path -LiteralPath $tmp) -or ((Get-Item -LiteralPath $tmp).Length -lt 50)) {
                    throw "Empty or missing download for $($f.Name)"
                }
                Copy-Item -LiteralPath $tmp -Destination $dest -Force
                $updated += $f.Name
            } catch {
                # cmd is optional; ps1 is required
                if ($f.Name -eq "VertexPath.ps1") { throw }
            } finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        if ($updated -notcontains "VertexPath.ps1") {
            throw "Could not download VertexPath.ps1 from GitHub."
        }
        if ($TxtUpdateHint) {
            $TxtUpdateHint.Text = ("Updated: {0}. Restarting..." -f ($updated -join ", "))
        }
        Set-Status "Update installed. Restarting..."
        $psExe = (Get-Process -Id $PID).Path
        $newScript = Join-Path $script:ScriptDir "VertexPath.ps1"
        $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $newScript)
        if ($script:DebugMode) { $argsList += '-Debug' }
        Start-Process -FilePath $psExe -ArgumentList $argsList | Out-Null
        $Window.Close()
    } catch {
        $msg = $_.Exception.Message
        if ($TxtUpdateHint) {
            $TxtUpdateHint.Text = "Update failed: $msg  You can still grab files at $($script:RepoUrl)"
        }
        Set-Status "Update failed: $msg" $true
        $BtnCheckUpdate.IsEnabled = $true
    }
})

function Refresh-Progress {
    if (-not $script:Checklist) {
        $TxtPct.Text = "0%"
        $BarFill.Width = 0
        $ChkTitleAll.IsChecked = $false
        return
    }
    $stats = Get-ChecklistStats -Checklist $script:Checklist
    $TxtPct.Text = "$($stats.Percent)%"
    $parent = $BarFill.Parent
    $full = if ($parent -and $parent.ActualWidth -gt 0) { $parent.ActualWidth } else { 400 }
    $BarFill.Width = [math]::Max(0, ($stats.Percent / 100.0) * $full)
    if ($stats.Total -gt 0 -and $stats.Done -eq $stats.Total) {
        $ChkTitleAll.IsChecked = $true
    } else {
        $ChkTitleAll.IsChecked = $false
    }
}

function Rebuild-List {
    $PanelItems.Children.Clear()
    if (-not $script:Checklist) {
        $TxtTitle.Text = "No checklist yet"
        Refresh-Progress
        return
    }
    $TxtTitle.Text = $script:Checklist.Title
    foreach ($it in $script:Checklist.Items) {
        if ($script:HideChecked -and $it.Checked) { continue }

        $row = New-Object System.Windows.Controls.Border
        $row.Padding = New-Object System.Windows.Thickness(4, 6, 4, 6)
        $row.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $row.Margin = New-Object System.Windows.Thickness(0, 1, 0, 1)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('ModernCheck')
        $cb.IsChecked = [bool]$it.Checked
        $cb.Tag = $it

        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $it.Text
        $tb.FontSize = 14
        $tb.TextWrapping = 'Wrap'
        $tb.VerticalAlignment = 'Center'
        if ($it.Checked) {
            $tb.Foreground = $Window.FindResource('Muted')
            $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
        } else {
            $tb.Foreground = $Window.FindResource('Text')
        }
        $cb.Content = $tb

        $cb.Add_Click({
            $node = $this.Tag
            $node.Checked = [bool]$this.IsChecked
            Mark-Dirty
            Invoke-Autosave
            Rebuild-List
        }.GetNewClosure())

        $row.Child = $cb
        [void]$PanelItems.Children.Add($row)
    }
    Refresh-Progress
}

$ChkTitleAll.Add_Click({
    if (-not $script:Checklist) { return }
    $val = [bool]$ChkTitleAll.IsChecked
    foreach ($it in $script:Checklist.Items) { $it.Checked = $val }
    Mark-Dirty
    Invoke-Autosave
    Rebuild-List
})

$BtnHideChecked.Add_Click({
    $script:HideChecked = -not $script:HideChecked
    $BtnHideChecked.Content = if ($script:HideChecked) { "Show checked" } else { "Hide checked" }
    Rebuild-List
})

$BtnDeleteChecked.Add_Click({
    if (-not $script:Checklist) { return }
    $kept = @($script:Checklist.Items | Where-Object { -not $_.Checked })
    if ($kept.Count -eq $script:Checklist.Items.Count) {
        Set-Status "No checked items to delete."
        return
    }
    $script:Checklist.Items = $kept
    Mark-Dirty
    Invoke-Autosave
    Rebuild-List
    Set-Status "Deleted checked items."
})

$Window.Add_SizeChanged({
    if ($script:Checklist) { Refresh-Progress }
})

$BtnGenerate.Add_Click({
    $idea = $TxtIdea.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($idea)) {
        Set-Status "Type an idea before generating." $true
        return
    }
    if ($script:Checklist -and -not (Confirm-DiscardIfDirty)) { return }

    $BtnGenerate.IsEnabled = $false
    try {
        if ($ToggleAI.IsChecked) {
            Set-Status "Generating with AI..."
            $Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
            try {
                $script:Checklist = Invoke-AIChecklistGeneration -Idea $idea -BaseUrl $TxtBaseUrl.Text.Trim() `
                    -ApiKey $TxtApiKey.Password.Trim() -Model $TxtModel.Text.Trim()
                Set-Status "Generated with AI."
            } catch {
                Set-Status "AI failed ($($_.Exception.Message)) - extracting from your text." $true
                try {
                    $script:Checklist = Generate-LocalChecklist -Idea $idea
                } catch {
                    Set-Status $_.Exception.Message $true
                    return
                }
            }
        } else {
            try {
                $script:Checklist = Generate-LocalChecklist -Idea $idea
                Set-Status ("Made {0} items from your text." -f $script:Checklist.Items.Count)
            } catch {
                Set-Status $_.Exception.Message $true
                return
            }
        }
        $script:CurrentFilePath = $null
        $script:Dirty = $true
        Update-FileLabel
        Rebuild-List
        Invoke-Autosave
    } finally {
        $BtnGenerate.IsEnabled = $true
    }
})

function Do-New {
    if (-not (Confirm-DiscardIfDirty)) { return }
    $script:Checklist = $null
    $script:CurrentFilePath = $null
    $script:Dirty = $false
    $TxtIdea.Text = ""
    Rebuild-List
    Update-FileLabel
    Set-Status "Ready for a new idea."
}

function Do-Save {
    if (-not $script:Checklist) { Set-Status "Nothing to save yet." $true; return }
    try {
        if (-not $script:CurrentFilePath) {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.InitialDirectory = $script:DataDir
            $dlg.Filter = "VertexPath Checklist (*.json)|*.json"
            $dlg.FileName = ($script:Checklist.Title -replace '[\\/:*?""<>|]', '_')
            if ($dlg.ShowDialog() -ne $true) { return }
            $script:CurrentFilePath = $dlg.FileName
        }
        Save-ChecklistToFile -Checklist $script:Checklist -Path $script:CurrentFilePath
        Update-FileLabel
        Set-Status "Saved."
    } catch {
        Set-Status "Save failed: $($_.Exception.Message)" $true
    }
}

function Do-Open {
    if (-not (Confirm-DiscardIfDirty)) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.InitialDirectory = $script:DataDir
    $dlg.Filter = "Checklist or text (*.json;*.txt;*.md)|*.json;*.txt;*.md|JSON (*.json)|*.json|Text (*.txt;*.md)|*.txt;*.md"
    if ($dlg.ShowDialog() -ne $true) { return }
    try {
        Import-DroppedOrPickedFile -Path $dlg.FileName
    } catch {
        Set-Status "Load failed: $($_.Exception.Message)" $true
    }
}

function Do-Export {
    if (-not $script:Checklist) { Set-Status "Nothing to export yet." $true; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = "Markdown (*.md)|*.md"
    $dlg.FileName = ($script:Checklist.Title -replace '[\\/:*?""<>|]', '_')
    if ($dlg.ShowDialog() -ne $true) { return }
    try {
        Export-ChecklistMarkdown -Checklist $script:Checklist -Path $dlg.FileName
        Set-Status "Exported Markdown."
    } catch {
        Set-Status "Export failed: $($_.Exception.Message)" $true
    }
}

$BtnNew.Add_Click({ Do-New })
$BtnSave.Add_Click({ Do-Save })
$BtnOpen.Add_Click({ Do-Open })
$BtnExport.Add_Click({ Do-Export })

if (Test-Path $script:AutosavePath) {
    try {
        $script:SuppressAutosave = $true
        $script:Checklist = Load-ChecklistFromFile -Path $script:AutosavePath
        if ($script:Checklist.Idea) { $TxtIdea.Text = $script:Checklist.Idea }
        Rebuild-List
        $script:Dirty = $false
        Update-FileLabel
        Set-Status "Restored last session."
    } catch {
    } finally {
        $script:SuppressAutosave = $false
    }
}


function Import-FromTxtFile {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "File is empty." }
    $TxtIdea.Text = $raw.Trim()
    $script:Checklist = Generate-LocalChecklist -Idea $raw.Trim()
    $script:CurrentFilePath = $null
    $script:Dirty = $true
    Update-FileLabel
    Rebuild-List
    Invoke-Autosave
    Set-Status ("Loaded TXT - {0} items." -f $script:Checklist.Items.Count)
}

function Import-DroppedOrPickedFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found." }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.json') {
        $script:Checklist = Load-ChecklistFromFile -Path $Path
        $script:CurrentFilePath = $Path
        $script:Dirty = $false
        if ($script:Checklist.Idea) { $TxtIdea.Text = $script:Checklist.Idea }
        Rebuild-List
        Update-FileLabel
        Set-Status "Loaded JSON."
    } elseif ($ext -eq '.txt' -or $ext -eq '.text' -or $ext -eq '.md') {
        Import-FromTxtFile -Path $Path
    } else {
        throw "Use a .txt or .json file."
    }
}

$Window.Add_DragOver({
    param($s, $e)
    $e.Effects = [System.Windows.DragDropEffects]::None
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        if ($files -and $files.Count -ge 1) {
            $ext = [IO.Path]::GetExtension([string]$files[0]).ToLowerInvariant()
            if ($ext -in @('.txt', '.text', '.md', '.json')) {
                $e.Effects = [System.Windows.DragDropEffects]::Copy
            }
        }
    }
    $e.Handled = $true
})

$Window.Add_Drop({
    param($s, $e)
    try {
        if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        if (-not $files -or $files.Count -lt 1) { return }
        if ($script:Checklist -and -not (Confirm-DiscardIfDirty)) { return }
        Import-DroppedOrPickedFile -Path ([string]$files[0])
    } catch {
        Set-Status ("Drop failed: {0}" -f $_.Exception.Message) $true
    }
})


[void]$Window.ShowDialog()
