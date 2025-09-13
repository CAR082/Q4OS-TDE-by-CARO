#!/bin/bash
# Script para remover compartilhamento Samba no Q4OS TDE
# Funciona via menu de contexto (pasta clicada)
#Melhoria para funcionar com pastas com espaço no nome e com caracteres especiais , tipo cedilha

#para ver erros, caso necessário , basta descomentar os comentários
#USUARIO="${SUDO_USER:-$USER}"
#LOG="/home/$USUARIO/script_output.log"
#exec > >(tee -a "$LOG") 2>&1


PASTA="$1"

if [ -z "$PASTA" ]; then
    PASTA=$(zenity --file-selection --directory --title="Selecione a pasta para remover compartilhamento")
    [ -z "$PASTA" ] && exit 0
fi

if [ ! -d "$PASTA" ]; then
    zenity --error --text="A pasta '$PASTA' não existe!"
    exit 1
fi

# Busca os nomes dos compartilhamentos
COMPARTILHAMENTOS=$(grep "^\[.*\]" /etc/samba/smb.conf | sed 's/^\[\(.*\)\]$/\1/')

MATCH=""
while IFS= read -r SHARE; do
    CAMINHO=$(grep -A10 "^\[$SHARE\]" /etc/samba/smb.conf | grep "path =" | awk -F'=' '{print $2}' | xargs)
    if [ "$CAMINHO" = "$PASTA" ]; then
        MATCH="$SHARE"
        break
    fi
done <<< "$COMPARTILHAMENTOS"

if [ -z "$MATCH" ]; then
    zenity --error --text="A pasta '$PASTA' não está compartilhada no Samba!"
    exit 1
fi

zenity --question --text="Deseja remover o compartilhamento '$MATCH' da pasta:\n$PASTA ?"
[ $? -ne 0 ] && exit 0

# Escape para caracteres especiais no nome do compartilhamento
ESCAPED_MATCH=$(printf '%s\n' "$MATCH" | sed 's/[]\/$*.^[]/\\&/g')

sudo sed -i "/^\[$ESCAPED_MATCH\]/,/^\s*$/d" /etc/samba/smb.conf

if command -v systemctl >/dev/null; then
    sudo systemctl restart smbd
else
    sudo service smbd restart
fi

zenity --info --text="Compartilhamento '$MATCH' (pasta $PASTA) removido com sucesso!"
