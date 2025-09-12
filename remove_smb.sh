#!/bin/bash
# Script para remover compartilhamento Samba no Q4OS TDE
# Funciona via menu de contexto (pasta clicada)

PASTA="$1"

# Se não veio nada (script rodado direto)
if [ -z "$PASTA" ]; then
    PASTA=$(zenity --file-selection --directory --title="Selecione a pasta para remover compartilhamento")
    [ -z "$PASTA" ] && exit 0
fi

# Verifica se a pasta existe
if [ ! -d "$PASTA" ]; then
    zenity --error --text="A pasta '$PASTA' não existe!"
    exit 1
fi

# Lista todos os compartilhamentos no smb.conf que não sejam comentários
COMPARTILHAMENTOS=$(grep "^\[.*\]" /etc/samba/smb.conf | sed 's/^\[\(.*\)\]$/\1/')

# Verifica quais compartilhamentos apontam para a pasta clicada
MATCH=""
for SHARE in $COMPARTILHAMENTOS; do
    CAMINHO=$(grep -A5 "^\[$SHARE\]" /etc/samba/smb.conf | grep "path =" | awk -F'=' '{print $2}' | xargs)
    if [ "$CAMINHO" = "$PASTA" ]; then
        MATCH="$SHARE"
        break
    fi
done

# Se não encontrou nenhum
if [ -z "$MATCH" ]; then
    zenity --error --text="A pasta '$PASTA' não está compartilhada no Samba!"
    exit 1
fi

# Confirma remoção
zenity --question --text="Deseja remover o compartilhamento '$MATCH' da pasta:\n$PASTA ?"
[ $? -ne 0 ] && exit 0

# Remove o bloco correspondente de forma segura
sudo sed -i "/^\[$MATCH\]/,/^[[:space:]]*$/d" /etc/samba/smb.conf

# Reinicia o Samba
if command -v systemctl >/dev/null; then
    sudo systemctl restart smbd
else
    sudo service smbd restart
fi

# Mensagem de sucesso
zenity --info --text="Compartilhamento '$MATCH' (pasta $PASTA) removido com sucesso!"
