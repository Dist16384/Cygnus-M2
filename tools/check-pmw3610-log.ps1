[CmdletBinding(DefaultParameterSetName = 'Capture')]
param(
    [Parameter(ParameterSetName = 'Capture')]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [Parameter(ParameterSetName = 'Capture')]
    [ValidateRange(5, 3600)]
    [int]$DurationSeconds = 20,

    [Parameter(ParameterSetName = 'Capture')]
    [ValidateRange(1, 600)]
    [int]$PortWaitSeconds = 60,

    [Parameter(ParameterSetName = 'Capture')]
    [ValidateRange(1200, 3000000)]
    [int]$BaudRate = 115200,

    [Parameter(ParameterSetName = 'Capture')]
    [string]$LogPath,

    [Parameter(Mandatory, ParameterSetName = 'Analyze')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputLog,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-AnsiEscape {
    param([AllowEmptyString()][string]$Text)

    $escape = [regex]::Escape([string][char]27)
    return [regex]::Replace($Text, "$escape\[[0-?]*[ -/]*[@-~]", '')
}

function Get-Pmw3610Diagnosis {
    param([AllowEmptyString()][string]$Text)

    $cleanText = Remove-AnsiEscape -Text $Text
    $lines = @($cleanText -split "\r?\n")
    $stepMatches = [regex]::Matches($cleanText, '(?i)PMW3610 async init step\s+(\d+)')
    $steps = @($stepMatches | ForEach-Object { [int]$_.Groups[1].Value } | Select-Object -Unique)
    $initialized = $cleanText -match '(?i)PMW3610 initialized'
    $motionSamples = [regex]::Matches($cleanText, '(?i)x/y:\s*-?\d+/-?\d+').Count

    $hardErrorPattern = '(?i)(<err>\s+pmw3610:|PMW3610 initialization failed|Failed self-test|Incorrect product id|Cannot obtain product id|Config the sensor failed|IRQ GPIO device not ready|Cannot configure IRQ GPIO|Cannot add IRQ GPIO callback|Burst write failed)'
    $warningPattern = '(?i)(<wrn>\s+pmw3610:|Device is not initialized yet|NO EVENT, leaving early)'
    $hardErrors = @($lines | Where-Object { $_ -match $hardErrorPattern } | Select-Object -Unique)
    $warnings = @($lines | Where-Object { $_ -match $warningPattern } | Select-Object -Unique)

    $diagnosis = 'No PMW3610 initialization result was found.'
    if ($cleanText -match '(?i)Incorrect product id') {
        $diagnosis = 'Product ID read failed. Check sensor power-up timing, SPI wiring, and chip select.'
    }
    elseif ($cleanText -match '(?i)Failed self-test') {
        $diagnosis = 'Sensor self-test failed. Check power stability and SPI communication.'
    }
    elseif ($cleanText -match '(?i)(IRQ GPIO device not ready|Cannot configure IRQ GPIO|Cannot add IRQ GPIO callback)') {
        $diagnosis = 'IRQ setup failed. Check the interrupt GPIO definition and wiring.'
    }
    elseif ($cleanText -match '(?i)Config the sensor failed') {
        $diagnosis = 'Sensor register configuration failed after identification.'
    }
    elseif ($cleanText -match '(?i)PMW3610 initialization failed in step\s+(\d+)') {
        switch ([int]$Matches[1]) {
            0 { $diagnosis = 'Power-up reset write failed. Check sensor power and SPI.' }
            1 { $diagnosis = 'Observation register clear failed. Check SPI writes.' }
            2 { $diagnosis = 'Self-test or product ID check failed. Check power-up timing and SPI reads.' }
            3 { $diagnosis = 'CPI or power-management register configuration failed.' }
            default { $diagnosis = 'Initialization failed at an unknown driver step.' }
        }
    }
    elseif ($initialized -and $motionSamples -gt 0) {
        $diagnosis = 'Initialization and motion reporting both succeeded.'
    }
    elseif ($initialized) {
        $diagnosis = 'Initialization succeeded, but no motion sample was captured. Move the trackball during capture.'
    }

    if ($hardErrors.Count -gt 0) {
        $result = 'FAIL'
        $exitCode = 1
    }
    elseif ($initialized -and $motionSamples -gt 0) {
        $result = 'PASS'
        $exitCode = 0
    }
    elseif ($initialized) {
        $result = 'WARN'
        $exitCode = 2
    }
    else {
        $result = 'INCOMPLETE'
        $exitCode = 3
    }

    return [pscustomobject]@{
        Result        = $result
        ExitCode      = $exitCode
        Initialized   = $initialized
        InitSteps     = $steps
        MotionSamples = $motionSamples
        HardErrors    = $hardErrors
        Warnings      = $warnings
        Diagnosis     = $diagnosis
        CleanText     = $cleanText
    }
}

function Show-Pmw3610Diagnosis {
    param(
        [Parameter(Mandatory)]$Diagnosis,
        [string]$Source
    )

    $color = switch ($Diagnosis.Result) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Yellow' }
    }

    Write-Host ''
    Write-Host "PMW3610 CHECK: $($Diagnosis.Result)" -ForegroundColor $color
    Write-Host "Initialized: $($Diagnosis.Initialized)"
    Write-Host "Init steps: $($Diagnosis.InitSteps -join ', ')"
    Write-Host "Motion samples: $($Diagnosis.MotionSamples)"
    Write-Host "Diagnosis: $($Diagnosis.Diagnosis)"
    if ($Source) {
        Write-Host "Log: $Source"
    }
    if ($Diagnosis.HardErrors.Count -gt 0) {
        Write-Host 'Detected errors:' -ForegroundColor Red
        $Diagnosis.HardErrors | ForEach-Object { Write-Host "  $_" }
    }
    if ($Diagnosis.Warnings.Count -gt 0) {
        Write-Host 'Detected warnings:' -ForegroundColor Yellow
        $Diagnosis.Warnings | ForEach-Object { Write-Host "  $_" }
    }
}

function Get-SerialPortInfo {
    $portNames = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
    $friendlyNames = @{}

    try {
        Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.Name -match '\(COM\d+\)' } |
            ForEach-Object {
                $match = [regex]::Match([string]$_.Name, '\((COM\d+)\)')
                if ($match.Success) {
                    $friendlyNames[$match.Groups[1].Value] = [string]$_.Name
                }
            }
    }
    catch {
        # Port enumeration still works without CIM metadata.
    }

    foreach ($portName in $portNames) {
        $friendlyName = if ($friendlyNames.ContainsKey($portName)) {
            $friendlyNames[$portName]
        }
        else {
            $portName
        }

        [pscustomobject]@{
            Port         = $portName
            FriendlyName = $friendlyName
        }
    }
}

