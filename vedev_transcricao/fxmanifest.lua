fx_version 'cerulean'
game 'gta5'

name        'vedev_transcricao'
description 'Transforma a fala do jogador (microfone) em texto usando Whisper'
version     '1.0.0'
author      'VeDev'

client_scripts {
    'config.lua',
    'client/main.lua',
}

server_scripts {
    'config_servidor.js', -- contém a chave da API: só servidor, nunca em client_scripts/files
    'server/main.js',
    'server/config_falas.lua', -- frases e ações: só servidor
    'server/falas.lua',
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js',
}

lua54 'yes'
