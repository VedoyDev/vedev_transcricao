<# : -- parte do cmd (o PowerShell enxerga isto como comentário) --
@echo off
setlocal
title Instalando Vosk - vedev_transcricao
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
# Instalador do Vosk local pré-configurado para o vedev_transcricao.
#
# - Instala o pacote "vosk" do Python (pip).
# - Baixa o modelo de português: small (~50 MB) ou, com -Grande, o completo (~1,7 GB).
# - No modelo completo, desativa a pasta "rescore" (arquivo de 2,28 GB que o Vosk
#   no Windows não consegue ler).
# - Cria o servidor_vosk.py e o iniciar_vosk.bat e, no fim, este instalador se apaga.
#
# Opção: instalar_vosk.bat -Grande
# =============================================================================
param([switch]$Grande)

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
    $modelos = Join-Path $pasta 'modelos'
    New-Item -ItemType Directory -Force -Path $modelos | Out-Null

    # --- Python + pacote vosk ------------------------------------------------------
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw 'Python nao encontrado. Instale em https://www.python.org/downloads/ (marque "Add python.exe to PATH") e rode de novo.'
    }
    Escrever "Python: $(& python --version 2>&1)"
    Escrever 'Instalando o pacote vosk (pip)...'
    & python -m pip install --upgrade --quiet --disable-pip-version-check vosk
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao instalar o pacote vosk com o pip.' }

    # --- Modelo -----------------------------------------------------------------------
    if ($Grande) { $nome = 'vosk-model-pt-fb-v0.1.1-20220516_2113' } else { $nome = 'vosk-model-small-pt-0.3' }
    $destino = Join-Path $modelos $nome
    if (Test-Path $destino) {
        Escrever "Modelo $nome ja instalado."
    } else {
        $zip = Join-Path $env:TEMP "$nome.zip"
        if ($Grande) { $tamanho = '~1,7 GB' } else { $tamanho = '~32 MB' }
        Escrever "Baixando o modelo $nome ($tamanho)..."
        Baixar "https://alphacephei.com/vosk/models/$nome.zip" $zip
        Escrever 'Extraindo...'
        Extrair $zip $modelos
        Remove-Item $zip -Force
        Escrever "Modelo instalado em modelos\$nome" 'Green'
    }
    $rescore = Join-Path $destino 'rescore'
    if (Test-Path $rescore) {
        Rename-Item $rescore 'rescore_desativado'
        Escrever 'Pasta rescore desativada (o Vosk no Windows nao le o G.carpa de 2,28 GB).' 'Yellow'
    }

    # --- Cria o servidor_vosk.py --------------------------------------------------------
    $servidor = @'
"""
Servidor do Vosk para o vedev_transcricao.

Recebe o áudio no mesmo formato da API do Whisper/OpenAI
(POST /v1/audio/transcriptions, multipart com o campo "file" em WAV)
e responde {"text": "..."}. Assim o script do FiveM usa o Vosk como
mais um provedor, com tipo 'openai', sem nenhuma mudança.

Uso:  python servidor_vosk.py [porta] [pasta do modelo]
"""

import array
import io
import json
import os
import sys
import time
import wave
from email.parser import BytesParser
from email.policy import default as politica_email
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from vosk import KaldiRecognizer, Model, SetLogLevel

PASTA = os.path.dirname(os.path.abspath(__file__))
PORTA = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
MODELO = sys.argv[2] if len(sys.argv) > 2 else os.path.join(PASTA, 'modelos', 'vosk-model-small-pt-0.3')
CAMINHO = '/v1/audio/transcriptions'
MAX_BYTES = 5 * 1024 * 1024

# Volume: áudio baixo faz o Vosk devolver texto vazio. Amplifica até este pico
# (fração do máximo), com ganho de no máximo GANHO_MAX vezes.
PICO_ALVO = 0.7
GANHO_MAX = 12.0

# Guarda os últimos áudios recebidos (para diagnóstico); 0 = não guarda
GUARDAR_ULTIMOS = 10
PASTA_AUDIOS = os.path.join(PASTA, 'ultimos_audios')


def log(msg):
    print(time.strftime('[%H:%M:%S]'), msg, flush=True)


def ler_arquivo_multipart(tipo, corpo):
    """Devolve os bytes do campo "file" de um multipart/form-data."""
    mensagem = BytesParser(policy=politica_email).parsebytes(
        b'Content-Type: ' + tipo.encode() + b'\r\n\r\n' + corpo)
    for parte in mensagem.iter_parts():
        if parte.get_param('name', header='content-disposition') == 'file':
            return parte.get_payload(decode=True)
    return None


def guardar(wav_bytes):
    if GUARDAR_ULTIMOS <= 0:
        return
    os.makedirs(PASTA_AUDIOS, exist_ok=True)
    nome = os.path.join(PASTA_AUDIOS, time.strftime('%Y%m%d_%H%M%S') + f'_{int(time.time() * 1000) % 1000:03d}.wav')
    with open(nome, 'wb') as f:
        f.write(wav_bytes)
    arquivos = sorted(os.listdir(PASTA_AUDIOS))
    for velho in arquivos[:-GUARDAR_ULTIMOS]:
        try:
            os.remove(os.path.join(PASTA_AUDIOS, velho))
        except OSError:
            pass


