local RESOURCE = GetCurrentResourceName()

local CONTROLE_PTT = 249        -- INPUT_PUSH_TO_TALK
local VELOCIDADE_ENVIO = 500000 -- bytes/s do evento latente com o áudio
local TIMEOUT_RESPOSTA = 25000  -- ms sem resposta do servidor até desistir do pedido

local gravando = false
local proximoId = 0
local pendentes = {} -- id -> true

local function debug(...)
    if Config.Debug then print(('[%s]'):format(RESOURCE), ...) end
end

local function iniciarGravacao()
    if gravando then return false end
    if IsPauseMenuActive() then return false end

    gravando = true
    SendNUIMessage({
        acao = 'iniciar',
        maxSegundos = Config.MaxSegundos,
        preRollMs = Config.PreRollMs,
        minFalaMs = Config.MinFalaMs,
        mostrarIndicador = Config.MostrarIndicador,
        debug = Config.Debug,
    })
    return true
end

local function pararGravacao()
    if not gravando then return end
    gravando = false
    SendNUIMessage({ acao = 'parar' })
end

-- NUI -> cliente: áudio pronto (WAV em base64), envia para o servidor transcrever
RegisterNUICallback('audio', function(data, cb)
    cb('ok')
    gravando = false
    if type(data.audio) ~= 'string' or data.audio == '' then return end

    proximoId = proximoId + 1
    local id = proximoId
    pendentes[id] = true
    debug(('enviando %d KB de áudio (%d ms)'):format(math.floor(#data.audio * 0.75 / 1024), data.duracao or 0))

    TriggerLatentServerEvent('vedev_transcricao:audio', VELOCIDADE_ENVIO, data.audio, data.mime, id)

    SetTimeout(TIMEOUT_RESPOSTA, function()
        if pendentes[id] then
            pendentes[id] = nil
            SendNUIMessage({ acao = 'falha', mensagem = 'Sem resposta do servidor' })
        end
    end)
end)

-- NUI -> cliente: mensagens de diagnóstico (só com Config.Debug)
RegisterNUICallback('log', function(data, cb)
    cb('ok')
    debug('[nui]', data.mensagem)
end)

-- NUI -> cliente: gravação curta demais ou cancelada
RegisterNUICallback('descartado', function(_, cb)
    cb('ok')
    gravando = false
end)

-- NUI -> cliente: erro ao acessar o microfone
RegisterNUICallback('erro', function(data, cb)
    cb('ok')
    gravando = false
    debug('erro na gravação:', data.motivo, data.detalhe)
end)

-- Servidor -> cliente: resultado da transcrição
RegisterNetEvent('vedev_transcricao:resultado', function(texto, erro, id)
    if id then
        if not pendentes[id] then return end -- já expirou
        pendentes[id] = nil
    end

    if erro then
        debug('falha na transcrição:', erro)
        -- no modo automático, "não entendi nada" é normal (tosse, barulho): não mostra na tela
        local silenciosa = Config.Modo == 'auto' and erro == 'Nenhuma fala reconhecida'
        SendNUIMessage({ acao = 'falha', mensagem = erro, silenciosa = silenciosa })
        return
    end

    debug('texto:', texto)
    SendNUIMessage({
        acao = 'resultado',
        texto = texto,
        mostrar = Config.MostrarTexto,
        tempo = Config.TempoTexto,
    })

    -- Outros scripts do cliente podem escutar:
    -- AddEventHandler('vedev_transcricao:texto', function(texto) ... end)
    TriggerEvent('vedev_transcricao:texto', texto)
end)

-- Verdadeiro enquanto o jogador local está transmitindo voz (pma-voice/Mumble),
-- seja no push-to-talk ou no microfone aberto (ativação por voz).
local function falandoNoJogo()
    local id = PlayerId()
    local mumble = MumbleIsPlayerTalking(id)
    return mumble == true or mumble == 1 or NetworkIsPlayerTalking(id) == true
end

-- Tem outro jogador (no alcance da voz) ou NPC perto o bastante para ouvir?
local function alguemPerto()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)

    local prox = LocalPlayer.state.proximity
    local alcance = (type(prox) == 'table' and tonumber(prox.distance)) or Config.DistanciaJogadores
    local eu = PlayerId()
    for _, id in ipairs(GetActivePlayers()) do
        if id ~= eu and #(GetEntityCoords(GetPlayerPed(id)) - pos) <= alcance then
            return true
        end
    end

    if Config.ContarNPCs then
        local distancia = Config.DistanciaNPCs
        for _, npc in ipairs(GetGamePool('CPed')) do
            if npc ~= ped and not IsPedAPlayer(npc) and IsPedHuman(npc) and not IsEntityDead(npc)
                and #(GetEntityCoords(npc) - pos) <= distancia then
                return true
            end
        end
    end
    return false
end

-- Índice do microfone escolhido nas configurações de voz do jogo
local function indiceMicrofoneJogo()
    return GetConvarInt('profile_voiceInputDevice', -1)
end

-- NUI -> cliente: microfone da voz do jogo identificado
RegisterNUICallback('microfone', function(data, cb)
    cb('ok')
    debug(('microfone da transcrição: %s (%s)'):format(data.label or '?', data.motivo or ''))
end)

-- Avisa a NUI quando o jogador fala no jogo (usado para descobrir o microfone da
-- voz e, no modo 'auto', para saber quando gravar).
CreateThread(function()
    -- abre o microfone já no início para ter o pre-roll pronto na primeira fala
    Wait(2000)
    local indice = indiceMicrofoneJogo()
    SendNUIMessage({ acao = 'preparar', preRollMs = Config.PreRollMs, debug = Config.Debug, indiceJogo = indice })

    local vozAnterior = false
    local ultimoFalando = 0
    local proximaChecagem = 0
    local temAlguem, proximaChecagemPerto = true, 0
    local avisouSozinho = false

    while true do
        local agora = GetGameTimer()
        local voz = falandoNoJogo()

        if voz ~= vozAnterior then
            vozAnterior = voz
            SendNUIMessage({ acao = 'vozJogo', falando = voz })
        end

        if agora >= proximaChecagem then
            proximaChecagem = agora + 2000
            local novo = indiceMicrofoneJogo()
            if novo ~= indice then
                indice = novo
                SendNUIMessage({ acao = 'indiceJogo', indice = novo })
            end
        end

        if Config.Modo == 'auto' then
            -- checagem de quem está por perto a cada 500 ms (não precisa ser a cada frame)
            if Config.SomenteComAlguemPerto and agora >= proximaChecagemPerto then
                proximaChecagemPerto = agora + 500
                temAlguem = alguemPerto()
            end

            if voz then
                ultimoFalando = agora
                if not gravando then
                    if not Config.SomenteComAlguemPerto or temAlguem then
                        avisouSozinho = false
                        if iniciarGravacao() then debug('fala detectada, gravando') end
                    elseif not avisouSozinho then
                        avisouSozinho = true
                        debug('fala ignorada: ninguém por perto para ouvir')
                    end
                end
            elseif gravando and agora - ultimoFalando > Config.SilencioMs then
                debug('silêncio, enviando frase')
                pararGravacao()
            end
        end

        Wait(50)
    end
end)

-- No modo 'auto' a gravação é controlada pela thread acima
if Config.Modo == 'ptt' then
    CreateThread(function()
        while true do
            local apertado = IsControlPressed(0, CONTROLE_PTT) or IsDisabledControlPressed(0, CONTROLE_PTT)
            if apertado and not gravando then
                iniciarGravacao()
            elseif not apertado and gravando then
                pararGravacao()
            end
            Wait(30)
        end
    end)
elseif Config.Modo == 'tecla' then
    RegisterCommand('+transcrever', iniciarGravacao, false)
    RegisterCommand('-transcrever', pararGravacao, false)
    RegisterKeyMapping('+transcrever', 'Transcrever fala (segurar)', 'keyboard', Config.Tecla)
end

-- Diagnóstico: /transcricao_status no F8 ou chat
RegisterCommand('transcricao_status', function()
    local qtd = 0
    for _ in pairs(pendentes) do qtd = qtd + 1 end
    print(('[%s] modo=%s gravando=%s pendentes=%d MumbleIsPlayerTalking=%s NetworkIsPlayerTalking=%s'):format(
        RESOURCE, Config.Modo, tostring(gravando), qtd,
        tostring(MumbleIsPlayerTalking(PlayerId())), tostring(NetworkIsPlayerTalking(PlayerId()))))
    print(('[%s] profile_voiceInputDevice=%d'):format(RESOURCE, indiceMicrofoneJogo()))
end, false)

exports('IniciarGravacao', iniciarGravacao)
exports('PararGravacao', pararGravacao)
exports('EstaGravando', function() return gravando end)
