#!/bin/bash
set -e

# -----------------------------
# Verifica se está como root
# -----------------------------
if [[ $EUID -ne 0 ]]; then
  zenity --error --text="Este script precisa ser executado como root (use sudo)." --width=300
  exit 1
fi

# -----------------------------
# Usuário real e home
# -----------------------------
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$USER_NAME")

# -----------------------------
# Função: detectar Desktop do usuário
# -----------------------------
detect_desktop() {
  local user="$1"
  local home
  home=$(eval echo "~$user")

  # 1) tenta xdg-user-dir como usuário real
  local desktop
  desktop=$(sudo -u "$user" xdg-user-dir DESKTOP 2>/dev/null || true)
  if [[ -n "$desktop" && -d "$desktop" ]]; then
    printf '%s\n' "$desktop"
    return 0
  fi

  # 2) tenta ler ~/.config/user-dirs.dirs
  if [[ -f "$home/.config/user-dirs.dirs" ]]; then
    local xdgval desktop_path
    xdgval=$(sed -n 's/^XDG_DESKTOP_DIR=//p' "$home/.config/user-dirs.dirs" | tr -d '"')
    if [[ -n "$xdgval" ]]; then
      desktop_path="${xdgval/\$HOME/$home}"
      desktop_path=$(realpath -m "$desktop_path")
      if [[ -d "$desktop_path" ]]; then
        printf '%s\n' "$desktop_path"
        return 0
      fi
    fi
  fi

  # 3) tenta nomes comuns
  for name in "Desktop" "desktop" "Área de trabalho" "Área de Trabalho" "Área_de_trabalho"; do
    if [[ -d "$home/$name" ]]; then
      printf '%s\n' "$home/$name"
      return 0
    fi
  done

  # 4) fallback
  printf '%s\n' "$home/Desktop"
}

# Detecta Desktop
DESKTOP_PATH=$(detect_desktop "$USER_NAME")
DESKTOP_PATH=$(realpath -m "$DESKTOP_PATH")

# Cria pasta Rede
REDE="$DESKTOP_PATH/Rede"
mkdir -p "$REDE"
chown "$USER_NAME:$USER_NAME" "$REDE"

# Cria o arquivo .directory para personalizar o ícone no TDE da pasta chamada Rede
cat > "$REDE/.directory" <<EOF
[Desktop Entry]
Icon=network-workgroup
EOF

chown "$USER_NAME:$USER_NAME" "$REDE/.directory"


# Copia pasta script (do local atual) para $USER_HOME/script
if [[ -d "./script" ]]; then
  rsync -a ./script/ "$USER_HOME/script/"
else
  mkdir -p "$USER_HOME/script"
fi
chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/script"
chmod -R u+rx "$USER_HOME/script"

# -----------------------------
# Instala dependências
# -----------------------------
DEPS="zenity smbclient nmap cifs-utils"
apt update
apt install -y $DEPS



# -----------------------------
# Cria atalhos na pasta Rede
# -----------------------------
cat > "$REDE/Montar Novo Compartilhamento.desktop" <<EOF
[Desktop Entry]
Name=Montar Novo Compartilhamento
Type=Application
Exec=konsole -e sudo $USER_HOME/script/monta_smb.sh
Icon=folder-remote
Terminal=false
EOF

cat > "$REDE/Remover Compartilhamento.desktop" <<EOF
[Desktop Entry]
Name=Remover Compartilhamento
Type=Application
Exec=konsole -e sudo  $USER_HOME/script/desmontar.sh
Icon=folder-remote
Terminal=false
EOF

chmod +x "$REDE/"*.desktop
chown "$USER_NAME:$USER_NAME" "$REDE/"*.desktop


# -----------------------------
# Cria atalhos na pasta $HOME/.trinity/share/apps/konqueror/servicemenus/
# -----------------------------

cat > "$USER_HOME/.trinity/share/apps/konqueror/servicemenus/compartilhar_smb.desktop" <<EOF
[Desktop Entry]
X-TDE-ServiceTypes=inode/directory
X-TDE-Priority=TopLevel
Actions=CompartilharSamba

[Desktop Action CompartilharSamba]
Name=Compartilhar via Samba
Icon=network-workgroup
Exec=konsole -e sudo $USER_HOME/script/compartilha_smb.sh "%f"
EOF

cat > "$USER_HOME/.trinity/share/apps/konqueror/servicemenus/remove_smb.desktop" <<EOF
[Desktop Entry]
X-TDE-ServiceTypes=inode/directory
X-TDE-Priority=TopLevel
Actions=removeShare

[Desktop Action removeShare]
Name=Remover compartilhamento Samba
Icon=network-workgroup
Exec=konsole -e sudo $USER_HOME/script/remove_smb.sh "%f"
EOF

zenity --info --text="Pasta Rede criada em: $REDE\nAtalhos prontos.\nDependências instaladas." --width=400
