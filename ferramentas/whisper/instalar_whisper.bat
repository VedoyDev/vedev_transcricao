<# : -- parte do cmd (o PowerShell enxerga isto como comentário) --
@echo off
setlocal
title Instalando Whisper - vedev_transcricao
set "VEDEV_PASTA=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8))) %*"
if errorlevel 1 (
    echo.
    echo A instalacao falhou. Veja a mensagem acima e tente de novo.
    pause
    exit /b 1
)
echo.
echo Instalacao concluida. Este instalador sera apagado.
pause
(goto) 2>nul & del "%~f0"
#>
# =============================================================================
# Instalador do Whisper local (whisper.cpp) pré-configurado para o vedev_transcricao.
#
# - Detecta placa NVIDIA: baixa a versão CUDA 12.4 e o modelo large-v3-turbo.
# - Sem NVIDIA (ou com -Cpu): baixa a versão para processador e o modelo small.
# - Cria o iniciar_whisper.bat e, no fim, este instalador se apaga.
#
# Opções: instalar_whisper.bat -Cpu
#         instalar_whisper.bat -Modelo small-q5_1
# =============================================================================
param(
    [switch]$Cpu,
    [string]$Modelo = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Escrever($texto, $cor = 'Gray') { Write-Host $texto -ForegroundColor $cor }

# Baixa com o curl.exe do Windows (rápido, com barra de progresso); sem ele, Invoke-WebRequest.
function Baixar($url, $destino) {
    $parcial = "$destino.parcial"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail --retry 3 --progress-bar -o $parcial $url
        if ($LASTEXITCODE -ne 0) { throw "Falha no download: $url" }
    } else {
        Escrever '  (sem curl.exe: baixando sem barra de progresso, pode demorar)' 'Yellow'
        Invoke-WebRequest $url -OutFile $parcial
    }
    Move-Item $parcial $destino -Force
}

# Extrai com o tar.exe do Windows (bem mais rápido em zips grandes); sem ele, Expand-Archive.
function Extrair($zip, $destino) {
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -xf $zip -C $destino
        if ($LASTEXITCODE -ne 0) { throw "Falha ao extrair $zip" }
    } else {
        Expand-Archive $zip -DestinationPath $destino -Force
    }
}

