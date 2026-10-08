const RESOURCE = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'vedev_transcricao';
const TAXA_SAIDA = 16000; // Whisper trabalha em 16 kHz
const MIN_MS = 400;       // gravações mais curtas que isso são descartadas
const LIMIAR_MIN = 0.005; // volume (RMS) mínimo para um pedaço contar como voz
const MARGEM_MS = 250;    // silêncio mantido antes/depois da fala ao cortar
const CHAVE_MIC = 'vedev_transcricao:microfone';

const indicador = document.getElementById('indicador');
const indicadorTexto = document.getElementById('indicador-texto');
const legenda = document.getElementById('legenda');

// Captura contínua do microfone em PCM. Fora da gravação, guarda só os últimos
// `preRollMs` (para não cortar o começo da fala quando a detecção demora).
let ctx = null;
let stream = null;
let preRoll = [];          // Float32Array[] (buffer circular)
let preRollVoz = [];       // para cada pedaço do preRoll: tem voz?
let ruido = 0.01;          // nível do ruído de fundo (RMS), acompanhado continuamente
let minFalaMs = 350;       // menos voz que isso na gravação = descarta (tosse, "hm", clique)
let preRollAmostras = 0;
let preRollMs = 500;
let gravacao = null;       // { pedacos, amostras, inicio, timerMax } enquanto grava
let abrindo = null;        // Promise enquanto o microfone está sendo aberto
let pararSolicitado = false;
let mostrarIndicador = true;
let pendentes = 0;
let timerLegenda = null;
let timerIndicador = null;
let debugAtivo = false;
let blocosRecebidos = 0;

// Microfone usado pela voz do jogo (descoberto por calibração e salvo)
let micSalvo = lerMicSalvo();   // { deviceId, label, indiceJogo }
let indiceJogo = null;          // profile_voiceInputDevice do jogo
let vozJogo = false;            // jogador transmitindo voz no jogo agora
let calibracao = null;
let trocarAposGravacao = false;

function log(...partes) {
    if (debugAtivo) post('log', { mensagem: partes.map(String).join(' ') });
}

function lerMicSalvo() {
    try {
        return JSON.parse(localStorage.getItem(CHAVE_MIC)) || null;
    } catch {
        return null;
    }
}

function salvarMic(valor) {
    try {
        localStorage.setItem(CHAVE_MIC, JSON.stringify(valor));
    } catch {}
}

function comTimeout(promessa, ms, motivo) {
    return Promise.race([
        promessa,
        new Promise((_, rejeitar) => setTimeout(() => rejeitar(new Error(motivo)), ms)),
    ]);
}

// Não usa await: resume() pode ficar pendente para sempre se o navegador bloquear o áudio
function retomarAudio() {
    if (ctx && ctx.state === 'suspended') {
        ctx.resume().catch(() => {});
        setTimeout(() => { if (ctx && ctx.state !== 'running') log('AudioContext continua', ctx.state); }, 1000);
    }
}

