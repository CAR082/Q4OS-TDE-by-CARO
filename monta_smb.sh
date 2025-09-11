#!/bin/bash
set -e

# Verifica se está como root
if [[ $EUID -ne 0 ]]; then
  zenity --error --text="Este script precisa ser executado como root (use sudo)." --width=300
  exit 1
fi

# Usuário real
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$USER_NAME")

# Desktop do usuário real
DESKTOP="$USER_HOME/Desktop"
REDE="$DESKTOP/Rede"
mkdir -p "$REDE"
chown "$USER_NAME:$USER_NAME" "$REDE"

# Detecta IP local e sub-rede
LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
SUBNET=$(echo "$LOCAL_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

(
  echo "5"; sleep 1
  echo "# Escaneando a rede: $SUBNET para hosts SMB ativos..."
  TMP_SCAN_FILE="/tmp/hosts_scan.txt"
  > "$TMP_SCAN_FILE"
  
  HOSTS=$(nmap -p445 --open -oG - "$SUBNET" | awk '/Up$/{print $2}')
  TOTAL=$(echo "$HOSTS" | wc -l)
  COUNT=0

  for IP in $HOSTS; do
    COUNT=$((COUNT + 1))
    PERCENT=$((5 + (COUNT * 90 / TOTAL)))
    echo "# Consultando nome NetBIOS em $IP..."
    NB_NAME=$(nmblookup -A "$IP" 2>/dev/null | awk '/<00>.*<ACTIVE>/ {print $1; exit}')
    if [[ -n "$NB_NAME" ]]; then
      echo "$IP $NB_NAME" >> "$TMP_SCAN_FILE"
    else
      echo "$IP" >> "$TMP_SCAN_FILE"
    fi
    echo "$PERCENT"
    sleep 1
  done
  echo 100
) | zenity --progress --title="Escaneando rede" --auto-close --width=400

# Carrega hosts
mapfile -t HOSTS < <(awk '/^[0-9]+\.[0-9]+\.[0-9]+/ {if(NF>=2) print $2 " (" $1 ")"; else print $1}' /tmp/hosts_scan.txt)
[[ ${#HOSTS[@]} -eq 0 ]] && { zenity --error --text="Nenhum host SMB encontrado." --width=300; exit 1; }

# Escolhe host
LIST_ITEMS=()
for i in "${!HOSTS[@]}"; do
  HOST_IP=$(echo "${HOSTS[$i]}" | sed -n 's/.*(\(.*\)).*/\1/p')
  [[ -z "$HOST_IP" ]] && HOST_IP="${HOSTS[$i]}"
  if [[ "$HOST_IP" == "$LOCAL_IP" ]]; then
    LIST_ITEMS+=("$((i+1))" "${HOSTS[$i]} ← ESTE COMPUTADOR")
  else
    LIST_ITEMS+=("$((i+1))" "${HOSTS[$i]}")
  fi
done

CHOICE=$(zenity --list --title="Computadores encontrados" --text="Escolha o computador:" \
  --column="Nº" --column="Nome" "${LIST_ITEMS[@]}" --height=350 --width=600)
[[ -z "$CHOICE" ]] && exit 0
INDEX=$((CHOICE-1))
SELECTED="${HOSTS[$INDEX]}"
HOST=$(echo "$SELECTED" | sed -n 's/.*(\(.*\)).*/\1/p')
[[ -z "$HOST" ]] && HOST="$SELECTED"

# Credenciais SMB
USERNAME=$(zenity --entry --title="Usuário Windows" --text="Digite o nome de usuário (vazio = convidado):" --width=400)
[[ -n "$USERNAME" ]] && PASSWORD=$(zenity --password --title="Senha" --text="Digite a senha:" --width=400) || PASSWORD=""

# Lista compartilhamentos
SHARES_RAW=$(smbclient -L //$HOST -U "$USERNAME%$PASSWORD" 2>/dev/null | awk '/Disk/ {print $1}' | grep -v '^IPC\$')
[[ -z "$SHARES_RAW" ]] && { zenity --error --text="Nenhum compartilhamento encontrado." --width=300; exit 1; }

# Monta arrays com labels
SHARE_ARRAY=()
DISPLAY_ARRAY=()

while read -r share; do
  LABEL="$share"
  if [[ "$share" =~ \$ ]]; then
    if [[ "$share" =~ ^[A-Z]\$$ ]]; then
      LABEL="$share (Compartilhamento de unidade → Administrativo)"
    elif [[ "$share" =~ ^ADMIN ]]; then
      LABEL="$share (Administração remota)"
    else
      LABEL="$share (Compartilhamento oculto)"
    fi
  elif [[ "$share" =~ ^Users$|^Home$|^Profiles$ ]]; then
    LABEL="$share (Pastas de usuários)"
  else
    LABEL="$share (Pasta compartilhada normal)"
  fi
  SHARE_ARRAY+=("$share")
  DISPLAY_ARRAY+=("$LABEL")
done <<< "$SHARES_RAW"

# Lista formatada para Zenity
LIST_SHARES=()
for i in "${!DISPLAY_ARRAY[@]}"; do
  LIST_SHARES+=("$((i+1))" "${DISPLAY_ARRAY[$i]}")
done

SHARE_CHOICE=$(zenity --list --title="Compartilhamentos" --text="Escolha o compartilhamento:" \
  --column="Nº" --column="Compartilhamento" "${LIST_SHARES[@]}" --height=350 --width=600)
[[ -z "$SHARE_CHOICE" ]] && exit 0
INDEX_SHARE=$((SHARE_CHOICE-1))
SHARE="${SHARE_ARRAY[$INDEX_SHARE]}"

# Monta compartilhamento na pasta Rede do usuário
MOUNT_POINT="$REDE/$SHARE"
mkdir -p "$MOUNT_POINT"
chown "$USER_NAME:$USER_NAME" "$MOUNT_POINT"

SUCCESS=0
for vers in 3.1.1 3.0 2.1 2.0 1.0; do
  if [[ -n "$USERNAME" ]]; then
    mount -t cifs "//$HOST/$SHARE" "$MOUNT_POINT" \
      -o username=$USERNAME,password=$PASSWORD,uid=$(id -u "$USER_NAME"),gid=$(id -g "$USER_NAME"),vers=$vers 2>/tmp/mount_error && SUCCESS=1 && break
  else
    mount -t cifs "//$HOST/$SHARE" "$MOUNT_POINT" \
      -o guest,uid=$(id -u "$USER_NAME"),gid=$(id -g "$USER_NAME"),vers=$vers 2>/tmp/mount_error && SUCCESS=1 && break
  fi
done

if [[ $SUCCESS -ne 1 ]]; then
  zenity --error --text="Falha ao montar o compartilhamento. Veja detalhes em /tmp/mount_error" --width=400
  exit 1
fi


# Adiciona ao fstab apenas se montou com sucesso
if [[ $SUCCESS -eq 1 ]]; then
  grep -q "^//$HOST/$SHARE " /etc/fstab || \
  echo "//$HOST/$SHARE $MOUNT_POINT cifs username=$USERNAME,password=$PASSWORD,uid=$(id -u "$USER_NAME"),gid=$(id -g "$USER_NAME"),vers=$vers 0 0" >> /etc/fstab
  zenity --info --text="Compartilhamento '$SHARE' montado em $MOUNT_POINT." --width=400
else
  zenity --error --text="Falha ao montar o compartilhamento. Veja detalhes em /tmp/mount_error" --width=400
  exit 1
fi
