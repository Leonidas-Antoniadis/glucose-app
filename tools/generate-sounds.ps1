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
