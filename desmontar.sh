#!/bin/bash
set -e

# Verifica root
if [[ $EUID -ne 0 ]]; then
  zenity --error --text="Este script precisa ser executado como root (use sudo)." --width=300
  exit 1
fi

# Usuário real
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$USER_NAME")

# Captura pontos de montagem CIFS reais
mapfile -t MOUNTED < <(mount | grep "type cifs" | awk '{print $3}')
[[ ${#MOUNTED[@]} -eq 0 ]] && { zenity --info --text="Nenhum compartilhamento CIFS montado encontrado." --width=300; exit 0; }

# Monta lista para Zenity
LIST_ITEMS=()
for i in "${!MOUNTED[@]}"; do
  LIST_ITEMS+=("$((i+1))" "${MOUNTED[$i]}")
done

CHOICE=$(zenity --list --title="Compartilhamentos montados" --text="Escolha o compartilhamento para desmontar:" \
  --column="Nº" --column="Montagem" "${LIST_ITEMS[@]}" --height=350 --width=600)
[[ -z "$CHOICE" ]] && exit 0

INDEX=$((CHOICE-1))
MOUNT_POINT="${MOUNTED[$INDEX]}"

# Descobre host/share a partir do /etc/mtab
HOST_SHARE=$(grep " $MOUNT_POINT " /etc/mtab | awk '{print $1}' | sed 's|^//||')
HOST=$(echo "$HOST_SHARE" | cut -d'/' -f1)
SHARE=$(echo "$HOST_SHARE" | cut -d'/' -f2-)

# Desmonta
umount "$MOUNT_POINT" 2>/tmp/umount_error || { zenity --error --text="Falha ao desmontar. Veja detalhes em /tmp/umount_error" --width=400; exit 1; }

# Remove entrada do fstab
ENTRY=$(grep " $MOUNT_POINT " /etc/fstab || true)
[[ -n "$ENTRY" ]] && sed -i "\|$ENTRY|d" /etc/fstab

# Remove diretório se estiver vazio
rmdir "$MOUNT_POINT" 2>/dev/null || true

# Tenta desmontar também do KDE/GVFS (system:/media/...)
if command -v kioclient5 &>/dev/null; then
  kioclient5 unmount "smb://$HOST/$SHARE" 2>/dev/null || true
fi
if command -v gvfs-mount &>/dev/null; then
  gvfs-mount -u "smb://$HOST/$SHARE" 2>/dev/null || true
fi

zenity --info --text="Compartilhamento desmontado com sucesso: $MOUNT_POINT (//$HOST/$SHARE)" --width=450
