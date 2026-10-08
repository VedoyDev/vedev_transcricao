// Recebe o áudio gravado pelo cliente e envia para as APIs de transcrição
// configuradas (Groq, Cloudflare, OpenAI, Whisper próprio...). Se uma recusar
// (limite, erro, fora do ar), o mesmo áudio vai para a próxima.
// As chaves ficam só aqui no servidor, nunca vão para o cliente.

const http = require('http');
const https = require('https');

const RESOURCE = GetCurrentResourceName();

const C = globalThis.ConfigServidor || {};
const CHAVE_EXEMPLO = 'COLOQUE_SUA_CHAVE_AQUI';

const cfg = {
    idioma: C.idioma || 'pt',
    prompt: C.prompt || '',
    cooldownMs: C.cooldownMs ?? 300,
    maxBytes: (C.maxKb ?? 1024) * 1024,
    timeoutMs: 20000,
    debug: C.debug === true,
};

// Frases que o Whisper costuma "inventar" quando o áudio é silêncio/ruído
const ALUCINACOES = [
    'amara.org',
    'legendas pela comunidade',
    'legendado por',
    'obrigado por assistir',
    'inscreva-se no canal',
];

const ultimoPedido = new Map(); // src -> timestamp
const emAndamento = new Map();  // src -> transcrições em andamento
const MAX_SIMULTANEAS = 2;      // por jogador (no modo automático as frases chegam em sequência)

function log(...args) {
    console.log(`[${RESOURCE}]`, ...args);
}

function extensaoDoMime(mime) {
    if (mime.includes('wav')) return { nome: 'audio.wav', tipo: 'audio/wav' };
    if (mime.includes('ogg')) return { nome: 'audio.ogg', tipo: 'audio/ogg' };
    if (mime.includes('mp4')) return { nome: 'audio.mp4', tipo: 'audio/mp4' };
    return { nome: 'audio.webm', tipo: 'audio/webm' };
}

function montarMultipart(campos, arquivo) {
    const boundary = '----vedev' + Date.now().toString(16) + Math.random().toString(16).slice(2);
    const partes = [];

    for (const [nome, valor] of Object.entries(campos)) {
        if (valor === undefined || valor === null || valor === '') continue;
        partes.push(Buffer.from(
            `--${boundary}\r\nContent-Disposition: form-data; name="${nome}"\r\n\r\n${valor}\r\n`
        ));
    }

    partes.push(Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${arquivo.nome}"\r\n` +
        `Content-Type: ${arquivo.tipo}\r\n\r\n`
    ));
    partes.push(arquivo.dados);
    partes.push(Buffer.from(`\r\n--${boundary}--\r\n`));

    return { corpo: Buffer.concat(partes), boundary };
}

function postar(urlTexto, headers, corpo) {
    return new Promise((resolve, reject) => {
        const url = new URL(urlTexto);
        const lib = url.protocol === 'http:' ? http : https;

        const req = lib.request(url, {
            method: 'POST',
            headers: { ...headers, 'Content-Length': corpo.length },
            timeout: cfg.timeoutMs,
        }, (res) => {
            const pedacos = [];
            res.on('data', (c) => pedacos.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                headers: res.headers,
                corpo: Buffer.concat(pedacos).toString('utf8'),
            }));
        });

        req.on('timeout', () => req.destroy(new Error('timeout')));
        req.on('error', reject);
        req.end(corpo);
    });
}

// ---------------------------------------------------------------------------
// Provedores
// ---------------------------------------------------------------------------

function preenchido(valor) {
    return typeof valor === 'string' && valor !== '' && valor !== CHAVE_EXEMPLO;
}

// Aceita o formato antigo (chave/endpoint/modelo soltos) como um provedor só
const listaConfig = Array.isArray(C.provedores) ? C.provedores
    : [{ nome: 'API', tipo: 'openai', chave: C.chave, endpoint: C.endpoint, modelo: C.modelo }];

const provedores = listaConfig.map((p) => ({ ...p, pausadoAte: 0 })).filter((p) => {
    if (p.ativo === false) return false;
    if (p.tipo === 'cloudflare') return preenchido(p.contaId) && preenchido(p.token);
    if (!p.endpoint) p.endpoint = 'https://api.groq.com/openai/v1/audio/transcriptions';
    // endpoint local (http://) não precisa de chave
    return preenchido(p.chave) || p.endpoint.startsWith('http://');
});

class ErroApi extends Error {
    constructor(mensagem, status, pausaMs) {
        super(mensagem);
        this.status = status;
        this.pausaMs = pausaMs;
    }
}

function msAteMeiaNoiteUtc() {
    const agora = new Date();
    return Date.UTC(agora.getUTCFullYear(), agora.getUTCMonth(), agora.getUTCDate() + 1) - agora.getTime() + 60 * 1000;
}

