#!/bin/bash
set -e

# --- Verificações iniciais ---
if [[ $EUID -ne 0 ]]; then
  zenity --error --text="Este script precisa ser executado como root (use sudo)." --width=350
  exit 1
fi

for cmd in nmap smbclient mount.cifs; do
  if ! command -v "${cmd%%.*}" >/dev/null 2>&1 && ! command -v "$cmd" >/dev/null 2>&1; then
    zenity --error --text="Comando obrigatório não encontrado: $cmd\nInstale nmap, smbclient e cifs-utils." --width=400
    exit 1
  fi
done

# Usuário real (quem chamou sudo)
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$USER_NAME")

DESKTOP="$USER_HOME/Desktop"
REDE="$DESKTOP/Rede"
mkdir -p "$REDE"
chown "$USER_NAME:$USER_NAME" "$REDE"

# Detecta IP local (IPv4) e sub-rede /24
LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
if [[ -z "$LOCAL_IP" ]]; then
  zenity --error --text="Não consegui detectar IP local." --width=350
  exit 1
fi
SUBNET=$(echo "$LOCAL_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

# --- Escaneia rede para hosts com SMB (porta 445) ---
TMP_SCAN_FILE="/tmp/hosts_scan.txt"
> "$TMP_SCAN_FILE"

(
  echo "5"; sleep 1
  echo "# Escaneando $SUBNET por hosts SMB..."
  HOSTS=""
  if command -v nmap >/dev/null 2>&1; then
    HOSTS=$(nmap -p445 --open -oG - "$SUBNET" 2>/dev/null | awk '/Up$/{print $2}')
  fi

  # fallback simples se nmap não retornar nada
  if [[ -z "$HOSTS" ]]; then
    for i in $(seq 1 254); do
      IP=$(echo "$SUBNET" | sed 's/0\/24$/'"$i"'/')
      ping -c1 -W1 "$IP" >/dev/null 2>&1 && echo "$IP" >> "$TMP_SCAN_FILE"
    done
    HOSTS=$(awk '{print $1}' "$TMP_SCAN_FILE")
  fi

  TOTAL=$(echo "$HOSTS" | wc -w)
  COUNT=0
  for IP in $HOSTS; do
    COUNT=$((COUNT + 1))
    PERCENT=$((5 + (COUNT * 90 / (TOTAL == 0 ? 1 : TOTAL))))
    echo "# Consultando NetBIOS em $IP..."
    NB_NAME=""
    if command -v nmblookup >/dev/null 2>&1; then
      NB_NAME=$(nmblookup -A "$IP" 2>/dev/null | awk '/<00>/{print $1; exit}' || true)
    fi
    # fallback: tentar smbclient -L com guest (-N) e tentar extrair um nome simples
    if [[ -z "$NB_NAME" ]] && command -v smbclient >/dev/null 2>&1; then
      NB_NAME=$(smbclient -L "//$IP" -N 2>/dev/null | awk -F' ' '/Server/{print $2; exit}' || true)
    fi

    if [[ -n "$NB_NAME" ]]; then
      echo "$IP $NB_NAME" >> "$TMP_SCAN_FILE"
    else
      echo "$IP" >> "$TMP_SCAN_FILE"
    fi
    echo "$PERCENT"
    sleep 0.6
  done
  echo 100
) | zenity --progress --title="Escaneando rede" --auto-close --width=420

# Carrega hosts para seleção
mapfile -t HOSTS < <(awk '/^[0-9]+\.[0-9]+\.[0-9]+/ {if(NF>=2) print $2 " (" $1 ")"; else print $1}' "$TMP_SCAN_FILE")
[[ ${#HOSTS[@]} -eq 0 ]] && { zenity --error --text="Nenhum host SMB encontrado." --width=300; exit 1; }

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

# Credenciais SMB (vazio = guest)
USERNAME=$(zenity --entry --title="Usuário Windows" --text="Digite o nome de usuário (vazio = convidado):" --width=420)
if [[ -n "$USERNAME" ]]; then
  PASSWORD=$(zenity --password --title="Senha" --text="Digite a senha:" --width=420)
fi

# Lista compartilhamentos
SMB_ERRORS="/tmp/smb_list_errors.$$"
if [[ -n "$USERNAME" ]]; then
  # Pegando toda a coluna do nome do compartilhamento antes da palavra "Disk" para respeitar espaços
  SHARES_RAW=$(smbclient -L "//$HOST" -U "$USERNAME%$PASSWORD" 2>"$SMB_ERRORS" | awk '/Disk/{print substr($0,1,index($0,"Disk")-2)}' | grep -v '^IPC\$' || true)
else
  SHARES_RAW=$(smbclient -L "//$HOST" -N 2>"$SMB_ERRORS" | awk '/Disk/{print substr($0,1,index($0,"Disk")-2)}' | grep -v '^IPC\$' || true)
fi

if [[ -z "$SHARES_RAW" ]]; then
  err=$(<"$SMB_ERRORS")
  zenity --error --text="Nenhum compartilhamento encontrado ou erro na listagem.\n\nDetalhes:\n${err}" --width=500
  rm -f "$SMB_ERRORS"
  exit 1
fi
rm -f "$SMB_ERRORS"


# Monta arrays com labels (respeitando nomes com espaços/acentos)
SHARE_ARRAY=()
DISPLAY_ARRAY=()
while IFS= read -r share; do
  share=$(echo "$share" | tr -d '\t' | sed -E 's/^ +//; s/ +$//')

  LABEL="$share"
  if [[ "$share" =~ \$ ]]; then
    if [[ "$share" =~ ^[A-Z]\$$ ]]; then
      LABEL="$share (Unidade administrativa)"
    else
      LABEL="$share (Oculto/Administrativo)"
    fi
  elif [[ "$share" =~ ^Users$|^Home$|^Profiles$ ]]; then
    LABEL="$share (Pastas de usuários)"
  else
    LABEL="$share (Pasta compartilhada)"
  fi
  SHARE_ARRAY+=("$share")
  DISPLAY_ARRAY+=("$LABEL")
done <<< "$SHARES_RAW"

LIST_SHARES=()
for i in "${!DISPLAY_ARRAY[@]}"; do
  LIST_SHARES+=("$((i+1))" "${DISPLAY_ARRAY[$i]}")
done

SHARE_CHOICE=$(zenity --list --title="Compartilhamentos" --text="Escolha o compartilhamento:" \
  --column="Nº" --column="Compartilhamento" "${LIST_SHARES[@]}" --height=350 --width=700)
[[ -z "$SHARE_CHOICE" ]] && exit 0
INDEX_SHARE=$((SHARE_CHOICE-1))
SHARE="${SHARE_ARRAY[$INDEX_SHARE]}"

# --- Montagem corrigida ---
MOUNT_POINT="$REDE/$SHARE"
mkdir -p "$MOUNT_POINT"
chown "$USER_NAME:$USER_NAME" "$MOUNT_POINT"

FSTAB_SHARE=$(printf '%s' "$SHARE" | sed -e 's/ /\\040/g')

SUCCESS=0
VERSIONS=("3.1.1" "3.0" "2.1" "2.0" "1.0")

for vers in "${VERSIONS[@]}"; do
  if [[ -n "$USERNAME" ]]; then
    CMD=(mount -t cifs "//${HOST}/${SHARE}" "$MOUNT_POINT" \
      -o "username=${USERNAME},password=${PASSWORD},vers=${vers},iocharset=utf8,uid=$(id -u "$USER_NAME"),gid=$(id -g "$USER_NAME")")
  else
    CMD=(mount -t cifs "//${HOST}/${SHARE}" "$MOUNT_POINT" \
      -o "guest,vers=${vers},iocharset=utf8,uid=$(id -u "$USER_NAME"),gid=$(id -g "$USER_NAME")")
  fi

  if "${CMD[@]}" 2>/tmp/mount_error; then
    SUCCESS=1
    break
  fi
done

if [[ $SUCCESS -ne 1 ]]; then
  ERR_MSG=$(<"/tmp/mount_error")
  zenity --error --text="Falha ao montar '$SHARE'.\nDetalhes:\n$ERR_MSG" --width=500
  exit 1
fi

# Adiciona no fstab se não existir
FSTAB_SRC="//$HOST/$FSTAB_SHARE"
if ! grep -Fq "$FSTAB_SRC $MOUNT_POINT" /etc/fstab; then
  if [[ -n "$USERNAME" ]]; then
    FSTAB_OPTS="username=${USERNAME},password=${PASSWORD},vers=${vers},iocharset=utf8,uid=$(id -u "$USER_NAME"),gid=$(id -g "$USER_NAME")"
  else
    FSTAB_OPTS="guest,vers=${vers},iocharset=utf8,uid=$(id -u "$USER_NAME"),gid=$(id -g "$USER_NAME")"
  fi
  printf '%s\n' "$FSTAB_SRC $MOUNT_POINT cifs $FSTAB_OPTS 0 0" >> /etc/fstab
fi

zenity --info --text="Compartilhamento '$SHARE' montado em:\n$MOUNT_POINT" --width=420
exit 0