try {
    $pasta = $env:VEDEV_PASTA.TrimEnd('\')
    $bin = Join-Path $pasta 'bin'
    $modelos = Join-Path $pasta 'modelos'
    New-Item -ItemType Directory -Force -Path $bin, $modelos | Out-Null

    # --- GPU ou processador -------------------------------------------------------
    $temNvidia = $false
    if (-not $Cpu) {
        $placas = Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name
        $temNvidia = [bool]($placas | Where-Object { $_ -match 'NVIDIA' })
        Escrever ("Placas de video: " + ($placas -join ', '))
    }
    if ($temNvidia) {
        $padraoPacote = '^whisper-(bin-win-cuda-12[\d.]*-x64|cublas-12[\d.]*-bin-x64)\.zip$'
        if (-not $Modelo) { $Modelo = 'large-v3-turbo-q5_0' }
        $threads = 4
        Escrever 'Modo: placa NVIDIA (CUDA 12)' 'Green'
    } else {
        $padraoPacote = '^whisper-blas-bin-x64\.zip$'
        if (-not $Modelo) { $Modelo = 'small-q5_1' }
        $threads = [Math]::Max(2, [Environment]::ProcessorCount)
        Escrever 'Modo: so processador' 'Yellow'
    }

    # --- Programa (whisper.cpp) ----------------------------------------------------
    if (Test-Path (Join-Path $bin 'whisper-server.exe')) {
        Escrever 'Programa ja instalado em bin\'
    } else {
        Escrever 'Procurando a versao mais recente do whisper.cpp no GitHub...'
        $releases = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=15' -Headers @{ 'User-Agent' = 'vedev_transcricao' }
        $pacote = $null
        foreach ($r in $releases) {
            $pacote = $r.assets | Where-Object { $_.name -match $padraoPacote } | Select-Object -First 1
            if ($pacote) { Escrever "Versao $($r.tag_name): $($pacote.name) ($([math]::Round($pacote.size / 1MB)) MB)"; break }
        }
        if (-not $pacote) { throw 'Nao encontrei o pacote do whisper.cpp nas releases do GitHub.' }

        $zip = Join-Path $env:TEMP $pacote.name
        $tmp = Join-Path $env:TEMP ('whisper_' + [guid]::NewGuid().ToString('N'))
        Escrever "Baixando o programa ($([math]::Round($pacote.size / 1MB)) MB)..."
        Baixar $pacote.browser_download_url $zip
        Escrever 'Extraindo...'
        Extrair $zip $tmp
        $exe = Get-ChildItem $tmp -Recurse -Filter 'whisper-server.exe' | Select-Object -First 1
        if (-not $exe) { throw 'O pacote baixado nao tem o whisper-server.exe.' }
        Copy-Item (Join-Path $exe.DirectoryName '*') $bin -Recurse -Force
        Remove-Item $zip, $tmp -Recurse -Force
        Escrever 'Programa instalado em bin\' 'Green'
    }

    # --- Modelo -----------------------------------------------------------------------
    $arquivoModelo = Join-Path $modelos "ggml-$Modelo.bin"
    if (Test-Path $arquivoModelo) {
        Escrever "Modelo ggml-$Modelo.bin ja baixado."
    } else {
        $tamanhos = @{ 'large-v3-turbo-q5_0' = '~550 MB'; 'small-q5_1' = '~190 MB'; 'large-v3-turbo' = '~1,6 GB'; 'medium-q5_0' = '~540 MB' }
        $tamanho = $tamanhos[$Modelo]; if (-not $tamanho) { $tamanho = 'tamanho variável' }
        Escrever "Baixando o modelo ggml-$Modelo.bin ($tamanho)..."
        Baixar "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$Modelo.bin" $arquivoModelo
        Escrever 'Modelo baixado em modelos\' 'Green'
    }

    # --- Cria o iniciar_whisper.bat ------------------------------------------------------
    $iniciar = @"
@echo off
REM ===========================================================================
REM  Whisper local (whisper.cpp) pre-configurado para o vedev_transcricao
REM  Deixe esta janela aberta enquanto o servidor estiver rodando.
REM
REM  No config_servidor.js do script, provedor "Whisper local" com ativo: true:
REM     endpoint: 'http://127.0.0.1:8000/v1/audio/transcriptions'
REM
REM  Otimizacoes (medidas numa GTX 1650: ~3,9 s -> ~1,8 s por frase, mesmo texto):
REM    -ac 768  processa 15,4 s de audio em vez de 30 s (mantenha Config.MaxSegundos <= 14)
REM    -nf      nao repete a transcricao quando fica em duvida (evita picos de ~30 s)
REM    -bo 1    guarda so 1 candidato
REM  Outros modelos: https://huggingface.co/ggerganov/whisper.cpp/tree/main
REM ===========================================================================
title Whisper - vedev_transcricao
cd /d "%~dp0"

set MODELO=modelos\ggml-$Modelo.bin
set PORTA=8000
set THREADS=$threads

:loop
echo [%time%] Iniciando Whisper (%MODELO%) na porta %PORTA%...
"bin\whisper-server.exe" -m "%MODELO%" -l pt -t %THREADS% -ac 768 -nf -bo 1 --host 127.0.0.1 --port %PORTA% --inference-path /v1/audio/transcriptions
echo [%time%] O Whisper fechou. Reiniciando em 3 segundos... (feche a janela para parar)
timeout /t 3 /nobreak >nul
goto loop
"@
    [IO.File]::WriteAllText((Join-Path $pasta 'iniciar_whisper.bat'), ($iniciar -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)

    Escrever ''
    Escrever 'Pronto! Agora:' 'Green'
    Escrever '  1. Dois cliques em iniciar_whisper.bat (deixe a janela aberta).'
    Escrever "  2. No config_servidor.js do vedev_transcricao, deixe o 'Whisper local' com ativo: true."
    if ($temNvidia) { Escrever '  Obs.: na primeira transcricao a placa compila as rotinas (1-2 min), so uma vez.' 'Yellow' }
    exit 0
} catch {
    Escrever ("ERRO: " + $_.Exception.Message) 'Red'
    exit 1
}