def transcrever(wav_bytes):
    with wave.open(io.BytesIO(wav_bytes), 'rb') as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2:
            raise ValueError('o áudio precisa ser WAV mono de 16 bits')
        taxa = wav.getframerate()
        amostras = array.array('h', wav.readframes(wav.getnframes()))

    if sys.byteorder == 'big':
        amostras.byteswap()

    pico = max((abs(a) for a in amostras), default=0) / 32768
    rms = (sum(a * a for a in amostras) / max(1, len(amostras))) ** 0.5 / 32768
    ganho = 1.0
    if 0 < pico < PICO_ALVO:
        ganho = min(PICO_ALVO / pico, GANHO_MAX)
        amostras = array.array('h', (max(-32768, min(32767, int(a * ganho))) for a in amostras))
        if sys.byteorder == 'big':
            amostras.byteswap()

    rec = KaldiRecognizer(modelo, taxa)
    dados = amostras.tobytes()
    passo = 8000  # 4000 amostras de 16 bits
    for i in range(0, len(dados), passo):
        rec.AcceptWaveform(dados[i:i + passo])
    texto = json.loads(rec.FinalResult()).get('text', '')
    # o modelo completo marca palavras que não conhece como <UNK>
    texto = ' '.join(p for p in texto.split() if p.lower() != '<unk>')
    info = f'{len(amostras) / taxa:.1f} s, pico {pico:.2f}, rms {rms:.3f}, ganho {ganho:.1f}x'
    return texto, info


class Handler(BaseHTTPRequestHandler):
    def responder(self, status, objeto):
        corpo = json.dumps(objeto, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def do_GET(self):
        self.responder(200, {'status': 'ok', 'modelo': os.path.basename(MODELO)})

    def do_POST(self):
        if self.path.split('?')[0] != CAMINHO:
            return self.responder(404, {'error': 'caminho não encontrado'})

        tamanho = int(self.headers.get('Content-Length') or 0)
        if tamanho <= 0 or tamanho > MAX_BYTES:
            return self.responder(413, {'error': 'áudio vazio ou grande demais'})

        inicio = time.time()
        try:
            audio = ler_arquivo_multipart(self.headers.get('Content-Type', ''), self.rfile.read(tamanho))
            if not audio:
                return self.responder(400, {'error': 'campo "file" não encontrado'})
            guardar(audio)
            texto, info = transcrever(audio)
        except Exception as erro:
            log(f'erro: {erro}')
            return self.responder(400, {'error': str(erro)})

        log(f'{int((time.time() - inicio) * 1000)} ms [{info}]: {texto or "(vazio)"}')
        self.responder(200, {'text': texto})

    def log_message(self, *args):
        pass  # sem o log padrão de cada requisição


if __name__ == '__main__':
    SetLogLevel(-1)
    if not os.path.isdir(MODELO):
        sys.exit(f'Modelo não encontrado: {MODELO}')
    log(f'carregando o modelo {os.path.basename(MODELO)}...')
    modelo = Model(MODELO)
    servidor = ThreadingHTTPServer(('127.0.0.1', PORTA), Handler)
    log(f'Vosk pronto em http://127.0.0.1:{PORTA}{CAMINHO}')
    servidor.serve_forever()
'@
    [IO.File]::WriteAllText((Join-Path $pasta 'servidor_vosk.py'), ($servidor -replace "`r?`n", "`n"), (New-Object Text.UTF8Encoding $false))

    # --- Cria o iniciar_vosk.bat ---------------------------------------------------------
    $iniciar = @"
@echo off
REM ===========================================================================
REM  Vosk local (so processador) pre-configurado para o vedev_transcricao
REM  Deixe esta janela aberta enquanto o servidor estiver rodando.
REM
REM  No config_servidor.js do script, provedor "Vosk local" com ativo: true:
REM     endpoint: 'http://127.0.0.1:8001/v1/audio/transcriptions'
REM
REM  Os ultimos 10 audios ficam em ultimos_audios\ para diagnostico (vozes de
REM  jogadores). Para desligar: GUARDAR_ULTIMOS = 0 no servidor_vosk.py.
REM ===========================================================================
title Vosk - vedev_transcricao
cd /d "%~dp0"

set MODELO=modelos\$nome
set PORTA=8001

:loop
python servidor_vosk.py %PORTA% "%MODELO%"
echo [%time%] O Vosk fechou. Reiniciando em 3 segundos... (feche a janela para parar)
timeout /t 3 /nobreak >nul
goto loop
"@
    [IO.File]::WriteAllText((Join-Path $pasta 'iniciar_vosk.bat'), ($iniciar -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)

    Escrever ''
    Escrever 'Pronto! Agora:' 'Green'
    Escrever '  1. Dois cliques em iniciar_vosk.bat (deixe a janela aberta).'
    Escrever "  2. No config_servidor.js do vedev_transcricao, deixe o 'Vosk local' com ativo: true."
    exit 0
} catch {
    Escrever ("ERRO: " + $_.Exception.Message) 'Red'
    exit 1
}
