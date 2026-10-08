# Motores de transcrição: comparação

Guia das opções testadas (ou avaliadas) para transformar a fala dos jogadores em texto no
`vedev_transcricao`: o que é grátis, o que é pago, capacidade, particularidades e links.

> Preços e limites mudam. Os números abaixo foram conferidos em **outubro de 2026** nas
> páginas oficiais (indicado quando vierem de terceiros). Sempre confira antes de decidir.
> Tempos marcados com 🧪 foram **medidos** neste projeto; o resto é estimativa.

## Resumo

| Motor | Onde roda | Custo | Qualidade pt-BR (fala real) | Limite | Formato no script |
|---|---|---|---|---|---|
| [Groq](#groq) | API | grátis com limite / pago barato | ótima | 20/min e 2.000/dia (grátis) | `tipo: 'openai'` |
| [Cloudflare Workers AI](#cloudflare-workers-ai) | API | grátis diário / pago por uso | ótima | 720/min | `tipo: 'cloudflare'` |
| [Whisper local (whisper.cpp)](#whisper-local-whispercpp) | seu servidor | grátis | ótima | o que a máquina aguentar | `tipo: 'openai'` |
| [faster-whisper / speaches](#faster-whisper--speaches) | seu servidor | grátis | ótima | o que a máquina aguentar | `tipo: 'openai'` |
| [OpenAI](#openai) | API | pago | ótima | alto | `tipo: 'openai'` |
| [Vosk](#vosk) | seu servidor | grátis | **fraca** 🧪 | o que a máquina aguentar | `tipo: 'openai'` (via ferramenta Vosk) |
| [Web Speech API](#o-que-não-funciona-no-fivem) | navegador do jogador | — | **não funciona no FiveM** 🧪 | — | — |
| [Qualquer coisa no PC do jogador](#o-que-não-funciona-no-fivem) | NUI | — | **não funciona no FiveM** 🧪 | — | — |

**Recomendação:** Whisper local (se houver GPU) → Groq → Cloudflare, nessa ordem. O script
troca sozinho quando um recusa ou cai.

---

## Groq

API rápida que roda o Whisper. Compatível com o formato da OpenAI.

- **Grátis** (`whisper-large-v3-turbo`): **20 requisições/min, 2.000/dia, 7.200 s de áudio/hora,
  28.800 s/dia**.
- **Pago (Developer):** US$ 0,04 por hora de áudio (turbo). Limites maiores, mas não
  publicados oficialmente (terceiros citam ~50/min e ~14.400 s/hora); veja em
  *Settings > Limits* no painel.
- ⚠️ **Cobrança mínima de 10 s por requisição**, mesmo uma frase de 1 s. Isso pesa no limite
  por hora e no custo.
- 🧪 Tempo: ~0,6–0,9 s por frase.
- Modelos: `whisper-large-v3-turbo` (rápido) e `whisper-large-v3` (um pouco mais preciso).

Capacidade aproximada no modo `auto` (jogador médio ≈ 3 frases/min): **~5–15 jogadores
falando** no grátis, ~8–16 no pago.

Links: [console](https://console.groq.com) · [chaves](https://console.groq.com/keys) ·
[speech-to-text](https://console.groq.com/docs/speech-to-text) ·
[limites](https://console.groq.com/docs/rate-limits)

## Cloudflare Workers AI

Roda o mesmo `whisper-large-v3-turbo` na rede da Cloudflare.

- **Grátis:** 10.000 *neurons* por dia ≈ **~214 min de áudio/dia** (o turbo gasta 46,63 neurons
  por minuto). Zera à meia-noite UTC.
- **Pago (Workers Paid, ~US$ 5/mês):** continua com os 10.000/dia grátis e cobra
  US$ 0,011 por 1.000 neurons ≈ **US$ 0,0005/min (~US$ 0,03/hora de áudio)**, sem teto.
- **Limite: 720 requisições/min** para reconhecimento de fala (praticamente não trava).
- Não encontramos cobrança mínima por requisição na documentação.
- 🧪 Tempo: ~1–2,5 s por frase.
- Precisa de **Account ID** (32 caracteres, aparece na barra de endereço do painel) e
  **API Token** (modelo "Workers AI"). Com o ID errado responde `401 Authentication error`.

Capacidade: ~240 jogadores falando ao mesmo tempo pelo limite de 720/min; o que conta é o custo.

Links: [Workers AI](https://developers.cloudflare.com/workers-ai/) ·
[modelo whisper-large-v3-turbo](https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/) ·
[preços](https://developers.cloudflare.com/workers-ai/platform/pricing/) ·
[limites](https://developers.cloudflare.com/workers-ai/platform/limits/) ·
[criar conta](https://dash.cloudflare.com/sign-up) ·
[tokens](https://dash.cloudflare.com/profile/api-tokens)

## Whisper local (whisper.cpp)

O Whisper rodando no seu servidor, em C/C++. Um `.exe` pronto no Windows, sem Python.
Instalação com um clique: [`ferramentas/whisper/instalar_whisper.bat`](README.md#whisper-instalar_whisperbat).

- **Grátis e sem limite**; o áudio não sai da sua máquina.
- **Com GPU NVIDIA** (pacote CUDA 12.4), medidos 🧪 numa **GTX 1650 4 GB**, com o GTA aberto
  no mesmo PC:

  | Modelo | Padrão | Com as otimizações do `.bat` |
  |---|---|---|
  | `small` (190 MB) | ~0,9 s | — |
  | `large-v3-turbo` (550 MB) | ~3,9 s (picos de ~28 s) | **~1,8 s** |

  Capacidade: ~20 jogadores falando (small) / ~10 (turbo otimizado) por GPU desse porte.
- **Só processador:** 🧪 ~44 s por frase com o `small` num Xeon E5-2420 (2012, sem AVX2).
  Em processadores modernos fica bem melhor (estimativa: small ~1–3 s, turbo ~4–8 s).
- `large-v3` completo: um pouco mais preciso que o turbo, bem mais lento (estimativa
  10–15 s/frase numa GPU de 4 GB) e pode faltar memória com o jogo aberto.
- Otimizações importantes: `-ac 768` (janela de 15 s), `-nf` (sem repetição), `-bo 1`.

Links: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) ·
[releases](https://github.com/ggml-org/whisper.cpp/releases) ·
[modelos](https://huggingface.co/ggerganov/whisper.cpp) ·
[Whisper original](https://github.com/openai/whisper)

## faster-whisper / speaches

Whisper otimizado em Python (CTranslate2). O **speaches** já sobe um servidor compatível com a
API da OpenAI, então funciona no script com `tipo: 'openai'`.

- Mesma qualidade do Whisper; costuma ser **mais rápido no processador** que o whisper.cpp e
  muito bom em GPUs com tensor cores.
- Mais trabalhoso no Windows (Python + CUDA + cuDNN). Ideal em **VPS Linux com Docker**.
- Boa opção para um servidor dedicado com GPU atendendo muitos jogadores.

Links: [faster-whisper](https://github.com/SYSTRAN/faster-whisper) ·
[speaches](https://github.com/speaches-ai/speaches)

## OpenAI

- Pago por minuto (`gpt-4o-mini-transcribe`, `gpt-4o-transcribe`, `whisper-1`), sem plano grátis
  para a API. Funciona direto com `tipo: 'openai'`.
- Endpoint: `https://api.openai.com/v1/audio/transcriptions`.

Links: [guia speech-to-text](https://platform.openai.com/docs/guides/speech-to-text) ·
[preços](https://openai.com/api/pricing/)

## Vosk

Reconhecimento leve (Kaldi), só processador. Instalação em
[`ferramentas/vosk/instalar_vosk.bat`](README.md#vosk-instalar_voskbat).

🧪 **O que encontramos com fala real** (mesmos áudios, microfone de jogador):

| Fala real | Whisper | Vosk completo (pt-fb) | Vosk small |
|---|---|---|---|
| "É isso aí." | ✅ | `<UNK>` | vazio |
| "Teste, teste." | ✅ | "este crescer" | vazio |
| Voz sintética: "Central, preciso de uma ambulância…" | ✅ | ✅ | ✅ |

- Vai bem com voz limpa/sintética e frases claras; **erra muito** com fala natural, frases
  curtas e gíria. Não recomendado para moderação (pode errar ou inventar palavras).
- Rápido: 🧪 ~0,5 s (completo) e ~2 s (small) por frase num processador antigo; ~350 MB de RAM.
- Modelo completo no Windows: desative `rescore/` (arquivo de 2,28 GB que o Vosk não lê).
- Sem pontuação/maiúsculas.

Links: [site](https://alphacephei.com/vosk/) · [modelos](https://alphacephei.com/vosk/models) ·
[vosk-api](https://github.com/alphacep/vosk-api) · [vosk-server](https://github.com/alphacep/vosk-server)

## O que não funciona no FiveM

Testado 🧪 dentro do jogo:

- **Web Speech API (`webkitSpeechRecognition`)** — no Chrome ela manda o áudio para o Google
  usando chaves que só o Chrome oficial tem. A NUI do FiveM (CEF) não tem: a API existe mas
  não ouve nem devolve nada.
- **Reconhecimento no PC do jogador (Vosk/Whisper em WebAssembly)** — a NUI do FiveM vem com
  **WebAssembly desativado** (`no native wasm support detected`), então bibliotecas como o
  [vosk-browser](https://ccoreilly.github.io/vosk-browser/) ou Whisper em navegador nem iniciam.

Consequência: **toda transcrição precisa acontecer no servidor ou numa API**. O jogador não
instala nada; a NUI só grava o microfone e envia o áudio.

## Outras APIs (créditos de teste ou pouco grátis)

| Serviço | Grátis | Observação | Link |
|---|---|---|---|
| Deepgram | ~US$ 200 de crédito (terceiros) | não renova; API simples, tem pt | [deepgram.com](https://deepgram.com) |
| Speechmatics | US$ 100 de crédito (oficial) | pausa quando acaba | [preços](https://www.speechmatics.com/pricing) |
| Gladia | 50 € de crédito único (oficial) | ~80 h | [preços](https://www.gladia.io/pricing) |
| AssemblyAI | ~US$ 50 de crédito (terceiros) | não renova | [assemblyai.com](https://www.assemblyai.com) |
| Azure AI Speech | ~5 h/mês | renova, mas é pouco | [Azure Speech](https://azure.microsoft.com/products/ai-services/ai-speech) |
| Google Cloud Speech-to-Text | ~60 min/mês | renova, muito pouco | [Google STT](https://cloud.google.com/speech-to-text) |
| Mistral Voxtral | pago (a partir de ~US$ 0,001/min) | lançado em 2026 | [Voxtral](https://mistral.ai/news/voxtral-transcribe-2) |

Nenhuma delas está implementada no script (exigem adaptação do formato), exceto as que
aceitam o formato da OpenAI.

## Quanto aguenta: estimativas por tamanho de servidor

Premissas: jogador médio no modo `auto` ≈ 3 frases/min de ~3,5 s; com o filtro "alguém por
perto" e o corte de silêncio o volume real cai bastante.

| Servidor | Setup sugerido | Custo aproximado/mês |
|---|---|---|
| até ~10 falando | Whisper local (GPU) → Groq → Cloudflare, tudo grátis | grátis |
| 10–30 | + Cloudflare pago como reserva | ~US$ 5–20 |
| ~100 | Cloudflare pago como principal (Groq grátis na frente) | ~US$ 50–80 (5 h/dia) |
| ~200 | Cloudflare pago, ou servidor dedicado com GPU + Cloudflare de reserva | ~US$ 150–250 (8 h/dia) · ~US$ 450–750 (24 h) na Cloudflare; GPU dedicada ~US$ 200–400 fixos |

Não coloque o Whisper na mesma máquina do servidor FiveM se ela já estiver no limite: ele usa
CPU/GPU a cada frase e piora as travadas (`server thread hitch warning`).