function post(rota, dados = {}) {
    return fetch(`https://${RESOURCE}/${rota}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(dados),
    }).catch(() => {});
}

function setIndicador(estado, texto) {
    clearTimeout(timerIndicador);
    indicador.classList.remove('processando', 'falha');
    if (!estado || !mostrarIndicador) {
        indicador.classList.add('oculto');
        return;
    }
    if (estado !== 'gravando') indicador.classList.add(estado);
    indicadorTexto.textContent = texto;
    indicador.classList.remove('oculto');
}

function atualizarIndicador() {
    if (gravacao) setIndicador('gravando', 'Gravando...');
    else if (pendentes > 0) setIndicador('processando', 'Transcrevendo...');
    else setIndicador(null);
}

function mostrarLegenda(texto, tempo) {
    clearTimeout(timerLegenda);
    legenda.textContent = texto;
    legenda.classList.remove('oculto');
    timerLegenda = setTimeout(() => legenda.classList.add('oculto'), tempo);
}

function volume(bloco) {
    let soma = 0;
    for (let i = 0; i < bloco.length; i++) soma += bloco[i] * bloco[i];
    return Math.sqrt(soma / bloco.length);
}

function aoReceberAudio(evento) {
    blocosRecebidos++;
    const bloco = new Float32Array(evento.inputBuffer.getChannelData(0));
    const nivel = volume(bloco);
    const temVoz = nivel > Math.max(LIMIAR_MIN, ruido * 3);

    if (gravacao) {
        gravacao.pedacos.push(bloco);
        gravacao.vozes.push(temVoz);
        gravacao.amostras += bloco.length;
        return;
    }

    // ruído de fundo: desce rápido e sobe devagar (assim a fala não "vira" ruído)
    ruido = nivel < ruido ? ruido * 0.9 + nivel * 0.1 : ruido * 0.995 + nivel * 0.005;

    preRoll.push(bloco);
    preRollVoz.push(temVoz);
    preRollAmostras += bloco.length;
    const limite = (preRollMs / 1000) * ctx.sampleRate;
    while (preRoll.length > 1 && preRollAmostras - preRoll[0].length >= limite) {
        preRollAmostras -= preRoll.shift().length;
        preRollVoz.shift();
    }
}

// Corta o silêncio do começo e do fim (mantendo MARGEM_MS) e diz quanto é voz.
function recortarFala(g) {
    const n = g.pedacos.length;
    if (n === 0) return null;
    const msPorPedaco = (g.pedacos[0].length / ctx.sampleRate) * 1000;
    let primeiro = -1, ultimo = -1, comVoz = 0;
    for (let i = 0; i < n; i++) {
        if (!g.vozes[i]) continue;
        comVoz++;
        if (primeiro < 0) primeiro = i;
        ultimo = i;
    }
    const vozMs = comVoz * msPorPedaco;
    if (primeiro < 0) return { vozMs, pedacos: [], amostras: 0 };

    const margem = Math.ceil(MARGEM_MS / msPorPedaco);
    const pedacos = g.pedacos.slice(Math.max(0, primeiro - margem), Math.min(n, ultimo + margem + 1));
    const amostras = pedacos.reduce((t, p) => t + p.length, 0);
    return { vozMs, pedacos, amostras };
}

function microfoneAberto() {
    return ctx && stream && stream.getAudioTracks().some((t) => t.readyState === 'live');
}

function deviceIdAtual() {
    const faixa = stream && stream.getAudioTracks()[0];
    return faixa ? faixa.getSettings().deviceId : null;
}

function pedirMicrofone(deviceId) {
    const audio = {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
    };
    if (deviceId) audio.deviceId = { exact: deviceId };
    return comTimeout(navigator.mediaDevices.getUserMedia({ audio }), 8000, 'getUserMedia não respondeu');
}

async function abrirMicrofone() {
    if (microfoneAberto()) {
        retomarAudio();
        return;
    }
    if (abrindo) return abrindo;

    abrindo = (async () => {
        log('abrindo microfone...');
        try {
            stream = await pedirMicrofone(micSalvo && micSalvo.deviceId);
        } catch (err) {
            if (!micSalvo) throw err;
            // o navegador do FiveM pode trocar o id do dispositivo entre sessões; abre o
            // padrão por enquanto e verificarMicrofone() reencontra o salvo pelo nome
            log('microfone salvo não abriu pelo id:', micSalvo.label, '-', err.name || err.message);
            stream = await pedirMicrofone(null);
        }
        const faixa = stream.getAudioTracks()[0];
        log('microfone aberto:', faixa ? faixa.label : '(sem faixa)');

        ctx = new (window.AudioContext || window.webkitAudioContext)();
        const fonte = ctx.createMediaStreamSource(stream);
        const processador = ctx.createScriptProcessor(4096, 1, 1);
        const mudo = ctx.createGain();
        mudo.gain.value = 0; // precisa chegar no destino para processar, mas sem tocar nada
        processador.onaudioprocess = aoReceberAudio;
        fonte.connect(processador);
        processador.connect(mudo);
        mudo.connect(ctx.destination);
        log('AudioContext', ctx.state, ctx.sampleRate + ' Hz');
        retomarAudio();
    })();

    try {
        await abrindo;
    } finally {
        abrindo = null;
    }
}

function fecharMicrofone() {
    if (stream) stream.getTracks().forEach((t) => t.stop());
    if (ctx) ctx.close().catch(() => {});
    stream = null;
    ctx = null;
    preRoll = [];
    preRollAmostras = 0;
}

async function trocarMicrofone() {
    if (gravacao) {
        trocarAposGravacao = true;
        return;
    }
    trocarAposGravacao = false;
    fecharMicrofone();
    try {
        await abrirMicrofone();
    } catch (err) {
        post('erro', { motivo: 'microfone', detalhe: String(err) });
    }
}

// ---------------------------------------------------------------------------
// Calibração: descobre qual microfone é o da voz do jogo.
// Abre todos os microfones ao mesmo tempo e compara o volume de cada um quando o
// jogo diz que o jogador está falando contra quando está calado. O microfone em
// que a pessoa fala tem a maior diferença (relação fala/ruído).
// ---------------------------------------------------------------------------

const AMOSTRAS_FALA_NECESSARIAS = 40; // x 50 ms = 2 s de fala
const AMOSTRAS_RUIDO_NECESSARIAS = 10;
const RELACAO_MINIMA = 1.5;

function rms(buf) {
    let soma = 0;
    for (let i = 0; i < buf.length; i++) soma += buf[i] * buf[i];
    return Math.sqrt(soma / buf.length);
}

async function listarMicrofones() {
    const lista = await navigator.mediaDevices.enumerateDevices();
    // 'default' e 'communications' são apelidos de outros dispositivos da lista
    return lista.filter((d) => d.kind === 'audioinput' && d.deviceId !== 'default' && d.deviceId !== 'communications');
}

function escolherMicrofone(disp, motivo) {
    micSalvo = { deviceId: disp.deviceId, label: disp.label, indiceJogo };
    salvarMic(micSalvo);
    post('microfone', { label: disp.label, motivo });
    if (deviceIdAtual() !== disp.deviceId) trocarMicrofone();
}

function encerrarCalibracao() {
    if (!calibracao) return;
    clearInterval(calibracao.timer);
    calibracao.medidores.forEach((m) => m.stream.getTracks().forEach((t) => t.stop()));
    calibracao.actx.close().catch(() => {});
    calibracao = null;
}

function medirCalibracao() {
    const c = calibracao;
    for (const m of c.medidores) {
        m.an.getFloatTimeDomainData(m.buf);
        const r = rms(m.buf);
        if (vozJogo) {
            m.fala += r;
            m.nFala++;
        } else {
            m.ruido += r;
            m.nRuido++;
        }
    }
    if (vozJogo) c.amostrasFala++;

    const ruidoSuficiente = c.medidores.every((m) => m.nRuido >= AMOSTRAS_RUIDO_NECESSARIAS);
    if (c.amostrasFala < AMOSTRAS_FALA_NECESSARIAS || !ruidoSuficiente) return;

    const notas = c.medidores.map((m) => ({
        m,
        relacao: (m.fala / m.nFala) / Math.max(m.ruido / m.nRuido, 1e-4),
    })).sort((a, b) => b.relacao - a.relacao);

    log('calibração:', notas.map((n) => `${n.m.disp.label}=${n.relacao.toFixed(2)}`).join(' | '));

    if (notas[0].relacao < RELACAO_MINIMA) {
        // nenhum microfone reagiu claramente à fala: mede de novo
        c.medidores.forEach((m) => { m.fala = 0; m.nFala = 0; });
        c.amostrasFala = 0;
        return;
    }

    const melhor = notas[0].m.disp;
    encerrarCalibracao();
    escolherMicrofone(melhor, 'calibrado');
}

async function iniciarCalibracao() {
    if (calibracao) return;
    let dispositivos;
    try {
        dispositivos = await listarMicrofones();
    } catch (err) {
        log('não foi possível listar microfones:', err.message);
        return;
    }

    if (dispositivos.length === 0) return;
    if (dispositivos.length === 1) {
        escolherMicrofone(dispositivos[0], 'único microfone');
        return;
    }

    const actx = new (window.AudioContext || window.webkitAudioContext)();
    const medidores = [];
    for (const disp of dispositivos) {
        try {
            const s = await comTimeout(navigator.mediaDevices.getUserMedia({
                audio: {
                    deviceId: { exact: disp.deviceId },
                    // sem processamento: o ganho automático esconderia a diferença entre os microfones
                    echoCancellation: false,
                    noiseSuppression: false,
                    autoGainControl: false,
                },
            }), 5000, 'timeout');
            const an = actx.createAnalyser();
            an.fftSize = 2048;
            actx.createMediaStreamSource(s).connect(an);
            medidores.push({ disp, stream: s, an, buf: new Float32Array(an.fftSize), fala: 0, nFala: 0, ruido: 0, nRuido: 0 });
        } catch (err) {
            log('não abriu', disp.label, '-', err.message);
        }
    }

    if (medidores.length === 0) {
        actx.close().catch(() => {});
        return;
    }
    if (medidores.length === 1) {
        medidores[0].stream.getTracks().forEach((t) => t.stop());
        actx.close().catch(() => {});
        escolherMicrofone(medidores[0].disp, 'único microfone disponível');
        return;
    }

    actx.resume().catch(() => {});
    calibracao = { actx, medidores, amostrasFala: 0, timer: setInterval(medirCalibracao, 50) };
    log(`calibrando entre ${medidores.length} microfones (fale no jogo por ~2 s)...`);
}

async function verificarMicrofone() {
    try {
        await abrirMicrofone(); // garante a permissão (sem ela a lista vem sem nomes)
    } catch (err) {
        post('erro', { motivo: 'microfone', detalhe: String(err) });
        return;
    }

    if (micSalvo && micSalvo.indiceJogo === indiceJogo) {
        const lista = await listarMicrofones();
        const disp = lista.find((d) => d.deviceId === micSalvo.deviceId)
            || lista.find((d) => d.label && d.label === micSalvo.label);
        if (disp) {
            if (disp.deviceId !== micSalvo.deviceId) {
                log('microfone salvo reencontrado pelo nome:', disp.label);
                micSalvo.deviceId = disp.deviceId;
                salvarMic(micSalvo);
            }
            if (deviceIdAtual() !== disp.deviceId) trocarMicrofone();
            log('usando microfone salvo:', micSalvo.label);
            return;
        }
        log('microfone salvo não está conectado:', micSalvo.label);
    }
    iniciarCalibracao();
}

// ---------------------------------------------------------------------------
// Conversão para WAV
// ---------------------------------------------------------------------------

function juntar(pedacos, total) {
    const saida = new Float32Array(total);
    let pos = 0;
    for (const p of pedacos) {
        saida.set(p, pos);
        pos += p.length;
    }
    return saida;
}

function reamostrar(entrada, taxaEntrada, taxaSaida) {
    if (taxaEntrada === taxaSaida) return entrada;
    const razao = taxaEntrada / taxaSaida;
    const tamanho = Math.floor(entrada.length / razao);
    const saida = new Float32Array(tamanho);
    for (let i = 0; i < tamanho; i++) {
        // média das amostras do intervalo (filtro passa-baixa simples)
        const ini = Math.floor(i * razao);
        const fim = Math.min(entrada.length, Math.floor((i + 1) * razao));
        let soma = 0;
        for (let j = ini; j < fim; j++) soma += entrada[j];
        saida[i] = soma / Math.max(1, fim - ini);
    }
    return saida;
}

function codificarWav(amostras, taxa) {
    const buffer = new ArrayBuffer(44 + amostras.length * 2);
    const v = new DataView(buffer);
    const texto = (pos, s) => { for (let i = 0; i < s.length; i++) v.setUint8(pos + i, s.charCodeAt(i)); };

    texto(0, 'RIFF');
    v.setUint32(4, 36 + amostras.length * 2, true);
    texto(8, 'WAVE');
    texto(12, 'fmt ');
    v.setUint32(16, 16, true);       // tamanho do bloco fmt
    v.setUint16(20, 1, true);        // PCM
    v.setUint16(22, 1, true);        // mono
    v.setUint32(24, taxa, true);
    v.setUint32(28, taxa * 2, true); // bytes por segundo
    v.setUint16(32, 2, true);        // bytes por amostra
    v.setUint16(34, 16, true);       // bits por amostra
    texto(36, 'data');
    v.setUint32(40, amostras.length * 2, true);

    let pos = 44;
    for (let i = 0; i < amostras.length; i++, pos += 2) {
        const s = Math.max(-1, Math.min(1, amostras[i]));
        v.setInt16(pos, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    return new Uint8Array(buffer);
}

function paraBase64(bytes) {
    let binario = '';
    const passo = 0x8000;
    for (let i = 0; i < bytes.length; i += passo) {
        binario += String.fromCharCode.apply(null, bytes.subarray(i, i + passo));
    }
    return btoa(binario);
}

// ---------------------------------------------------------------------------
// Gravação
// ---------------------------------------------------------------------------

async function iniciar(opcoes) {
    if (gravacao) return;
    pararSolicitado = false;
    mostrarIndicador = opcoes.mostrarIndicador !== false;
    preRollMs = opcoes.preRollMs ?? 500;
    minFalaMs = opcoes.minFalaMs ?? 350;
    setIndicador('gravando', 'Gravando...');

    try {
        await abrirMicrofone();
    } catch (err) {
        log('erro no microfone:', err && err.message ? err.message : err);
        setIndicador('falha', 'Microfone indisponível');
        timerIndicador = setTimeout(atualizarIndicador, 2500);
        post('erro', { motivo: 'microfone', detalhe: String(err) });
        return;
    }

    // Soltou/parou de falar antes do microfone abrir
    if (pararSolicitado) {
        atualizarIndicador();
        post('descartado');
        return;
    }

    gravacao = {
        pedacos: preRoll,
        vozes: preRollVoz,
        amostras: preRollAmostras,
        inicio: performance.now(),
        timerMax: setTimeout(parar, Math.max(1, opcoes.maxSegundos || 15) * 1000),
    };
    preRoll = [];
    preRollVoz = [];
    preRollAmostras = 0;
    atualizarIndicador();
}

function parar() {
    pararSolicitado = true;
    if (!gravacao) return;

    const g = gravacao;
    gravacao = null;
    clearTimeout(g.timerMax);

    const duracao = performance.now() - g.inicio;
    log(`fim da gravação: ${Math.round(duracao)} ms, ${g.amostras} amostras, ${blocosRecebidos} blocos de áudio desde o início, AudioContext ${ctx && ctx.state}`);

    const fala = ctx && g.amostras > 0 ? recortarFala(g) : null;

    if (duracao < MIN_MS || !fala || fala.vozMs < minFalaMs) {
        if (fala) log(`descartado: só ${Math.round(fala.vozMs)} ms de voz (mínimo ${minFalaMs} ms)`);
        atualizarIndicador();
        post('descartado');
    } else {
        try {
            const pcm = reamostrar(juntar(fala.pedacos, fala.amostras), ctx.sampleRate, TAXA_SAIDA);
            const audio = paraBase64(codificarWav(pcm, TAXA_SAIDA));
            log(`enviando ${Math.round(fala.amostras / ctx.sampleRate * 1000)} ms (de ${Math.round(g.amostras / ctx.sampleRate * 1000)} ms gravados), ${Math.round(fala.vozMs)} ms de voz`);
            pendentes++;
            atualizarIndicador();
            post('audio', { audio, mime: 'audio/wav', duracao: Math.round(duracao) });
        } catch (err) {
            atualizarIndicador();
            post('erro', { motivo: 'conversao', detalhe: String(err) });
        }
    }

    if (trocarAposGravacao) trocarMicrofone();
}

window.addEventListener('message', (event) => {
    const d = event.data || {};
    switch (d.acao) {
        case 'preparar':
            debugAtivo = d.debug === true;
            preRollMs = d.preRollMs ?? preRollMs;
            indiceJogo = d.indiceJogo ?? null;
            verificarMicrofone();
            break;
        case 'vozJogo':
            vozJogo = d.falando === true;
            break;
        case 'indiceJogo':
            // jogador trocou o microfone nas configurações do jogo: descobre de novo
            indiceJogo = d.indice ?? null;
            log('microfone do jogo alterado, recalibrando');
            encerrarCalibracao();
            iniciarCalibracao();
            break;
        case 'iniciar':
            debugAtivo = d.debug === true;
            iniciar(d);
            break;
        case 'parar':
            parar();
            break;
        case 'resultado':
            pendentes = Math.max(0, pendentes - 1);
            atualizarIndicador();
            if (d.mostrar && d.texto) mostrarLegenda(d.texto, d.tempo || 6000);
            break;
        case 'falha':
            pendentes = Math.max(0, pendentes - 1);
            if (d.silenciosa) {
                atualizarIndicador();
                break;
            }
            setIndicador('falha', d.mensagem || 'Falha na transcrição');
            timerIndicador = setTimeout(atualizarIndicador, 2500);
            break;
    }
});
