# vedev_transcricao

Transcrição de voz para **FiveM**: transforma a fala dos jogadores (microfone da voz do jogo)
em texto e dispara ações a partir do que foi dito: moderação de xingamentos e discriminação
com prova em áudio no Discord, detecção de assalto, venda de drogas e o que mais você
configurar.

- 🎙️ Grava automaticamente quando o jogador fala no jogo (pma-voice), sem apertar nada.
- 🧠 Usa **Whisper** (local, Groq ou Cloudflare) com troca automática entre motores.
- 🗣️ Interpretador de frases com contexto: "eu como tua mãe" ≠ "como está tua mãe".
- 🛡️ Webhook no Discord com **nome, RG, ID, data/hora e o áudio da fala** como prova.
- 💸 Pensado para gastar pouco: corta silêncio, ignora tosse/barulho, só transcreve com
  alguém por perto.
- 👤 O jogador **não instala nada**.

> ⚠️ **Conteúdo sensível:** `server/config_falas.lua` contém listas de xingamentos e termos
> discriminatórios para fins de moderação.

---

## Sumário

- [Como funciona](#como-funciona)
- [Requisitos](#requisitos)
- [Instalação](#instalação)
- [Motores de transcrição](#motores-de-transcrição)
- [Configuração do jogador (`config.lua`)](#configuração-do-jogador-configlua)
- [Falas e ações (`server/config_falas.lua`)](#falas-e-ações-serverconfig_falaslua)
- [Webhook do Discord](#webhook-do-discord)
- [Economia de processamento](#economia-de-processamento)
- [Ferramentas: Whisper e Vosk locais](#ferramentas-whisper-e-vosk-locais)
- [Comandos e integração](#comandos-e-integração)
- [Problemas comuns](#problemas-comuns)
- [Privacidade (LGPD)](#privacidade-lgpd)
- [Links](#links)

---

## Como funciona

```
PC DO JOGADOR (dentro do FiveM, nada para instalar)
  pma-voice diz que o jogador está falando
    └─► a NUI grava o microfone da voz do jogo (com 0,5 s de áudio anterior)
        ├─ descarta tosse/barulho (menos de 0,35 s de voz)
        ├─ corta o silêncio do começo e do fim
        └─ converte para WAV 16 kHz mono ─► envia ao servidor (evento latente)

SERVIDOR FIVEM
  server/main.js
    └─► tenta os motores na ordem: Whisper local → Groq → Cloudflare
        (se um recusar/cair/demorar, o mesmo áudio vai para o próximo)
  server/falas.lua
    └─► compara o texto com server/config_falas.lua
        ├─ log no console (com nome do personagem e RG)
        ├─ webhook no Discord (+ áudio da fala, se anexarAudio = true)
        ├─ aviso na tela do jogador (ox_lib)
        ├─ função acao() da categoria
        └─ limite de ocorrências → aoAtingirLimite() (ex.: expulsar)
```

**Por que tudo é processado no servidor?** A NUI do FiveM não tem acesso ao reconhecimento de
voz do Google (Web Speech API) e vem com WebAssembly desativado, então não dá para
transcrever no PC do jogador. Detalhes em [MOTORES.md](MOTORES.md#o-que-não-funciona-no-fivem).

**Microfone certo:** o script descobre sozinho qual microfone é o da voz do jogo. Na primeira
fala, escuta todos os microfones por ~2 s e escolhe o que reagiu à voz. A escolha fica salva e
é refeita se o jogador trocar o microfone nas configurações de voz do jogo.

## Requisitos

| | Obrigatório? | Para quê |
|---|---|---|
| [pma-voice](https://github.com/AvarianKnight/pma-voice) (ou Mumble nativo) | sim, no modo `auto` | saber quando o jogador está falando |
| Pelo menos **um** motor de transcrição | sim | Groq/Cloudflare (chave grátis) ou Whisper local |
| [ox_lib](https://github.com/overextended/ox_lib) | opcional | aviso na tela do jogador |
| [Qbox](https://github.com/Qbox-project/qbx_core) | opcional | nome do personagem e RG (`citizenid`) no log/Discord |

Sem Qbox, o script usa o nome da conta FiveM. Funciona em qualquer framework.

## Instalação

O repositório tem duas partes:

```
vedev_transcricao/      ← o script (vai para resources/)
ferramentas/            ← opcionais, rodam FORA do FiveM
├── whisper/instalar_whisper.bat
└── vosk/instalar_vosk.bat
```

1. Copie **só** a pasta `vedev_transcricao` para `resources/` (ex.: `resources/[scripts]/`).
2. Configure ao menos um motor em **`config_servidor.js`** (passo a passo abaixo).
3. (Opcional) Coloque a URL do webhook em **`server/config_falas.lua`** → `Falas.Webhook`.
4. No `server.cfg`: `ensure vedev_transcricao`.
5. No console do servidor deve aparecer:
   ```
   [vedev_transcricao] pronto. APIs: Groq -> Cloudflare | idioma=pt
   [vedev_transcricao] falas carregadas: 4 categorias, ... frases/padrões
   ```
6. Teste sem falar: `transcricao_exemplos` no console do servidor.

> Depois de mudar o `fxmanifest.lua`, rode `refresh` antes do `ensure`. Comandos de servidor
> vão no **console do servidor/txAdmin**, não no F8 do jogo.

**Arquivos:**

| Arquivo (dentro de `vedev_transcricao/`) | Onde roda | Conteúdo |
|---|---|---|
| `config.lua` | cliente (baixado pelos jogadores) | modo, tecla, filtros. **Nunca coloque chaves aqui** |
| `config_servidor.js` | só servidor | motores, chaves, idioma, prompt |
| `server/config_falas.lua` | só servidor | frases, categorias, webhook |
| `server/main.js` | servidor | envio aos motores, troca automática, webhook com áudio |
| `server/falas.lua` | servidor | interpretador de frases e ações |
| `client/main.lua` | cliente | detecção de fala, filtros, comandos |
| `web/` | cliente (NUI) | gravação, calibração do microfone, corte de silêncio, WAV |

## Motores de transcrição

A lista `provedores` em `config_servidor.js` é tentada **na ordem**. Comparação completa
(grátis × pago, capacidade, particularidades, links) em **[MOTORES.md](MOTORES.md)**.

| O que aconteceu com o motor | O que o script faz |
|---|---|
| Limite atingido (HTTP 429) | deixa de lado pelo tempo que ele pedir (ou 60 s) |
| Cota diária da Cloudflare esgotada | deixa de lado até a meia-noite UTC |
| Chave/token errado (401/403) | deixa de lado por 10 min e avisa no console |
| Fora do ar, erro de rede ou demora (>20 s) | deixa de lado por 15–30 s |

O console mostra quem transcreveu cada frase (`[Whisper local | 1800 ms]`, `[Groq | 600 ms]`).
Use `ativo: false` para desligar um motor sem apagar a configuração.

### Groq: chave

1. Crie a conta em https://console.groq.com
2. **API Keys** → https://console.groq.com/keys → **Create API Key**
3. Copie (começa com `gsk_`, só aparece uma vez) e cole em `chave:` do bloco da Groq.

### Cloudflare: Account ID e token

1. Conta grátis: https://dash.cloudflare.com/sign-up
2. **Account ID** (32 caracteres): com o painel aberto, é o código na barra de endereço
   `https://dash.cloudflare.com/`**`<account_id>`**`/home`. Também aparece em
   **AI > Workers AI > Use REST API**.
   ⚠️ Não use o User ID, o Zone ID nem um exemplo de documentação (dá `401 Authentication error`).
3. **Token:** https://dash.cloudflare.com/profile/api-tokens → **Create Token** →
   **Use template** em **Workers AI** → **Continue to summary** → **Create Token**. Copie
   (só aparece uma vez). Opcional: em *Client IP Address Filtering* restrinja ao IP do servidor.
4. Preencha `contaId:` e `token:` no bloco da Cloudflare.

### Whisper / Vosk locais

Instalação com um clique em [Ferramentas](#ferramentas-whisper-e-vosk-locais). Depois de subir
o servidor local, ative o provedor correspondente (`ativo: true`).

### Idioma e português do Brasil

- `idioma: 'pt'` trava o Whisper em português (ele não tem código separado para pt-BR).
- `prompt` puxa para o português do Brasil e ajuda com gírias e nomes do servidor. Mantenha
  **curto e em forma de frase**; listas de palavras soltas podem ser "copiadas" pelo Whisper
  quando o áudio for só barulho.

## Configuração do jogador (`config.lua`)

| Opção | Padrão | Descrição |
|---|---|---|
| `Config.Modo` | `'auto'` | `auto` (grava quando o jogador fala no jogo), `tecla` (segurar `Config.Tecla`), `ptt` (junto com o push-to-talk) |
| `Config.SilencioMs` | `700` | silêncio que encerra uma frase |
| `Config.PreRollMs` | `500` | áudio guardado de antes da detecção (não corta o começo) |
| `Config.MinFalaMs` | `350` | menos voz que isso = descarta sem enviar |
| `Config.SomenteComAlguemPerto` | `true` | só transcreve com jogador/NPC por perto |
| `Config.DistanciaJogadores` | `15.0` | usado se o pma-voice não informar o alcance da voz |
| `Config.ContarNPCs` / `DistanciaNPCs` | `true` / `10.0` | NPC por perto também conta (assalto/venda para NPC) |
| `Config.MaxSegundos` | `14` | duração máxima de uma frase (o Whisper local otimizado aceita ~15 s) |
| `Config.MostrarIndicador` / `MostrarTexto` | `false` | "Gravando..." e legenda na tela |
| `Config.Debug` | `false` | logs no F8 |

## Falas e ações (`server/config_falas.lua`)

Roda só no servidor (os jogadores não veem a lista). Acentos, maiúsculas e pontuação são
ignorados, e a comparação é por palavra inteira (`mao` não casa com `mamao`).

### Como escrever frases

| Sintaxe | Significa | Exemplo |
|---|---|---|
| `'isso e um assalto'` | palavras nessa ordem, juntas | |
| `{ 'passa', 'celular' }` | todas as palavras, em qualquer ordem | "passa logo esse celular" |
| `{mae}` | qualquer palavra do grupo (`Falas.Grupos`) | mãe, mamãe, coroa… |
| `viva\|salve` | uma palavra ou outra | |
| `a?` | palavra opcional | |
| `*` / `*2` | até 3 (ou 2) palavras quaisquer no meio | |
| `excecoes` | frases normais que anulam um acerto contido nelas | |

Exemplo de contexto (ofensa à mãe):

| Frase | Resultado |
|---|---|
| "Sou tua mãe" / "Como está tua mãe?" / "Tua mãe tá puta contigo" (com raiva) | normal |
| "Eu como tua mãe" / "Tua mãe é uma puta" / "No cu da tua mãe" | xingamento |
| "Tô puta, filho da puta" | xingamento ("tô puta" ignorado, "filho da puta" conta) |

### Categorias padrão

| Categoria | Webhook | Áudio | Aviso | Limite |
|---|---|---|---|---|
| `assalto` | não | — | não | — |
| `drogas` | não | — | não | — |
| `xingamentos` | sim | sim | "Evite palavras ofensivas." | 5 → `aoAtingirLimite` (vazio por padrão) |
| `discriminacao` | sim | sim | "Discriminação é crime…" | **1 → expulsa** (`DropPlayer`) |

Cada categoria aceita `cooldown`, `log`, `enviarWebhook`, `anexarAudio`, `cor`, `aviso`,
`limite`, `aoAtingirLimite(src, total)` e `acao(src, texto, frase)`, onde você coloca o que
deve acontecer no jogo (ex.: NPC levanta as mãos, chamado para a polícia).

> ⚠️ `discriminacao` expulsa na primeira ocorrência. Palavras como "viado" são usadas como
> brincadeira entre amigos em muitos servidores; ajuste a lista e o `limite` à sua realidade.

## Webhook do Discord

`Falas.Webhook` recebe as categorias com `enviarWebhook = true`. A mensagem tem: categoria (com
cor), texto falado, jogador (personagem + conta), **RG** (`citizenid` no Qbox), ID, **data e
hora**, frase detectada e qual motor transcreveu.

Com `anexarAudio = true`, o **trecho de áudio da fala** (`.wav`, já sem silêncio, 1–3 s em
geral) vai anexado e pode ser ouvido no próprio Discord. O servidor guarda cada áudio só por
30 s, o tempo de enviar a prova.

## Economia de processamento

| Etapa | Onde | Efeito (medido) |
|---|---|---|
| Só grava quando o jogador fala no jogo | cliente | nada é enviado em silêncio |
| Só com alguém por perto (jogador/NPC) | cliente | sozinho em casa/carro não gasta nada |
| Descarta < 0,35 s de voz | cliente | tosse, "hm", cliques e barulho não são enviados |
| Corta silêncio do começo/fim | cliente | fala real: 4,3 s gravados → 1,2 s enviados (−72%) |
| Whisper local `-ac 768 -nf -bo 1` | ferramentas | GTX 1650 + turbo: ~3,9 s → ~1,8 s por frase |
| Junta repetições do Whisper | servidor | "Sou bicha / Sou bicha" → "Sou bicha" |
| Troca automática de motor | servidor | soma cotas grátis e evita parar quando um cai |

## Ferramentas: Whisper e Vosk locais

Motores que rodam **no seu servidor (ou em outro PC/VPS Windows), fora do FiveM**, sem API e
sem limite. Cada pasta vem com **um único arquivo**, já configurado para o script (porta,
idioma e otimizações batem com os padrões do `config_servidor.js`):

| Ferramenta | Instalador | Depois da instalação | Porta |
|---|---|---|---|
| Whisper (whisper.cpp) | `ferramentas/whisper/instalar_whisper.bat` | `iniciar_whisper.bat`, `bin/`, `modelos/` | 8000 |
| Vosk | `ferramentas/vosk/instalar_vosk.bat` | `iniciar_vosk.bat`, `servidor_vosk.py`, `modelos/` | 8001 |

**Como usar:**
1. Coloque a pasta da ferramenta em qualquer lugar do servidor (**não** em `resources`).
2. Dois cliques no `instalar_*.bat`. Ele baixa tudo, **cria o `iniciar_*.bat` e se apaga**.
3. Dois cliques no `iniciar_*.bat` e deixe a janela aberta (reinicia sozinho se fechar).
4. No `config_servidor.js`, deixe o provedor com `ativo: true`.

### Whisper (`instalar_whisper.bat`)

- Detecta placa **NVIDIA** e baixa o [whisper.cpp](https://github.com/ggml-org/whisper.cpp/releases)
  com CUDA 12.4 (~685 MB) + modelo `large-v3-turbo` (~550 MB); sem NVIDIA, baixa a versão para
  processador (~22 MB) + modelo `small` (~190 MB). Modelos do
  [HuggingFace](https://huggingface.co/ggerganov/whisper.cpp).
- Opções: `instalar_whisper.bat -Cpu` (força processador) e
  `instalar_whisper.bat -Modelo small-q5_1` (outro modelo).
- Otimizações no `iniciar_whisper.bat`: `-ac 768` (processa 15 s em vez de 30 s), `-nf` (não
  repete em caso de dúvida), `-bo 1`. Por causa do `-ac 768`, mantenha `Config.MaxSegundos` ≤ 14.
- Desempenho medido:

  | Máquina | Modelo | Tempo por frase curta |
  |---|---|---|
  | GTX 1650 4 GB (com o GTA aberto no mesmo PC) | `large-v3-turbo` | **~1,8 s** (era ~3,9 s sem as otimizações) |
  | GTX 1650 4 GB | `small` | ~0,9 s |
  | Xeon E5-2420 (2012, só processador) | `small` | ~33 s (processadores modernos são bem mais rápidos) |

- A primeira transcrição na GPU compila as rotinas do modelo (1–2 min); depois fica em cache.
- Em outra máquina: no `iniciar_whisper.bat` troque `--host 127.0.0.1` por `--host 0.0.0.0`,
  libere a porta 8000 no firewall **só para o IP do servidor FiveM** e use
  `http://IP:8000/v1/audio/transcriptions` no `config_servidor.js`.

### Vosk (`instalar_vosk.bat`)

- Precisa do [Python 3](https://www.python.org/downloads/) (marque *Add python.exe to PATH*).
- Instala o pacote `vosk` (pip) e baixa o modelo `vosk-model-small-pt-0.3` (~50 MB) da
  [página de modelos](https://alphacephei.com/vosk/models). Modelo completo (~1,7 GB, mais
  preciso): `instalar_vosk.bat -Grande`. No completo, o instalador desativa a pasta `rescore`
  (o Vosk no Windows não lê o `G.carpa` de 2,28 GB).
- O servidor amplifica áudio baixo, remove `<UNK>` e **guarda os últimos 10 áudios** em
  `ultimos_audios/` para diagnóstico (vozes de jogadores; `GUARDAR_ULTIMOS = 0` no
  `servidor_vosk.py` desliga).
- ⚠️ Com fala real o Vosk erra bem mais que o Whisper (veja [MOTORES.md](MOTORES.md#vosk)).
  Use como reserva.

## Comandos e integração

**Console do servidor:**

| Comando | O que faz |
|---|---|
| `transcricao_testar <id> <frase>` | mostra o que casou (ou qual exceção anulou) e dispara as ações de verdade (sem áudio) |
| `transcricao_exemplos` | confere ~36 frases de exemplo sem disparar nada |

**F8 do jogo:** `transcricao_status`, que mostra o modo, se está gravando, frases aguardando
resposta, se o jogo detecta a sua voz e o índice do microfone da voz do jogo. Com
`Config.Debug = true`, o F8 também mostra qual microfone a transcrição está usando.

**Eventos e exports:**

```lua
-- servidor: toda fala transcrita (evento local, cliente não consegue forjar)
AddEventHandler('vedev_transcricao:texto', function(src, texto, motor, audioId) end)

-- servidor: quando uma categoria de server/config_falas.lua é detectada
AddEventHandler('vedev_transcricao:fala', function(src, categoria, texto, frase) end)

-- cliente: texto da própria fala
AddEventHandler('vedev_transcricao:texto', function(texto) end)

-- cliente: controle manual da gravação
exports.vedev_transcricao:IniciarGravacao()
exports.vedev_transcricao:PararGravacao()
exports.vedev_transcricao:EstaGravando()
```

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| `nenhuma API configurada` | nenhuma chave/token preenchido (ou todos com `ativo: false`) |
| `Cloudflare indisponível (HTTP 401: Authentication error)` | Account ID errado ou token sem Workers AI |
| `Groq indisponível (HTTP 429 ...)` | limite da Groq; as frases vão para o próximo motor |
| Nenhuma linha `falas carregadas` | o script não foi reiniciado depois de mudar o `fxmanifest.lua` (`refresh` + `ensure`) |
| `Nenhuma fala reconhecida` toda hora | motor fraco (ex.: Vosk) ou microfone errado; veja `transcricao_status` |
| Whisper local responde 404 | iniciado pelo Git Bash (o `/v1/...` vira caminho); use o `.bat` |
| Comandos não fazem nada | foram digitados no F8 do jogo em vez do console do servidor |

## Privacidade (LGPD)

A voz dos jogadores é dado pessoal. Recomendações:
- deixe o canal do webhook **visível só para a staff**;
- avise nas **regras do servidor** que a voz é transcrita e que falas ofensivas são registradas
  com áudio como prova;
- prefira o Whisper local quando possível: o áudio não sai da sua máquina;
- o script não grava nada em disco no servidor FiveM (o áudio fica 30 s na memória para o
  webhook). O servidor Vosk das ferramentas guarda os últimos 10 áudios para diagnóstico
  (`GUARDAR_ULTIMOS = 0` desliga).

## Links

**Motores:** [Groq](https://console.groq.com) ·
[Cloudflare Workers AI](https://developers.cloudflare.com/workers-ai/) ·
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) ·
[modelos whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) ·
[Whisper (OpenAI)](https://github.com/openai/whisper) ·
[faster-whisper](https://github.com/SYSTRAN/faster-whisper) ·
[speaches](https://github.com/speaches-ai/speaches) ·
[Vosk](https://alphacephei.com/vosk/) ·
[vosk-api](https://github.com/alphacep/vosk-api) ·
[vosk-server](https://github.com/alphacep/vosk-server) ·
[OpenAI speech-to-text](https://platform.openai.com/docs/guides/speech-to-text)

**FiveM:** [pma-voice](https://github.com/AvarianKnight/pma-voice) ·
[ox_lib](https://github.com/overextended/ox_lib) ·
[Qbox](https://github.com/Qbox-project/qbx_core) ·
[Documentação FiveM](https://docs.fivem.net/docs/)

Comparação detalhada de motores, preços e capacidade: **[MOTORES.md](MOTORES.md)**.

## Licença

[GPL-3.0](LICENSE). Você pode usar, estudar, modificar e redistribuir; versões modificadas
que forem distribuídas também precisam ser GPL-3.0 com o código aberto.
