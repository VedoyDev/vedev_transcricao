-- Compara o texto transcrito com as frases/padrões de server/config_falas.lua e executa as ações.

local RESOURCE = GetCurrentResourceName()

-- ---------------------------------------------------------------------------
-- Normalização
-- ---------------------------------------------------------------------------

-- Letras acentuadas (UTF-8, 2 bytes começando em 0xC3) -> letra sem acento
local SEM_ACENTO = {
    ['à'] = 'a', ['á'] = 'a', ['â'] = 'a', ['ã'] = 'a', ['ä'] = 'a',
    ['À'] = 'a', ['Á'] = 'a', ['Â'] = 'a', ['Ã'] = 'a', ['Ä'] = 'a',
    ['è'] = 'e', ['é'] = 'e', ['ê'] = 'e', ['ë'] = 'e',
    ['È'] = 'e', ['É'] = 'e', ['Ê'] = 'e', ['Ë'] = 'e',
    ['ì'] = 'i', ['í'] = 'i', ['î'] = 'i', ['ï'] = 'i',
    ['Ì'] = 'i', ['Í'] = 'i', ['Î'] = 'i', ['Ï'] = 'i',
    ['ò'] = 'o', ['ó'] = 'o', ['ô'] = 'o', ['õ'] = 'o', ['ö'] = 'o',
    ['Ò'] = 'o', ['Ó'] = 'o', ['Ô'] = 'o', ['Õ'] = 'o', ['Ö'] = 'o',
    ['ù'] = 'u', ['ú'] = 'u', ['û'] = 'u', ['ü'] = 'u',
    ['Ù'] = 'u', ['Ú'] = 'u', ['Û'] = 'u', ['Ü'] = 'u',
    ['ç'] = 'c', ['Ç'] = 'c', ['ñ'] = 'n', ['Ñ'] = 'n',
}

