# Hook SessionEnd de Claude Code: guarda un resumen de la sesion en la carpeta
# historial\ del proyecto, dentro de la boveda de Obsidian.
param([string]$Entrada)

# ---- AJUSTA ESTO ----------------------------------------------------------
$Boveda      = "C:\Users\TU_USUARIO\OneDrive\Proyectos"  # carpeta de proyectos = boveda
$MinMensajes = 10       # sesiones mas cortas no se guardan (ahorra tokens)
$MaxCaracteres = 150000 # recorta conversaciones muy largas (se queda con el final)
$Modelo      = "haiku"  # modelo barato para resumir
# ---------------------------------------------------------------------------

# La sesion que hace el resumen tambien dispara este hook: evitar el bucle.
if ($env:GUARDAR_SESION -eq "1") { exit 0 }

# Fase 1 (llamada por el hook): guardar la entrada y relanzarse en segundo plano
# para no retrasar el cierre de Claude Code.
if (-not $Entrada) {
    $tmp = Join-Path $env:TEMP ("claude-sesion-" + [guid]::NewGuid() + ".json")
    [Console]::In.ReadToEnd() | Set-Content -Path $tmp -Encoding UTF8
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"", "-Entrada", "`"$tmp`"")
    exit 0
}

# Fase 2 (segundo plano)
$utf8 = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = $utf8
[Console]::OutputEncoding = $utf8

$datos = Get-Content $Entrada -Raw -Encoding UTF8 | ConvertFrom-Json
Remove-Item $Entrada -ErrorAction SilentlyContinue

# Solo sesiones abiertas dentro de la boveda
$cwd = $datos.cwd
if (-not $cwd -or -not $cwd.StartsWith($Boveda, [StringComparison]::OrdinalIgnoreCase)) { exit 0 }
if (-not (Test-Path $datos.transcript_path)) { exit 0 }

# Extraer solo el texto de los mensajes (sin resultados de herramientas)
$mensajes = @(foreach ($linea in Get-Content $datos.transcript_path -Encoding UTF8) {
    try { $e = $linea | ConvertFrom-Json } catch { continue }
    if ($e.type -ne "user" -and $e.type -ne "assistant") { continue }
    $c = $e.message.content
    if ($c -is [string]) { $texto = $c }
    else { $texto = ($c | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n" }
    if ($texto) { "[$($e.type)] $texto" }
})
if ($mensajes.Count -lt $MinMensajes) { exit 0 }

$conversacion = $mensajes -join "`n`n"
if ($conversacion.Length -gt $MaxCaracteres) {
    $conversacion = $conversacion.Substring($conversacion.Length - $MaxCaracteres)
}

$instrucciones = @'
Resume la conversacion de abajo en Markdown para guardarla como documentacion del proyecto.
Responde SOLO con el Markdown, en espanol, maximo 40 lineas, con este formato:

# [Proyecto] - [tema]
**Herramientas:** (Power BI / Power Automate / SharePoint / Excel / Python...)

## Objetivo
## Como quedo construido
(tablas, listas, flujos, medidas DAX, consultas, archivos y donde estan)
## Decisiones y por que
## Problemas resueltos
(error -> solucion)
## Pendientes

Incluye solo lo que siga siendo valido. No copies codigo completo, solo nombres y ubicacion.
Si la conversacion no tiene nada que valga la pena guardar, responde exactamente: NADA

--- CONVERSACION ---
'@

$env:GUARDAR_SESION = "1"
$resumen = (($instrucciones + "`n" + $conversacion) | claude -p --model $Modelo) -join "`n"
if (-not $resumen -or $resumen.Trim() -eq "NADA") { exit 0 }

$dir = Join-Path $cwd "historial"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$archivo = Join-Path $dir ((Get-Date -Format "yyyy-MM-dd-HHmm") + "-sesion.md")
[IO.File]::WriteAllText($archivo, $resumen, $utf8)
