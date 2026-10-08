-- =============================================================================
-- FALAS -> AÇÕES
-- Roda só no SERVIDOR (os jogadores não conseguem ver esta lista).
--
-- Maiúsculas, acentos e pontuação são ignorados: 'é' = 'e', 'ç' = 'c'.
-- A comparação é por palavra inteira: 'mao' não casa com 'mamao'.
--
-- COMO ESCREVER AS FRASES
--   'isso e um assalto'        palavras nessa ordem, juntas
--   { 'passa', 'celular' }     todas as palavras, em qualquer ordem e posição
--
-- PADRÕES (interpretador de contexto) - dá para misturar tudo:
--   {mae}         qualquer palavra do grupo `mae` (veja Falas.Grupos abaixo)
--   viva|salve    uma palavra OU outra (também vale com grupos: {comer}|como)
--   a?            palavra opcional (também vale para grupos: {intens}?)
--   *             até 3 palavras quaisquer no meio  (*2 = até 2, *5 = até 5)
--
--   Exemplo: 'eu como|{comer} a? {poss}? {mae}'
--     casa:     "eu como tua mãe", "eu comi a sua mãe", "eu fodi tua coroa"
--     não casa: "como está tua mãe", "sou tua mãe", "como vai sua mãe"
--
-- EXCEÇÕES (por categoria): frases normais. Um acerto que fica TODO dentro de uma
-- exceção é ignorado. Ex.: exceção '{estar} {intens}? puta' faz "tô puta contigo"
-- (com raiva) não contar como xingamento, mas "tô puta, filho da puta" ainda conta.
--
-- Para testar no console do servidor:
--   transcricao_testar 1 eu como tua mãe      (mostra o que casou e dispara as ações)
--   transcricao_exemplos                      (roda frases de exemplo, sem disparar nada)
--
-- Quando uma categoria é detectada, o script:
--   1. imprime no console do servidor (se log = true)
--   2. manda para o Discord: nome, RG, ID, data e hora (só se enviarWebhook = true)
--      e, com anexarAudio = true, o trecho de áudio da fala anexado como prova
--   3. mostra uma notificação para o jogador (se aviso estiver preenchido)
--   4. dispara o evento de servidor 'vedev_transcricao:fala' (src, categoria, texto, frase)
--   5. chama a função `acao` da categoria (se existir)
--   6. conta as ocorrências e chama `aoAtingirLimite` ao chegar em `limite`
-- =============================================================================

Falas = {}

-- Webhook do Discord usado por todas as categorias com `enviarWebhook = true`.
Falas.Webhook = ''  -- URL do webhook do Discord (Configurações do canal > Integrações > Webhooks)

-- Formato da data e hora no webhook (horário do servidor)
Falas.FormatoDataHora = '%d/%m/%Y %H:%M:%S'

-- Quantas palavras o `*` aceita no meio, quando não tem número
Falas.LacunaPadrao = 3