function Resolve-LoggingPort {
    param(
        [string]$RequestedPort,
        [int]$WaitSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $waitingMessageShown = $false
    if ($RequestedPort) {
        $RequestedPort = $RequestedPort.ToUpperInvariant()
    }

    while ([DateTime]::UtcNow -lt $deadline) {
        $ports = @(Get-SerialPortInfo)

        if ($RequestedPort) {
            if ($ports.Port -contains $RequestedPort) {
                return $RequestedPort
            }
        }
        else {
            $candidates = @($ports | Where-Object {
                $_.FriendlyName -match '(?i)(Cygnus|ZMK|USB Serial|CDC)'
            })

            if ($candidates.Count -eq 1) {
                Write-Host "Auto-detected $($candidates[0].Port): $($candidates[0].FriendlyName)"
                return $candidates[0].Port
            }
            if ($candidates.Count -gt 1) {
                $list = ($candidates | ForEach-Object { "$($_.Port): $($_.FriendlyName)" }) -join [Environment]::NewLine
                throw "Multiple USB serial ports were found. Re-run with -Port COMx:`n$list"
            }
            if ($ports.Count -eq 1) {
                Write-Host "Using the only serial port found: $($ports[0].Port)"
                return $ports[0].Port
            }
            if ($ports.Count -gt 1) {
                $list = ($ports | ForEach-Object { "$($_.Port): $($_.FriendlyName)" }) -join [Environment]::NewLine
                throw "Multiple serial ports were found. Re-run with -Port COMx:`n$list"
            }
        }

        if (-not $waitingMessageShown) {
            if ($RequestedPort) {
                Write-Host "Waiting for $RequestedPort. Connect or power-cycle the logging firmware now."
            }
            else {
                Write-Host 'Waiting for the USB logging serial port. Connect the right half now.'
            }
            $waitingMessageShown = $true
        }
        Start-Sleep -Milliseconds 250
    }

    if ($RequestedPort) {
        throw "Timed out waiting for $RequestedPort."
    }
    throw 'Timed out waiting for a USB logging serial port.'
}

function New-LoggingSerialPort {
    param(
        [string]$PortName,
        [int]$Speed
    )

    $serial = New-Object System.IO.Ports.SerialPort(
        $PortName,
        $Speed,
        [System.IO.Ports.Parity]::None,
        8,
        [System.IO.Ports.StopBits]::One
    )
    $serial.Handshake = [System.IO.Ports.Handshake]::None
    $serial.DtrEnable = $true
    $serial.ReadTimeout = 250
    $serial.Encoding = [System.Text.Encoding]::ASCII
    return $serial
}

function Invoke-Capture {
    param(
        [string]$PortName,
        [int]$Speed,
        [int]$Seconds
    )

    $builder = New-Object System.Text.StringBuilder
    $serial = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $connectedOnce = $false
    $disconnectReported = $false

    Write-Host "Capturing $PortName for $Seconds seconds. Move the trackball during capture."
    Write-Host 'A USB reset or cold-boot disconnect is handled by automatic reconnect.'

    try {
        while ($stopwatch.Elapsed.TotalSeconds -lt $Seconds) {
            if ($null -eq $serial -or -not $serial.IsOpen) {
                if (-not ([System.IO.Ports.SerialPort]::GetPortNames() -contains $PortName)) {
                    Start-Sleep -Milliseconds 100
                    continue
                }

                try {
                    $serial = New-LoggingSerialPort -PortName $PortName -Speed $Speed
                    $serial.Open()
                    if ($connectedOnce) {
                        Write-Host "Reconnected to $PortName."
                    }
                    else {
                        Write-Host "Connected to $PortName."
                        $connectedOnce = $true
                    }
                    $disconnectReported = $false
                }
                catch {
                    if ($null -ne $serial) {
                        $serial.Dispose()
                        $serial = $null
                    }
                    Start-Sleep -Milliseconds 250
                    continue
                }
            }

            try {
                $chunk = $serial.ReadExisting()
                if ($chunk.Length -gt 0) {
                    [Console]::Write($chunk)
                    [void]$builder.Append($chunk)
                }
            }
            catch {
                if (-not $disconnectReported) {
                    Write-Host "`nSerial port disconnected; waiting for $PortName to return."
                    $disconnectReported = $true
                }
                if ($null -ne $serial) {
                    try { $serial.Close() } catch {}
                    $serial.Dispose()
                    $serial = $null
                }
            }

            Start-Sleep -Milliseconds 50
        }
    }
    finally {
        if ($null -ne $serial) {
            try {
                if ($serial.IsOpen) {
                    $remaining = $serial.ReadExisting()
                    if ($remaining.Length -gt 0) {
                        [Console]::Write($remaining)
                        [void]$builder.Append($remaining)
                    }
                    $serial.Close()
                }
            }
            catch {}
            $serial.Dispose()
        }
    }

    if (-not $connectedOnce) {
        throw "Could not open $PortName. Close ZMK Studio, PuTTY, and other serial monitors, then retry."
    }

    return $builder.ToString()
}

function Invoke-SelfTest {
    $cases = @(
        [pscustomobject]@{
            Name = 'Successful initialization and motion'
            Text = "PMW3610 async init step 0`nPMW3610 async init step 1`nPMW3610 async init step 2`nPMW3610 async init step 3`nPMW3610 initialized`nx/y: 12/-4"
            Expected = 'PASS'
        },
        [pscustomobject]@{
            Name = 'Product ID failure'
            Text = "PMW3610 async init step 2`nIncorrect product id 0xff (expecting 0x3e)!`nPMW3610 initialization failed in step 2"
            Expected = 'FAIL'
        },
        [pscustomobject]@{
            Name = 'Initialized without motion'
            Text = "PMW3610 async init step 3`nPMW3610 initialized"
            Expected = 'WARN'
        },
        [pscustomobject]@{
            Name = 'Generic PMW3610 module error'
            Text = '<err> pmw3610: Failed to set CPI'
            Expected = 'FAIL'
        },
        [pscustomobject]@{
            Name = 'No PMW3610 data'
            Text = 'ZMK booted'
            Expected = 'INCOMPLETE'
        }
    )

    foreach ($case in $cases) {
        $actual = (Get-Pmw3610Diagnosis -Text $case.Text).Result
        if ($actual -ne $case.Expected) {
            throw "Self-test failed: $($case.Name); expected $($case.Expected), got $actual"
        }
        Write-Host "PASS: $($case.Name)"
    }
}

if ($PSCmdlet.ParameterSetName -eq 'SelfTest') {
    Invoke-SelfTest
    exit 0
}

if ($PSCmdlet.ParameterSetName -eq 'Analyze') {
    $inputPath = (Resolve-Path -LiteralPath $InputLog).Path
    $text = [System.IO.File]::ReadAllText($inputPath)
    $diagnosis = Get-Pmw3610Diagnosis -Text $text
    Show-Pmw3610Diagnosis -Diagnosis $diagnosis -Source $inputPath
    exit $diagnosis.ExitCode
}

$resolvedPort = Resolve-LoggingPort -RequestedPort $Port -WaitSeconds $PortWaitSeconds
$capturedText = Invoke-Capture -PortName $resolvedPort -Speed $BaudRate -Seconds $DurationSeconds
$cleanCapturedText = Remove-AnsiEscape -Text $capturedText

if (-not $LogPath) {
    $outputDirectory = [System.IO.Path]::Combine(
        [Environment]::GetFolderPath('MyDocuments'),
        'Cygnus-M2-logs'
    )
    $LogPath = Join-Path $outputDirectory ("pmw3610-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

$logDirectory = Split-Path -Parent $LogPath
if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
    [void](New-Item -ItemType Directory -Path $logDirectory -Force)
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($LogPath, $cleanCapturedText, $utf8NoBom)
$savedLogPath = (Resolve-Path -LiteralPath $LogPath).Path

$diagnosis = Get-Pmw3610Diagnosis -Text $cleanCapturedText
Show-Pmw3610Diagnosis -Diagnosis $diagnosis -Source $savedLogPath
exit $diagnosis.ExitCode
