#!/bin/bash
# Script para compartilhar pasta via Samba no Q4OS TDE

# Seleciona a pasta se não foi passado argumento
if [ -z "$1" ]; then
    PASTA=$(zenity --file-selection --directory --title="Selecione a pasta para compartilhar")
    if [ -z "$PASTA" ]; then
        exit 0
    fi
else
    PASTA="$1"
fi

# Verifica se a pasta existe
if [ ! -d "$PASTA" ]; then
    zenity --error --text="Pasta $PASTA não existe!"
    exit 1
fi

# Usuário real (para force user)
REAL_USER=$(logname)

# Pergunta o nome do compartilhamento
NOME_COMPARTILHAMENTO=$(zenity --entry --text="Digite o nome do compartilhamento:" --entry-text "$(basename "$PASTA")")

# Se usuário cancelar
if [ -z "$NOME_COMPARTILHAMENTO" ]; then
    exit 0
fi

# Verifica se já existe no smb.conf
if grep -q "^\[$NOME_COMPARTILHAMENTO\]" /etc/samba/smb.conf; then
    zenity --warning --text="Um compartilhamento com este nome já existe!"
    exit 1
fi

# Adiciona entrada no smb.conf
sudo bash -c "cat >> /etc/samba/smb.conf <<EOF

[$NOME_COMPARTILHAMENTO]
   path = $PASTA
   read only = no
   browsable = yes
   guest ok = yes
   force user = $REAL_USER
EOF"

# Reinicia o serviço Samba
if command -v systemctl >/dev/null; then
    sudo systemctl restart smbd
else
    sudo service smbd restart
fi

# Mensagem de sucesso
zenity --info --text="Pasta $PASTA compartilhada como $NOME_COMPARTILHAMENTO com sucesso!"