// Quanto tempo deixar um provedor de lado depois de uma falha
function pausaPara(status, headers) {
    if (status === 429) {
        const retry = Number(headers && headers['retry-after']);
        return Number.isFinite(retry) && retry > 0 ? Math.min(retry * 1000, 6 * 3600 * 1000) : 60 * 1000;
    }
    if (status === 401 || status === 403) return 10 * 60 * 1000; // chave/token errado
    if (status >= 500) return 30 * 1000;                         // fora do ar
    return 0;                                                    // erro só deste áudio
}

async function chamarOpenAI(p, audio, mime) {
    const arquivo = { ...extensaoDoMime(mime), dados: audio };
    const { corpo, boundary } = montarMultipart({
        model: p.modelo,
        language: cfg.idioma,
        prompt: cfg.prompt,
        response_format: 'json',
        temperature: '0',
    }, arquivo);

    const headers = { 'Content-Type': `multipart/form-data; boundary=${boundary}` };
    if (preenchido(p.chave)) headers['Authorization'] = `Bearer ${p.chave}`;

    const res = await postar(p.endpoint, headers, corpo);
    if (res.status < 200 || res.status >= 300) {
        throw new ErroApi(`HTTP ${res.status}: ${res.corpo.slice(0, 200)}`, res.status, pausaPara(res.status, res.headers));
    }
    return String(JSON.parse(res.corpo).text || '').trim();
}

async function chamarCloudflare(p, audio) {
    const modelo = p.modelo || '@cf/openai/whisper-large-v3-turbo';
    const url = `https://api.cloudflare.com/client/v4/accounts/${p.contaId}/ai/run/${modelo}`;
    const entrada = { audio: audio.toString('base64'), language: cfg.idioma };
    if (cfg.prompt) entrada.initial_prompt = cfg.prompt;
    const corpo = Buffer.from(JSON.stringify(entrada));

    const res = await postar(url, { 'Content-Type': 'application/json', 'Authorization': `Bearer ${p.token}` }, corpo);
    let json = null;
    try { json = JSON.parse(res.corpo); } catch {}

    if (res.status < 200 || res.status >= 300 || !json || json.success === false) {
        const detalhe = json && json.errors && json.errors[0] ? json.errors[0].message : res.corpo.slice(0, 200);
        // cota grátis diária esgotada: só volta depois da meia-noite UTC
        const esgotou = /neurons|daily|allocation|quota/i.test(detalhe);
        const pausa = esgotou ? msAteMeiaNoiteUtc() : pausaPara(res.status, res.headers);
        throw new ErroApi(`HTTP ${res.status}: ${detalhe}`, res.status, pausa);
    }
    const r = json.result || {};
    return String(r.text || (r.transcription_info && r.transcription_info.text) || '').trim();
}

// Tenta cada provedor disponível, na ordem. Retorna { texto, provedor }.
async function transcrever(audio, mime) {
    const agora = Date.now();
    let disponiveis = provedores.filter((p) => p.pausadoAte <= agora);
    if (disponiveis.length === 0) {
        // todos pausados: tenta o que volta primeiro, em vez de desistir
        disponiveis = [provedores.reduce((a, b) => (a.pausadoAte <= b.pausadoAte ? a : b))];
    }

    let ultimoErro;
    for (const p of disponiveis) {
        // com um provedor só, uma falha de rede ganha uma segunda tentativa
        const tentativas = disponiveis.length === 1 ? 2 : 1;
        for (let t = 1; t <= tentativas; t++) {
            try {
                const texto = p.tipo === 'cloudflare' ? await chamarCloudflare(p, audio) : await chamarOpenAI(p, audio, mime);
                if (p.pausadoAte) {
                    p.pausadoAte = 0;
                    log(`${p.nome} voltou a responder.`);
                }
                return { texto, provedor: p.nome };
            } catch (err) {
                ultimoErro = err;
                const deRede = !(err instanceof ErroApi);
                const pausa = deRede ? 15 * 1000 : err.pausaMs;
                if (pausa > 0 && t === tentativas) {
                    p.pausadoAte = Date.now() + pausa;
                    const proximo = disponiveis[disponiveis.indexOf(p) + 1];
                    log(`^3${p.nome} indisponível (${err.message.slice(0, 120)}) por ${Math.round(pausa / 1000)} s` +
                        (proximo ? `, usando ${proximo.nome}^7` : '^7'));
                } else if (cfg.debug) {
                    log(`${p.nome} falhou: ${err.message.slice(0, 160)}`);
                }
                if (!deRede && pausa === 0) break; // erro deste áudio: não adianta repetir no mesmo
            }
        }
    }
    throw ultimoErro || new Error('nenhuma API de transcrição configurada');
}

// ---------------------------------------------------------------------------
// Áudio como prova no Discord
// Cada fala transcrita fica guardada por alguns segundos, com um id. Se o
// server/falas.lua detectar algo que deve ir com áudio, chama o export
// EnviarWebhookComAudio(url, json, audioId) e o arquivo vai anexado.
// ---------------------------------------------------------------------------

const AUDIO_TTL_MS = 30 * 1000;
const audiosRecentes = new Map(); // id -> { audio, expira }
let proximoAudioId = 0;