-- "Isso é um ASSALTO!" -> { 'isso', 'e', 'um', 'assalto' }
local function palavras(texto)
    texto = texto:gsub('\195[\128-\191]', SEM_ACENTO):lower()
    texto = texto:gsub('[^%w]', ' ')
    local lista = {}
    for p in texto:gmatch('%S+') do
        lista[#lista + 1] = p
    end
    return lista
end

-- ---------------------------------------------------------------------------
-- Compilação das frases e padrões
--   token = { conjunto = { palavra = true, ... }, opcional = bool }
--         | { lacuna = N }   (até N palavras quaisquer)
-- ---------------------------------------------------------------------------

local function ehPadrao(frase)
    return frase:find('[{|*?]') ~= nil
end

local function compilarPadrao(frase, origem)
    local tokens = {}
    for pedaco in frase:gmatch('%S+') do
        local parte = pedaco
        local lacuna = parte:match('^%*(%d*)$')
        if lacuna then
            tokens[#tokens + 1] = { lacuna = tonumber(lacuna) or Falas.LacunaPadrao or 3 }
        else
            local opcional = false
            if parte:sub(-1) == '?' then
                opcional = true
                parte = parte:sub(1, -2)
            end

            local conjunto, vazio = {}, true
            for alternativa in parte:gmatch('[^|]+') do
                local nomeGrupo = alternativa:match('^{(.+)}$')
                local fontes = { alternativa }
                if nomeGrupo then
                    fontes = Falas.Grupos and Falas.Grupos[nomeGrupo]
                    if not fontes then
                        print(('[%s] ^3grupo {%s} não existe (em %s: "%s")^7'):format(RESOURCE, nomeGrupo, origem, frase))
                        fontes = {}
                    end
                end
                for _, f in ipairs(fontes) do
                    for _, p in ipairs(palavras(f)) do
                        conjunto[p] = true
                        vazio = false
                    end
                end
            end

            if not vazio then
                tokens[#tokens + 1] = { conjunto = conjunto, opcional = opcional }
            end
        end
    end
    return tokens
end

local function compilarFrase(frase, origem)
    if type(frase) == 'table' then
        local lista = {}
        for _, p in ipairs(frase) do
            for _, pp in ipairs(palavras(p)) do lista[#lista + 1] = pp end
        end
        if #lista == 0 then return nil end
        return { tipo = 'todas', palavras = lista, original = table.concat(frase, ' + ') }
    end

    if type(frase) ~= 'string' then return nil end

    local tokens
    if ehPadrao(frase) then
        tokens = compilarPadrao(frase, origem)
    else
        tokens = {}
        for _, p in ipairs(palavras(frase)) do
            tokens[#tokens + 1] = { conjunto = { [p] = true } }
        end
    end
    if #tokens == 0 then return nil end
    return { tipo = 'padrao', tokens = tokens, original = frase }
end

-- ---------------------------------------------------------------------------
-- Busca
-- ---------------------------------------------------------------------------

-- Tenta casar tokens[ti..] a partir da palavra pi. Retorna o índice da última
-- palavra consumida (ou pi - 1 se nada foi consumido) ou nil.
local function casarEm(tokens, ti, lista, pi)
    if ti > #tokens then return pi - 1 end
    local tk = tokens[ti]

    if tk.lacuna then
        for k = 0, tk.lacuna do
            if pi + k > #lista + 1 then break end
            local fim = casarEm(tokens, ti + 1, lista, pi + k)
            if fim then return fim end
        end
        return nil
    end

    local w = lista[pi]
    if w and tk.conjunto[w] then
        local fim = casarEm(tokens, ti + 1, lista, pi + 1)
        if fim then return fim end
    end
    if tk.opcional then
        return casarEm(tokens, ti + 1, lista, pi)
    end
    return nil
end

-- Todos os trechos { inicio, fim } do texto onde a regra casa
local function trechos(regra, lista)
    local res = {}
    if regra.tipo == 'todas' then
        local ini, fim = math.huge, 0
        for _, p in ipairs(regra.palavras) do
            local achou
            for i, w in ipairs(lista) do
                if w == p then achou = i break end
            end
            if not achou then return res end
            ini = math.min(ini, achou)
            fim = math.max(fim, achou)
        end
        res[1] = { ini, fim }
        return res
    end

    for i = 1, #lista do
        local fim = casarEm(regra.tokens, 1, lista, i)
        if fim and fim >= i then
            res[#res + 1] = { i, fim }
        end
    end
    return res
end

local function dentroDeAlgum(trecho, excecoes)
    for _, e in ipairs(excecoes) do
        if e[1] <= trecho[1] and trecho[2] <= e[2] then return true end
    end
    return false
end

-- Pré-processa o config
local categorias = {}
for id, cat in pairs(Falas.Categorias) do
    if cat.ativo ~= false then
        local regras, excecoes = {}, {}
        for _, frase in ipairs(cat.frases or {}) do
            local r = compilarFrase(frase, id)
            if r then regras[#regras + 1] = r end
        end
        for _, frase in ipairs(cat.excecoes or {}) do
            local r = compilarFrase(frase, id .. '.excecoes')
            if r then excecoes[#excecoes + 1] = r end
        end
        categorias[#categorias + 1] = { id = id, cfg = cat, regras = regras, excecoes = excecoes }
    end
end
table.sort(categorias, function(a, b) return a.id < b.id end)

-- Analisa um texto. Retorna lista de { categoria, frase, ignorada = { frase, excecao }? }
local function analisar(texto)
    local lista = palavras(texto)
    local resultado = {}

    for _, categoria in ipairs(categorias) do
        local trechosExcecao, nomesExcecao = {}, {}
        for _, exc in ipairs(categoria.excecoes) do
            for _, t in ipairs(trechos(exc, lista)) do
                trechosExcecao[#trechosExcecao + 1] = t
                nomesExcecao[#nomesExcecao + 1] = exc.original
            end
        end

        -- Entre as regras que casaram, fica a mais específica (o trecho mais longo)
        local casou, tamanho, ignorada = nil, 0, nil
        for _, regra in ipairs(categoria.regras) do
            for _, t in ipairs(trechos(regra, lista)) do
                if dentroDeAlgum(t, trechosExcecao) then
                    if not ignorada then
                        for i, e in ipairs(trechosExcecao) do
                            if e[1] <= t[1] and t[2] <= e[2] then
                                ignorada = { frase = regra.original, excecao = nomesExcecao[i] }
                                break
                            end
                        end
                    end
                elseif t[2] - t[1] + 1 > tamanho then
                    casou = regra.original
                    tamanho = t[2] - t[1] + 1
                end
            end
        end

        if casou or ignorada then
            resultado[#resultado + 1] = { categoria = categoria, frase = casou, ignorada = not casou and ignorada or nil }
        end
    end
    return resultado, lista
end

-- ---------------------------------------------------------------------------
-- Ações
-- ---------------------------------------------------------------------------

local ultimoDisparo = {} -- [src][categoria] = GetGameTimer()
local contagem = {}      -- [src][categoria] = total

-- Nome do personagem e RG (citizenid do Qbox)
local function dadosJogador(src)
    local conta = GetPlayerName(src) or ('id ' .. src)
    local ok, jogador = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    local dados = ok and jogador and jogador.PlayerData
    local info = dados and dados.charinfo

    local nome = conta
    if info and info.firstname then
        nome = ('%s %s (%s)'):format(info.firstname, info.lastname or '', conta)
    end
    return nome, (dados and dados.citizenid) or 'sem personagem'
end

local function enviarWebhook(url, cat, src, texto, frase, provedor, audioId)
    local nome, rg = dadosJogador(src)
    local dataHora = os.date(Falas.FormatoDataHora or '%d/%m/%Y %H:%M:%S')
    local corpo = json.encode({
        username = 'Transcrição de voz',
        embeds = { {
            title = cat.nome or 'Fala detectada',
            color = cat.cor or 3447003,
            description = ('**"%s"**'):format(texto),
            fields = {
                { name = 'Jogador', value = nome, inline = true },
                { name = 'RG', value = tostring(rg), inline = true },
                { name = 'ID', value = tostring(src), inline = true },
                { name = 'Data e hora', value = dataHora, inline = true },
                { name = 'Frase detectada', value = frase, inline = true },
                { name = 'Transcrito por', value = provedor or '?', inline = true },
            },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        } },
    })

    -- Com áudio: o lado JavaScript manda o webhook com o trecho da fala anexado
    if cat.anexarAudio and audioId then
        local ok, enviado = pcall(function()
            return exports[RESOURCE]:EnviarWebhookComAudio(url, corpo, audioId)
        end)
        if ok and enviado then return end
        -- áudio indisponível (expirou ou teste do console): manda só o texto
    end

    PerformHttpRequest(url, function(status)
        if status < 200 or status >= 300 then
            print(('[%s] ^3webhook recusou a mensagem (HTTP %s). Confira a URL em server/config_falas.lua^7'):format(RESOURCE, status))
        end
    end, 'POST', corpo, { ['Content-Type'] = 'application/json' })
end

local function chamar(nomeFuncao, categoria, fn, ...)
    if type(fn) ~= 'function' then return end
    local ok, erro = pcall(fn, ...)
    if not ok then
        print(('[%s] ^1erro em %s.%s: %s^7'):format(RESOURCE, categoria, nomeFuncao, erro))
    end
end

local function disparar(src, categoria, texto, frase, provedor, audioId)
    local cat = categoria.cfg
    local id = categoria.id
    local agora = GetGameTimer()

    ultimoDisparo[src] = ultimoDisparo[src] or {}
    if agora - (ultimoDisparo[src][id] or -math.huge) < (cat.cooldown or 0) * 1000 then return end
    ultimoDisparo[src][id] = agora

    if cat.log ~= false then
        local nome, rg = dadosJogador(src)
        print(('[%s] [%s] %s RG %s [%d]: "%s" (frase: %s | transcrito por: %s)'):format(
            RESOURCE, id, nome, rg, src, texto, frase, provedor or '?'))
    end

    if cat.enviarWebhook == true and type(Falas.Webhook) == 'string' and Falas.Webhook ~= '' then
        enviarWebhook(Falas.Webhook, cat, src, texto, frase, provedor, audioId)
    end

    if cat.aviso then
        TriggerClientEvent('ox_lib:notify', src, {
            title = cat.nome,
            description = cat.aviso,
            type = 'error',
        })
    end

    TriggerEvent('vedev_transcricao:fala', src, id, texto, frase)
    chamar('acao', id, cat.acao, src, texto, frase)

    if cat.limite then
        contagem[src] = contagem[src] or {}
        local total = (contagem[src][id] or 0) + 1
        contagem[src][id] = total
        if total >= cat.limite then
            contagem[src][id] = 0
            chamar('aoAtingirLimite', id, cat.aoAtingirLimite, src, total)
        end
    end
end

-- Disparado pelo server/main.js a cada transcrição
AddEventHandler('vedev_transcricao:texto', function(src, texto, provedor, audioId)
    src = tonumber(src)
    if not src or type(texto) ~= 'string' or texto == '' then return end

    for _, r in ipairs(analisar(texto)) do
        if r.frase then
            disparar(src, r.categoria, texto, r.frase, provedor, audioId)
        end
    end
end)

AddEventHandler('playerDropped', function()
    ultimoDisparo[source] = nil
    contagem[source] = nil
end)

-- ---------------------------------------------------------------------------
-- Testes pelo console do servidor
-- ---------------------------------------------------------------------------

local function descrever(texto)
    local resultado, lista = analisar(texto)
    local partes = {}
    for _, r in ipairs(resultado) do
        if r.frase then
            partes[#partes + 1] = ('%s ("%s")'):format(r.categoria.id, r.frase)
        else
            partes[#partes + 1] = ('ignorado em %s ("%s" anulado pela exceção "%s")'):format(
                r.categoria.id, r.ignorada.frase, r.ignorada.excecao)
        end
    end
    return resultado, lista, #partes > 0 and table.concat(partes, ' | ') or 'nada'
end

-- transcricao_testar <id> <frase>: mostra a análise e dispara as ações de verdade
RegisterCommand('transcricao_testar', function(source, args)
    if source ~= 0 then return end -- só console
    local src = tonumber(table.remove(args, 1))
    local texto = table.concat(args, ' ')
    if not src or texto == '' then
        print('uso: transcricao_testar <id do jogador> <frase>')
        return
    end
    local _, lista, resumo = descrever(texto)
    print(('[%s] "%s" -> [%s] -> %s'):format(RESOURCE, texto, table.concat(lista, ' '), resumo))
    TriggerEvent('vedev_transcricao:texto', src, texto, 'teste do console')
end, true)

-- transcricao_exemplos: confere frases de exemplo (não dispara nada)
local EXEMPLOS = {
    -- { frase, categoria esperada (nil = nenhuma) }
    { 'Oi, sou tua mãe', nil },
    { 'Como está tua mãe?', nil },
    { 'Como vai a sua mãe, tudo bem?', nil },
    { 'Como tua mãe tá?', nil },
    { 'Cadê tua mãe?', nil },
    { 'Tua mãe tá puta contigo', nil },
    { 'Fiquei muito puta com isso', nil },
    { 'Peguei tua mãe no aeroporto', nil },
    { 'Sua mãe mora na zona sul', nil },
    { 'Comprei um carro preto', nil },
    { 'Sou ariano, kkkk', nil },
    { 'A luta contra o racismo', nil },
    { 'O nazismo foi horrível', nil },
    { 'Vou caçar macaco na mata', nil },
    { 'Eu como tua mãe', 'xingamentos' },
    { 'Comi a sua mãe ontem', 'xingamentos' },
    { 'Como tua mãe gostoso', 'xingamentos' },
    { 'Tua mãe é uma puta', 'xingamentos' },
    { 'Sua mãe aquela vagabunda', 'xingamentos' },
    { 'Vai tomar no cu da tua mãe', 'xingamentos' },
    { 'Tua mãe dá o cu', 'xingamentos' },
    { 'Sua mãe chupa meu pau', 'xingamentos' },
    { 'Tua mãe trabalha no puteiro', 'xingamentos' },
    { 'Filho de uma rapariga', 'xingamentos' },
    { 'Tô puta, filho da puta', 'xingamentos' },
    { 'Seu macaco imundo', 'discriminacao' },
    { 'Preto é tudo ladrão', 'discriminacao' },
    { 'Volta pra senzala', 'discriminacao' },
    { 'Heil Hitler!', 'discriminacao' },
    { 'Hitler tinha razão', 'discriminacao' },
    { 'Morte aos judeus', 'discriminacao' },
    { 'Gay é doença', 'discriminacao' },
    { 'Lugar de mulher é na cozinha', 'discriminacao' },
    { 'Nordestino burro', 'discriminacao' },
    { 'Isso é um assalto, passa o celular', 'assalto' },
    { 'Quer comprar maconha?', 'drogas' },
}

RegisterCommand('transcricao_exemplos', function(source)
    if source ~= 0 then return end
    local erros = 0
    for _, ex in ipairs(EXEMPLOS) do
        local resultado, _, resumo = descrever(ex[1])
        local achou = {}
        for _, r in ipairs(resultado) do
            if r.frase then achou[r.categoria.id] = true end
        end
        local ok
        if ex[2] then
            ok = achou[ex[2]] == true
        else
            ok = next(achou) == nil
        end
        if not ok then erros = erros + 1 end
        print(('[%s] %s "%s" -> %s'):format(RESOURCE, ok and '^2OK^7  ' or '^1FALHA^7', ex[1], resumo))
    end
    print(('[%s] exemplos: %d de %d corretos'):format(RESOURCE, #EXEMPLOS - erros, #EXEMPLOS))
end, true)

local total = 0
for _, c in ipairs(categorias) do total = total + #c.regras end
print(('[%s] falas carregadas: %d categorias, %d frases/padrões'):format(RESOURCE, #categorias, total))
