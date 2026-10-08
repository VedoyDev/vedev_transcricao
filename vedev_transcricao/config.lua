-- Configuração do lado do cliente.
-- Este arquivo é enviado aos jogadores: NÃO coloque a chave da API aqui.
-- A chave e o motor de transcrição ficam em config_servidor.js.

Config = {}

-- Como a gravação é acionada:
--   'tecla' -> tecla própria (segurar para falar). O jogador pode trocar em
--              Configurações > Atalhos > FiveM > "Transcrever fala".
--   'ptt'   -> grava junto com o push-to-talk da voz (controle 249, tecla N).
--   'auto'  -> grava sozinho sempre que o jogador está transmitindo voz no jogo
--              (funciona com microfone aberto/ativação por voz e com push-to-talk).
--              Só o microfone do próprio jogador é gravado.
Config.Modo = 'auto'

-- [auto] Quanto tempo de silêncio (ms) encerra uma frase e manda transcrever.
-- Menor = resposta mais rápida, mas pode cortar frases com pausas.
Config.SilencioMs = 700

-- Áudio guardado de antes da detecção (ms), para não cortar o começo da fala.
Config.PreRollMs = 500

-- Economia: gravações com menos voz que isso (ms) são descartadas sem enviar
-- (tosse, "hm", clique, barulho). O silêncio do começo e do fim também é cortado.
Config.MinFalaMs = 350

-- [auto] Só transcreve quando tem alguém por perto para ouvir (economiza as APIs).
-- Quem está sozinho em casa, no carro na estrada ou no mato não gasta requisição.
Config.SomenteComAlguemPerto = true

-- Distância (metros) para contar outro JOGADOR como "por perto".
-- Se o pma-voice informar o alcance de voz atual (sussurro/normal/grito), usa ele.
Config.DistanciaJogadores = 15.0

-- Conta NPCs também (necessário para assaltar/vender droga para NPC).
Config.ContarNPCs = true
Config.DistanciaNPCs = 10.0

-- Tecla padrão do modo 'tecla' (só vale para quem ainda não alterou o atalho).
Config.Tecla = 'J'

-- Duração máxima de uma gravação, em segundos (para sozinho ao atingir).
-- O Whisper local está configurado para no máximo ~15 s de áudio (-ac 768 no
-- iniciar_whisper.bat). Somando o PreRollMs, 14 s fica dentro do limite.
Config.MaxSegundos = 14

-- Mostra o indicador "Gravando..." / "Transcrevendo..." na tela.
Config.MostrarIndicador = false

-- Mostra o texto reconhecido na tela e por quanto tempo (ms).
Config.MostrarTexto = false
Config.TempoTexto = 6000

-- Imprime o texto reconhecido e erros no F8.
Config.Debug = false
