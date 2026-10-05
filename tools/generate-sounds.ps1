# Generates the bundled alert sounds (WAV, 16-bit mono, 22.05 kHz, under 30 s as iOS requires).
# Voice clips use Windows text-to-speech; tunes are synthesized tones.
# Usage (Windows PowerShell): powershell -ExecutionPolicy Bypass -File tools/generate-sounds.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$out = Join-Path $PSScriptRoot '..\App\GlucoseApp\Resources\Sounds'
New-Item -ItemType Directory -Force $out | Out-Null
$sampleRate = 22050

function Write-Wav([string]$path, [int16[]]$samples) {
    $stream = [System.IO.File]::Create($path)
    $writer = New-Object System.IO.BinaryWriter($stream)
    $dataBytes = $samples.Length * 2
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + $dataBytes))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
    $writer.Write([int16]1); $writer.Write([int16]1); $writer.Write([int]$sampleRate)
    $writer.Write([int]($sampleRate * 2)); $writer.Write([int16]2); $writer.Write([int16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]$dataBytes)
    foreach ($s in $samples) { $writer.Write($s) }
    $writer.Close()
}

# Each note: frequency in Hz (0 = silence) and duration in seconds.
function New-Tune([object[]]$notes, [int]$repeats, [double]$volume) {
    $list = New-Object System.Collections.Generic.List[int16]
    for ($r = 0; $r -lt $repeats; $r++) {
        foreach ($note in $notes) {
            $freq = [double]$note[0]; $count = [int]($note[1] * $sampleRate)
            for ($i = 0; $i -lt $count; $i++) {
                if ($freq -eq 0) { $list.Add(0); continue }
                $t = $i / $sampleRate
                # Short attack and release to avoid clicks.
                $env = [Math]::Min(1.0, [Math]::Min($i / 300.0, ($count - $i) / 600.0))
                $v = [Math]::Sin(2 * [Math]::PI * $freq * $t) * 0.8 + [Math]::Sin(4 * [Math]::PI * $freq * $t) * 0.2
                $list.Add([int16]($v * $env * $volume * 32000))
            }
        }
    }
    return $list.ToArray()
}

# Ultra loud: full-scale, square-like tones at 2.5-4 kHz, where phone speakers are loudest and
# the ear is most sensitive (the band smoke detectors use). Each note: frequency (or start and
# end frequency for a sweep) and duration in seconds.
function New-LoudTune([object[]]$notes, [double]$seconds) {
    $list = New-Object System.Collections.Generic.List[int16]
    $total = [int]($seconds * $sampleRate)
    $phase = 0.0
    while ($list.Count -lt $total) {
        foreach ($note in $notes) {
            $count = [int]($note[$note.Length - 1] * $sampleRate)
            $from = [double]$note[0]
            $to = if ($note.Length -eq 3) { [double]$note[1] } else { $from }
            for ($i = 0; $i -lt $count; $i++) {
                if ($from -eq 0) { $list.Add(0); $phase = 0.0; continue }
                $phase += 2 * [Math]::PI * ($from + ($to - $from) * $i / $count) / $sampleRate
                # Fundamental plus third harmonic is close to a square wave (louder than a sine for the
                # same peak) while staying below the 11 kHz limit of 22.05 kHz audio.
                $v = ([Math]::Sin($phase) + [Math]::Sin(3 * $phase) / 3) / 0.89
                $env = [Math]::Min(1.0, [Math]::Min($i / 60.0, ($count - $i) / 60.0))
                $list.Add([int16]([Math]::Max(-1.0, [Math]::Min(1.0, $v)) * $env * 32700))
            }
        }
    }
    return $list.GetRange(0, $total).ToArray()
}

# Ultra loud low: rapid piercing beeps that alternate pitch, like a smoke alarm. Hard to sleep through.
Write-Wav (Join-Path $out 'tune_alarm_loud_low.wav') (New-LoudTune @(
        @(3500, 0.07), @(0, 0.03), @(3500, 0.07), @(0, 0.03), @(3500, 0.07), @(0, 0.03), @(3500, 0.07), @(0, 0.08),
        @(4000, 0.07), @(0, 0.03), @(4000, 0.07), @(0, 0.03), @(4000, 0.07), @(0, 0.03), @(4000, 0.07), @(0, 0.18)) 29)
# Ultra loud high: fast high-pitched siren sweeping up and down.
Write-Wav (Join-Path $out 'tune_alarm_loud_high.wav') (New-LoudTune @(@(2500, 3600, 0.25), @(3600, 2500, 0.25), @(0, 0.05)) 29)

Write-Wav (Join-Path $out 'tune_chime.wav') (New-Tune @(@(880, 0.18), @(1175, 0.18), @(1568, 0.35), @(0, 0.6)) 2 0.7)
# Loud alarms sound different for lows and highs, so you know which it is without looking.
# Low: urgent, fast descending three-tone, repeated.
Write-Wav (Join-Path $out 'tune_alarm_low.wav') (New-Tune @(@(1319, 0.14), @(988, 0.14), @(659, 0.22), @(0, 0.25)) 9 0.95)
# High: slower rising two-tone, like a siren.
Write-Wav (Join-Path $out 'tune_alarm_high.wav') (New-Tune @(@(523, 0.35), @(784, 0.45), @(0, 0.4)) 6 0.9)
Write-Wav (Join-Path $out 'tune_pulse.wav') (New-Tune @(@(660, 0.12), @(0, 0.12)) 10 0.75)

$voices = [ordered]@{
    'glucose_low'       = 'Glucose low.'
    'glucose_very_low'  = 'Glucose very low.'
    'urgent_low'        = 'Urgent low glucose. Treat now.'
    'glucose_high'      = 'Glucose high.'
    'glucose_very_high' = 'Glucose very high.'
    'falling_fast'      = 'Glucose falling fast.'
    'rising_fast'       = 'Glucose rising fast.'
    'low_soon'          = 'Glucose will be low soon.'
    'no_data'           = 'No glucose data. Check your sensor.'
}
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synth.Rate = -1
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo($sampleRate, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
foreach ($name in $voices.Keys) {
    $path = Join-Path $out "voice_$name.wav"
    $synth.SetOutputToWaveFile($path, $format)
    # Say it twice with a pause, so it is hard to miss.
    $prompt = New-Object System.Speech.Synthesis.PromptBuilder
    $prompt.AppendText($voices[$name]); $prompt.AppendBreak([TimeSpan]::FromMilliseconds(700)); $prompt.AppendText($voices[$name])
    $synth.Speak($prompt)
    $synth.SetOutputToNull()
}
$synth.Dispose()
Get-ChildItem $out | Select-Object Name, @{n = 'KB'; e = { [math]::Round($_.Length / 1KB) } }