-- Grupos de palavras usados nos padrões como {nome}. Uma palavra por item.
Falas.Grupos = {
    -- mãe e família
    mae        = { 'mae', 'mamae', 'maezinha', 'mainha', 'mamis', 'genitora', 'progenitora', 'coroa', 'velha' },
    poss       = { 'tua', 'sua', 'tu', 'teu', 'vossa' },
    de         = { 'da', 'de', 'do', 'dessa', 'daquela', 'na', 'no', 'pra', 'pro', 'para', 'pela', 'nessa' },
    dele       = { 'dele', 'dela', 'do', 'da', 'deles' },

    -- verbos
    ser        = { 'e', 'eh', 'era', 'foi', 'virou', 'vira', 'parece', 'sempre' },
    estar      = { 'esta', 'ta', 'tava', 'estava', 'estou', 'to', 'tou', 'ficou', 'fica', 'fico', 'fiquei', 'ficar', 'vai', 'anda', 'deixou', 'deixa' },
    intens     = { 'muito', 'mo', 'mt', 'bem', 'super', 'mega', 'meio', 'tao', 'mais', 'muita' },

    -- "comer" no sentido sexual (sem 'como', que também é "de que jeito")
    comer      = { 'comi', 'comendo', 'comeu', 'comer', 'comia', 'comerei', 'comeria', 'fodi', 'fudi', 'fodo', 'fudo',
                   'foder', 'fuder', 'fodendo', 'fudendo', 'fodia', 'traco', 'tracei', 'tracar', 'papei', 'papar',
                   'chupei', 'chupo', 'chupar', 'arrombei', 'arrombo', 'arrombar', 'meti', 'meto', 'meter',
                   'enrabei', 'enrabo', 'enrabar', 'currei', 'curro', 'currar', 'estuprei', 'estupro', 'estuprar' },
    depois_comer = { 'gostoso', 'gostosinho', 'todo', 'toda', 'todinha', 'inteira', 'sempre', 'mesmo', 'direto',
                     'ontem', 'hoje', 'quatro', 'pelada', 'peladinha', 'sem', 'devagar', 'forte' },

    insulto_mulher = { 'puta', 'putinha', 'putona', 'vadia', 'piranha', 'vagabunda', 'vagaba', 'rapariga', 'quenga',
                       'biscate', 'prostituta', 'meretriz', 'arrombada', 'rodada', 'cadela', 'cachorra', 'safada',
                       'galinha', 'vaca', 'gostosa', 'marmita', 'puteira', 'piriguete' },
    parte      = { 'cu', 'cuzinho', 'buceta', 'boceta', 'bucetao', 'xoxota', 'xereca', 'xota', 'priquito',
                   'perereca', 'pepeca', 'raba', 'rabo', 'bunda', 'teta', 'tetas', 'peito', 'peitos' },
    objeto     = { 'pau', 'rola', 'pica', 'piroca', 'pirocao', 'pinto', 'caralho', 'cacete', 'benga',
                   'cu', 'buceta', 'rabo', 'leite', 'porra' },
    acao_sexual = { 'da', 'deu', 'dando', 'chupa', 'chupou', 'chupando', 'mama', 'mamou', 'mamando', 'senta',
                    'sentou', 'sentando', 'rebola', 'rebolou', 'libera', 'liberou', 'abre', 'abriu', 'engole',
                    'engoliu', 'toma', 'tomou', 'leva', 'levou', 'gosta', 'gostou', 'adora' },
    lugar_puta = { 'puteiro', 'bordel', 'cabare', 'prostibulo', 'boate' },

    -- discriminação
    raca       = { 'preto', 'preta', 'pretos', 'pretas', 'negro', 'negra', 'negros', 'negras', 'nego', 'nega',
                   'neguinho', 'neguinha', 'negrinho', 'negrinha', 'macaco', 'macaca', 'macacos', 'crioulo',
                   'crioula', 'tiziu', 'escurinho', 'escurinha' },
    sujo       = { 'imundo', 'imunda', 'sujo', 'suja', 'fedido', 'fedida', 'fedorento', 'fedorenta', 'nojento',
                   'nojenta', 'burro', 'burra', 'ladrao', 'ladra', 'vagabundo', 'vagabunda', 'safado', 'safada',
                   'inferior', 'lixo', 'escravo', 'escrava' },
    estereotipo = { 'ladrao', 'ladroes', 'bandido', 'bandidos', 'vagabundo', 'vagabundos', 'burro', 'burros',
                    'macaco', 'macacos', 'lixo', 'inferior', 'inferiores', 'escravo', 'escravos', 'sujo', 'sujos' },
    lgbt       = { 'gay', 'gays', 'lesbica', 'lesbicas', 'travesti', 'travestis', 'trans', 'bissexual', 'homossexual',
                   'homossexuais', 'viado', 'viados', 'veado', 'veados', 'sapatao', 'bicha', 'bichas' },
    doenca     = { 'doenca', 'doente', 'doentes', 'aberracao', 'nojento', 'nojenta', 'nojo', 'errado', 'pecado',
                   'anormal', 'praga' },
    alvo_odio  = { 'judeu', 'judeus', 'negros', 'pretos', 'macacos', 'gays', 'viados', 'nordestinos', 'baianos',
                   'paraibas', 'travestis', 'imigrantes', 'pobres', 'favelados' },
    matar      = { 'matar', 'mata', 'morte', 'morram', 'morra', 'exterminar', 'extermina', 'queimar', 'queima',
                   'fuzilar', 'enforcar', 'eliminar' },
    coisa      = { 'carro', 'saco', 'sapato', 'tenis', 'moto', 'roupa', 'camisa', 'camiseta', 'calca', 'casaco',
                   'jaqueta', 'blusa', 'vestido', 'bone', 'celular', 'cachorro', 'gato', 'cavalo', 'pano', 'chao',
                   'asfalto', 'pneu', 'vidro', 'banco', 'tapete', 'mercado', 'humor', 'buraco', 'cinto', 'faixa',
                   'quadro', 'carvao', 'cafe', 'feijao', 'olho', 'olhos', 'cabelo', 'fumo', 'po', 'sabao' },
    nordeste   = { 'nordestino', 'nordestina', 'nordestinos', 'baiano', 'baiana', 'baianos', 'paraiba', 'paraibas',
                   'cearense', 'piauiense', 'maranhense', 'pernambucano', 'alagoano', 'sergipano' },
}