function guardarAudio(audio) {
    const id = ++proximoAudioId;
    audiosRecentes.set(id, { audio, expira: Date.now() + AUDIO_TTL_MS });
    return id;
}

setInterval(() => {
    const agora = Date.now();
    for (const [id, a] of audiosRecentes) if (a.expira < agora) audiosRecentes.delete(id);
}, 10 * 1000);

function multipartWebhook(payloadJson, arquivo, nomeArquivo) {
    const boundary = '----vedev' + Date.now().toString(16) + Math.random().toString(16).slice(2);
    const corpo = Buffer.concat([
        Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\n` +
            `Content-Type: application/json\r\n\r\n`),
        Buffer.from(payloadJson, 'utf8'),
        Buffer.from(`\r\n--${boundary}\r\nContent-Disposition: form-data; name="files[0]"; filename="${nomeArquivo}"\r\n` +
            `Content-Type: audio/wav\r\n\r\n`),
        arquivo,
        Buffer.from(`\r\n--${boundary}--\r\n`),
    ]);
    return { corpo, boundary };
}

exports('EnviarWebhookComAudio', (url, payloadJson, audioId) => {
    const guardado = audiosRecentes.get(Number(audioId));
    if (!guardado || typeof url !== 'string' || typeof payloadJson !== 'string') return false;

    const nome = `fala_${new Date().toISOString().replace(/[:.]/g, '-')}.wav`;
    const { corpo, boundary } = multipartWebhook(payloadJson, guardado.audio, nome);
    postar(url, { 'Content-Type': `multipart/form-data; boundary=${boundary}` }, corpo)
        .then((res) => {
            if (res.status < 200 || res.status >= 300) {
                log(`^3webhook com áudio recusado (HTTP ${res.status}): ${res.corpo.slice(0, 200)}^7`);
            }
        })
        .catch((err) => log(`^3falha ao enviar webhook com áudio: ${err.message}^7`));
    return true;
});

// O Whisper às vezes repete a mesma frase em linhas seguidas ("Sou bicha\nSou bicha").
// Junta as linhas e remove repetições seguidas.
function limparRepeticoes(texto) {
    const chave = (s) => s.toLowerCase().replace(/[^\p{L}\p{N} ]/gu, '').trim();
    const linhas = texto.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const unicas = linhas.filter((l, i) => i === 0 || chave(l) !== chave(linhas[i - 1]));
    return unicas.join(' ').trim();
}

function ehAlucinacao(texto) {
    const t = texto.toLowerCase();
    // ruído às vezes vira texto em outro alfabeto (ex.: coreano)
    if (!/[a-z0-9À-ÿ]/i.test(t)) return true;
    return ALUCINACOES.some((frase) => t.includes(frase));
}

onNet('vedev_transcricao:audio', async (base64, mime, id) => {
    const src = global.source;
    const responder = (texto, erro) => {
        if (GetPlayerName(src)) emitNet('vedev_transcricao:resultado', src, texto, erro, id);
    };

    if (typeof base64 !== 'string' || base64.length === 0) return;
    if (base64.length > cfg.maxBytes * 4 / 3) return responder(null, 'Áudio muito grande');

    if (provedores.length === 0) {
        return responder(null, 'Transcrição não configurada no servidor');
    }

    const agora = Date.now();
    const andamento = emAndamento.get(src) || 0;
    if (andamento >= MAX_SIMULTANEAS || agora - (ultimoPedido.get(src) || 0) < cfg.cooldownMs) {
        return responder(null, 'Aguarde um momento');
    }
    ultimoPedido.set(src, agora);
    emAndamento.set(src, andamento + 1);

    try {
        const audio = Buffer.from(base64, 'base64');
        const resultado = await transcrever(audio, typeof mime === 'string' ? mime : 'audio/wav');
        let texto = limparRepeticoes(resultado.texto);
        if (ehAlucinacao(texto)) texto = '';

        if (cfg.debug) log(`[${resultado.provedor} | ${Date.now() - agora} ms] ${GetPlayerName(src)} (${src}): ${texto}`);

        if (!texto) return responder(null, 'Nenhuma fala reconhecida');

        responder(texto, null);

        // Outros scripts do servidor podem escutar:
        // AddEventHandler('vedev_transcricao:texto', function(src, texto, provedor) ... end)
        emit('vedev_transcricao:texto', src, texto, resultado.provedor, guardarAudio(audio));
    } catch (err) {
        log(`falha ao transcrever áudio de ${src}: ${err.message}`);
        responder(null, 'Falha na transcrição');
    } finally {
        const restante = (emAndamento.get(src) || 1) - 1;
        if (restante > 0) emAndamento.set(src, restante);
        else emAndamento.delete(src);
    }
});

on('playerDropped', () => {
    ultimoPedido.delete(global.source);
    emAndamento.delete(global.source);
});

if (provedores.length === 0) {
    log('^3AVISO: nenhuma API configurada em config_servidor.js, a transcrição não funciona.^7');
} else {
    log(`pronto. APIs: ${provedores.map((p) => p.nome).join(' -> ')} | idioma=${cfg.idioma}`);
}
