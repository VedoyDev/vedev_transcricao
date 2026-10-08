// Configuração do SERVIDOR. Este arquivo roda só no servidor e nunca é enviado
// aos jogadores, por isso as chaves das APIs ficam aqui (e não no config.lua).
// NUNCA publique este arquivo com as suas chaves preenchidas.

globalThis.ConfigServidor = {
    // Motores de transcrição, em ordem de preferência. Se o primeiro recusar
    // (limite atingido, erro, fora do ar ou demorar demais), o mesmo áudio vai
    // para o próximo. Use `ativo: false` (ou deixe a chave/token vazio) para
    // desligar um deles. Veja MOTORES.md para comparar as opções.
    provedores: [
        {
            // Whisper rodando no próprio servidor (whisper.cpp).
            // Veja ferramentas/whisper. Grátis e sem limite; precisa de GPU para ser rápido.
            nome: 'Whisper local',
            ativo: false,
            tipo: 'openai',
            chave: '',
            endpoint: 'http://127.0.0.1:8000/v1/audio/transcriptions',
            modelo: 'large-v3-turbo',
        },
        {
            // Groq: https://console.groq.com/keys (plano grátis com limite diário)
            nome: 'Groq',
            ativo: true,
            tipo: 'openai', // qualquer API compatível com /v1/audio/transcriptions
            chave: '',      // gsk_...
            endpoint: 'https://api.groq.com/openai/v1/audio/transcriptions',
            modelo: 'whisper-large-v3-turbo',
        },
        {
            // Cloudflare Workers AI (plano grátis diário + pago por uso)
            nome: 'Cloudflare',
            ativo: true,
            tipo: 'cloudflare',
            contaId: '',    // Account ID (32 caracteres) - veja o README
            token: '',      // API Token com o modelo "Workers AI"
            modelo: '@cf/openai/whisper-large-v3-turbo',
        },
        {
            // Vosk no próprio servidor, só processador (ferramentas/vosk).
            // Leve, mas bem menos preciso que o Whisper com fala real (veja MOTORES.md).
            nome: 'Vosk local',
            ativo: false,
            tipo: 'openai',
            chave: '',
            endpoint: 'http://127.0.0.1:8001/v1/audio/transcriptions',
            modelo: 'vosk-model-small-pt-0.3',
        },
    ],

    // Idioma falado (código ISO-639-1). O Whisper não diferencia pt-BR de pt-PT;
    // use o `prompt` abaixo para puxar para o português do Brasil.
    idioma: 'pt',

    // Texto de contexto que o Whisper "lê" antes de cada áudio. Puxa a transcrição
    // para o português do Brasil e ajuda com gírias/nomes do servidor. Mantenha
    // curto e em forma de frase (lista de palavras soltas pode ser "copiada").
    prompt: 'Conversa informal em português do Brasil, num servidor de roleplay, com gírias como mano, tá ligado, parça e véi.',

    // Intervalo mínimo entre transcrições do mesmo jogador (ms).
    // Baixo de propósito: no modo automático as frases chegam uma atrás da outra.
    cooldownMs: 300,

    // Tamanho máximo do áudio recebido (KB)
    maxKb: 1024,

    // Imprime no console do servidor quem falou o quê (e qual motor transcreveu)
    debug: false,
};