Falas.Categorias = {

    -- -------------------------------------------------------------------------
    assalto = {
        ativo = true,
        nome = 'Assalto / Roubo',
        cooldown = 15,    -- segundos entre disparos para o mesmo jogador
        log = true,
        enviarWebhook = false, -- true = manda para o Discord
        cor = 15105570,   -- cor da mensagem no Discord (laranja)
        aviso = nil,      -- notificação para o jogador (nil = nenhuma)

        frases = {
            'isso e um assalto',
            'e um assalto',
            'perdeu perdeu',
            'perdeu playboy',
            'maos ao alto',
            'maos para cima',
            'mao na cabeca',
            'passa tudo',
            'passa a carteira',
            'passa o celular',
            'passa a chave',
            'passa o dinheiro',
            'passa a grana',
            'desce do carro',
            'sai|saia|saí|sair|desce|desca|desça do|da carro|moto|veiculo',
            'levanta|levante|levantar|bota|coloca|poe a|as mao|maos',
            'mao|maos pra|para|na cima|cabeca|parede',
            'parado|parada ai',
            'fica|ficar parado|parada',
            'sai|saia do carro',
            'deita no chao',
            'ninguem se mexe',
            'abre o cofre',
            { 'passa', 'celular' },
            { 'passa', 'carteira' },
            { 'passa', 'dinheiro' },
        },

        -- Função chamada no servidor quando a categoria é detectada.
        -- src = id do jogador, texto = tudo que ele falou, frase = frase que casou
        acao = function(src, texto, frase)
            -- Exemplo: avisar a polícia, fazer o NPC mais próximo levantar as mãos, etc.
            -- TriggerClientEvent('meu_script:npcRendido', src)
        end,
    },

    -- -------------------------------------------------------------------------
    drogas = {
        ativo = true,
        nome = 'Venda de drogas',
        cooldown = 15,
        log = true,
        enviarWebhook = false,
        cor = 10181046,   -- roxo
        aviso = nil,

        frases = {
            'quer comprar',
            'quer droga',
            'quer erva',
            'quer maconha',
            'quer po',
            'quer cocaina',
            'quer crack',
            'quer bala',
            'quer lanca',
            'tenho maconha',
            'tenho cocaina',
            'tenho pedra',
            'vendo maconha',
            'vendo droga',
            'vendo erva',
            'vende droga',
            'vai querer quanto',
            'quer|tem|tenho|vende|vendo uma? paradinha|baseado|beck|fino|pino|pedra|bala|doce',
            'paradinha boa',
            'faco um preco',
            { 'compra', 'droga' },
            { 'vender', 'droga' },
            { 'vender', 'maconha' },
            { 'grama', 'maconha' },
            { 'grama', 'cocaina' },
        },

        acao = function(src, texto, frase)
            -- Exemplo: liberar a venda para o NPC mais próximo
            -- TriggerClientEvent('meu_script:ofertaDroga', src)
        end,
    },

    -- -------------------------------------------------------------------------
    xingamentos = {
        ativo = true,
        nome = 'Palavras ofensivas',
        cooldown = 5,
        log = true,
        enviarWebhook = true, -- xingamentos vão para o Discord
        anexarAudio = true,   -- manda o trecho de áudio da fala junto, como prova
        cor = 15158332,   -- vermelho
        aviso = 'Evite palavras ofensivas.',

        -- Conta quantas vezes cada jogador falou algo desta categoria (zera ao sair).
        -- Ao chegar no limite, chama `aoAtingirLimite` e zera a contagem.
        limite = 5,
        aoAtingirLimite = function(src, total)
            -- Exemplo: expulsar do servidor
            -- DropPlayer(src, 'Linguagem ofensiva no chat de voz.')
        end,

        frases = {
            -- ---------------- Xingamentos gerais ----------------
            'filho da puta', 'filha da puta', 'fdp', 'filho de uma egua', 'filho de rapariga',
            'filho|filha|fio|fia da|de uma? {insulto_mulher}',
            'puta que pariu', 'puta que te pariu', 'puta merda', 'puta', 'vai pra puta que pariu',
            'vai se foder', 'vai se fuder', 'vai te foder', 'se fode', 'se foda', 'foda se',
            'vai tomar no cu', 'tomar no cu', 'toma no cu', 'pau no cu', 'enfia no cu',
            'vai a merda', 'vai pra merda', 'seu merda', 'sua merda', 'merda', 'bosta', 'seu bosta',
            'caralho', 'porra', 'cacete', 'fudido', 'fodido', 'fudida', 'fodida',
            'cuzao', 'cuzona', 'arrombado', 'arrombada', 'desgracado', 'desgracada',
            'escroto', 'escrota', 'otario', 'otaria', 'babaca', 'imbecil', 'idiota', 'cretino', 'cretina',
            'lixo humano', 'seu lixo', 'sua lixo', 'verme', 'seu verme',
            'corno', 'corna', 'chifrudo', 'chifruda', 'pilantra', 'safado', 'safada', 'canalha',
            'vagabundo', 'vagabunda', 'vadia', 'piranha', 'biscate', 'rapariga', 'quenga',
            'chupa meu pau', 'chupa rola', 'mama aqui', 'mamador', 'buceta', 'boceta', 'xoxota', 'piroca',
            'fuck', 'fuck you', 'motherfucker', 'bitch', 'son of a bitch', 'asshole',

            -- ---------------- Capacitismo ----------------
            'retardado', 'retardada', 'mongol', 'mongoloide', 'debil mental', 'debiloide',
            'seu|sua aleijado|aleijada', 'seu doente mental', 'autista de merda', 'retard',

            -- ---------------- Ofensas à mãe (interpretador) ----------------
            -- "eu como/comi (a) tua mãe"
            'eu como|{comer} a? {poss}? {mae}',
            -- "comi/fodi tua mãe" (sem o "eu"; não inclui "como", que também é pergunta)
            '{comer} a? {poss} {mae}',
            -- "fodi a mãe dele / do João"
            '{comer} a {mae} {dele}',
            -- "como tua mãe gostoso / todo dia / de quatro"
            'como a? {poss} {mae} {depois_comer}',
            'como a? {poss} {mae} de quatro',
            -- "tua mãe é (uma) puta", "sua mãe virou vadia"
            '{poss} {mae} {ser} uma? {insulto_mulher}',
            -- "sua mãe (aquela) vagabunda"
            '{poss} {mae} aquela|essa? {insulto_mulher}',
            -- "a puta da tua mãe", "vagabunda da sua mãe"
            '{insulto_mulher} {de} {poss} {mae}',
            -- "no cu da tua mãe", "a buceta da sua mãe"
            '{parte} {de} {poss} {mae}',
            -- "tua mãe dá o cu", "sua mãe chupa meu pau", "tua mãe mama rola"
            '{poss} {mae} {acao_sexual} * {objeto}',
            -- "meu pau na tua mãe"
            'meu {objeto} {de} {poss} {mae}',
            -- "tua mãe trabalha no puteiro"
            '{poss} {mae} * {lugar_puta}',
            -- "manda tua mãe chupar / sentar"
            'manda a? {poss} {mae} chupar|sentar|mamar|rebolar|dar',
        },

        -- Frases normais: um acerto que fica todo dentro de uma destas é ignorado
        excecoes = {
            '{estar} {intens}? puta',                -- "tô puta", "ficou puta da vida", "tua mãe tá puta contigo"
            'puta {intens}? da vida',
            'como {estar} a? {poss} {mae}',           -- "como está tua mãe"
            'como vai a? {poss} {mae}',               -- "como vai sua mãe"
            'sou a? {poss} {mae}',                    -- "sou tua mãe"
            'cade a? {poss} {mae}',
        },

        acao = function(src, texto, frase)
        end,
    },

    -- -------------------------------------------------------------------------
    discriminacao = {
        ativo = true,
        nome = 'Discriminação (racismo, homofobia, nazismo...)',
        cooldown = 0,
        log = true,
        enviarWebhook = true,
        anexarAudio = true,   -- manda o trecho de áudio da fala junto, como prova
        cor = 8388608,     -- vinho
        aviso = 'Discriminação é crime e não é tolerada neste servidor.',

        -- Expulsa na primeira ocorrência
        limite = 1,
        aoAtingirLimite = function(src, total)
            DropPlayer(src, 'Você foi expulso por fala discriminatória (racismo, homofobia, nazismo etc.). A staff recebeu o registro.')
        end,

        frases = {
            -- ---------------- Racismo / injúria racial ----------------
            '{raca} {sujo}',                                         -- "preto sujo", "macaco imundo"
            '{raca} de merda|bosta',
            'seu|sua|esse|essa macaco|macaca|crioulo|crioula|tiziu|negrinho|negrinha',
            '{raca} {ser}? tudo|todo|sempre? {estereotipo}',         -- "preto é tudo ladrão"
            'volta|vai|voltar pra|pro|para a|o? senzala|tronco|africa|chicote',
            'cabelo ruim|duro|pixaim', 'cabelo de bombril', 'cabelo de palha de aco',
            'servico|coisa|cara|jeito de preto|negro|macaco',
            'so podia ser preto|negro|macaco', 'lugar de preto|negro',
            'crioulo', 'crioula', 'picole de asfalto', 'ticao', 'raca inferior', 'raca ruim',
            'seu|sua escravo|escrava', 'escravo de branco',
            'nigger', 'nigga', 'niggers',
            'china|chines|japones|japa de merda', 'china|chines|japones imundo|sujo',
            'indio imundo|sujo|preguicoso', 'indio de merda', 'bugre',

            -- ---------------- Xenofobia / preconceito social ----------------
            '{nordeste} {sujo}', '{nordeste} de merda|bosta', '{nordeste} {ser}? tudo|todo|sempre? {estereotipo}',
            'baiano|baiana preguicoso|preguicosa', 'seu paraiba', 'cabeca chata', 'volta|vai pro nordeste',
            'favelado|favelada {sujo}', 'favelado|favelada de merda', 'seu favelado|favelada',

            -- ---------------- Homofobia / transfobia ----------------
            'viado', 'seu viado', 'seu veado', 'veadinho', 'viadinho', 'bicha', 'bichinha', 'bichona',
            'boiola', 'boiolinha', 'baitola', 'frutinha', 'maricas', 'mulherzinha', 'queima rosca',
            'gayzinho', 'sapatao', 'sapatona', 'fanchona', 'traveco', 'travecao', 'faggot',
            'vira homem', 'vira macho',
            '{lgbt} {sujo}', '{lgbt} de merda|bosta', '{lgbt} {ser} {doenca}',
            'ser|virar gay|viado {ser}? {doenca}',

            -- ---------------- Machismo / misoginia ----------------
            'lugar de mulher e na cozinha', 'lugar de mulher e no tanque', 'volta|vai pra cozinha',
            'mulher nao presta', 'tinha que ser mulher', 'mulher no volante',
            'mulher|mulheres {ser}? tudo|toda|todas? burra|burras|inferior|inferiores|interesseira|interesseiras',

            -- ---------------- Nazismo / supremacismo / antissemitismo ----------------
            'heil hitler', 'sieg heil', 'heil', 'viva|salve|ave o? hitler|nazismo|reich',
            'hitler {ser}|tinha|estava um? razao|certo|heroi|bom|lenda|genio|foda',
            'sou|virei|orgulho de? nazista|neonazista|nazi',
            'nazismo {ser} bom|certo|lindo|foda|o? caminho',
            'nazismo {ser} a solucao',
            'white power', 'poder branco', 'orgulho branco', 'orgulho de ser branco', 'supremacia branca',
            'raca pura', 'raca superior', 'raca ariana', 'pureza racial', 'limpeza racial',
            'holocausto nunca|nao existiu|aconteceu', 'holocausto {ser} mentira|farsa|pouco|bom',
            'faltou|precisa|precisava de? holocausto', 'camara de gas para|pra|nos|nas',
            'forno|gas nos|pros|para|pra judeus', 'suastica', 'ku klux klan', '1488',
            'quatorze palavras', 'fourteen words',
            '{alvo_odio} {sujo}', '{alvo_odio} de merda|bosta',

            -- ---------------- Incitação de ódio ----------------
            '{matar} a|aos|os|todo|todos|esses? {alvo_odio}',          -- "morte aos judeus", "matar todos os gays"
            'tem|tinha|precisa que? {matar} * {alvo_odio}',
        },

        excecoes = {
            'contra o? racismo|nazismo|homofobia|preconceito',   -- "luta contra o racismo"
            -- cor de objeto/animal: "carro preto sujo", "saco preto de lixo", "cavalo negro imundo"
            '{coisa} {raca} {sujo}|de',
            'macaco hidraulico|mecanico',                        -- ferramenta da mecânica
        },

        acao = function(src, texto, frase)
        end,
    },
}
