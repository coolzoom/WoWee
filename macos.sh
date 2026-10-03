#!/bin/bash
# WoWee macOS 一键脚本：安装环境 / 配置 / 编译 / 导出资源 / 安装 / 运行
#
# 用法:
#   ./macos.sh            交互式菜单
#   ./macos.sh 3          直接执行某一项（可多个: ./macos.sh 2 3 6）
#
# 所有临时文件（构建目录、日志、保存的配置）都放在项目的 _work/ 下。
# 导出的游戏资源写入项目的 Data/（与 extract_assets.sh 一致，已被 gitignore）。
#
# 兼容 macOS 自带的 bash 3.2：不使用关联数组，空数组只在非空时展开。

set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${ROOT_DIR}/_work"
BUILD_DIR="${WORK_DIR}/build"
LOG_DIR="${WORK_DIR}/logs"
CONFIG_FILE="${WORK_DIR}/config.env"
DATA_DIR="${ROOT_DIR}/Data"

BREW_PACKAGES="cmake pkgconf sdl3 glm openssl@3 zlib ffmpeg vulkan-loader vulkan-headers molten-vk shaderc stormlib unicorn"

# ---------- 默认配置（会被 _work/config.env 覆盖） ----------
BUILD_TYPE="Release"
BUILD_TESTS="OFF"
WOW_MPQ_DIR="/Users/mac/Downloads/git/wow1121cn/Data"
WOW_EXPANSION="auto"
INSTALL_PREFIX="${HOME}/Applications/WoWee"
INSTALL_DATA_MODE="link"

# ---------- 输出工具 ----------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi
info()  { echo "${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()    { echo "${C_GREEN}✔${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}警告:${C_RESET} $*" >&2; }
die()   { echo "${C_RED}错误:${C_RESET} $*" >&2; exit 1; }

# ask "提示" 默认值 -> 结果写入 REPLY
ask() {
    local prompt="$1" default="$2"
    if [ -n "$default" ]; then
        read -r -p "${prompt} [${default}]: " REPLY
    else
        read -r -p "${prompt}: " REPLY
    fi
    REPLY="${REPLY:-$default}"
    case "$REPLY" in "~"*) REPLY="${HOME}${REPLY#\~}" ;; esac
}

confirm() {
    local answer
    read -r -p "$1 [Y/n]: " answer
    case "$answer" in [nN]*) return 1 ;; *) return 0 ;; esac
}

nproc_mac() { sysctl -n hw.logicalcpu 2>/dev/null || echo 4; }

timestamp() { date +%Y%m%d-%H%M%S; }

# ---------- 配置读写 ----------
load_config() {
    # shellcheck disable=SC1090
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
}

save_config() {
    mkdir -p "$WORK_DIR"
    {
        echo "# WoWee macos.sh 配置，可直接编辑；重新运行选项 2 也会改写此文件"
        printf 'BUILD_TYPE=%q\n'        "$BUILD_TYPE"
        printf 'BUILD_TESTS=%q\n'       "$BUILD_TESTS"
        printf 'WOW_MPQ_DIR=%q\n'       "$WOW_MPQ_DIR"
        printf 'WOW_EXPANSION=%q\n'     "$WOW_EXPANSION"
        printf 'INSTALL_PREFIX=%q\n'    "$INSTALL_PREFIX"
        printf 'INSTALL_DATA_MODE=%q\n' "$INSTALL_DATA_MODE"
    } > "$CONFIG_FILE"
    ok "配置已保存到 ${CONFIG_FILE#"$ROOT_DIR"/}"
}

# Homebrew 不在 CMake / pkg-config 的默认搜索路径里，需要显式传入
brew_env() {
    command -v brew >/dev/null 2>&1 || die "未找到 Homebrew，请先执行选项 1 安装环境"
    BREW_PREFIX="$(brew --prefix)"
    local pc="$BREW_PREFIX/lib/pkgconfig" f
    for f in ffmpeg openssl@3 vulkan-loader shaderc; do
        [ -d "$BREW_PREFIX/opt/$f/lib/pkgconfig" ] && pc="$pc:$BREW_PREFIX/opt/$f/lib/pkgconfig"
    done
    export PKG_CONFIG_PATH="${pc}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
}

# 失败的 CMake 配置也会留下 CMakeCache.txt，所以以生成的构建文件为准
is_configured() {
    [ -f "$BUILD_DIR/Makefile" ] || [ -f "$BUILD_DIR/build.ninja" ]
}

ensure_configured() {
    if ! is_configured; then
        cmake_configure
    fi
}

# run_logged 日志名 命令...  —— 输出同时写入 _work/logs/<日志名>-<时间>.log
run_logged() {
    local name="$1"; shift
    "$@" 2>&1 | tee "$LOG_DIR/${name}-$(timestamp).log"
}

# ========== 1. 安装环境 ==========
step_setup() {
    info "[1] 安装环境"

    if ! xcode-select -p >/dev/null 2>&1; then
        warn "未安装 Xcode Command Line Tools，正在启动安装程序..."
        xcode-select --install || true
        die "请在弹出的窗口中完成安装后重新运行本选项"
    fi
    ok "Xcode Command Line Tools: $(xcode-select -p)"

    if ! command -v brew >/dev/null 2>&1; then
        confirm "未找到 Homebrew，是否现在安装？" || die "需要 Homebrew 才能继续"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        command -v brew >/dev/null 2>&1 || die "Homebrew 安装后仍不可用，请重开终端再试"
    fi
    ok "Homebrew: $(brew --prefix)"

    local missing="" pkg
    for pkg in $BREW_PACKAGES; do
        brew list --versions "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        info "安装依赖:${missing}"
        # shellcheck disable=SC2086
        brew install $missing || die "brew install 失败"
    fi
    ok "Homebrew 依赖已就绪"

    info "初始化子模块 (imgui, vk-bootstrap)"
    git -C "$ROOT_DIR" submodule update --init --depth 1 extern/imgui extern/vk-bootstrap \
        || die "子模块初始化失败，请检查网络"
    ok "子模块已就绪"
}

# ========== 2. 配置 ==========
step_configure_interactive() {
    info "[2] 配置"
    load_config

    ask "构建类型 (Release/Debug/RelWithDebInfo)" "$BUILD_TYPE";  BUILD_TYPE="$REPLY"
    ask "是否编译测试 (ON/OFF)" "$BUILD_TESTS";                    BUILD_TESTS="$REPLY"
    echo "WoW 客户端的 Data 目录是包含 *.MPQ 的那个目录（不是 WoW 根目录），可留空以后再填"
    ask "WoW 客户端 Data 目录" "$WOW_MPQ_DIR";                       WOW_MPQ_DIR="$REPLY"
    ask "资料片 (auto/classic/turtle/tbc/wotlk)" "$WOW_EXPANSION";  WOW_EXPANSION="$REPLY"
    ask "安装目录" "$INSTALL_PREFIX";                                INSTALL_PREFIX="$REPLY"
    echo "安装时资源处理: link = 软链接到项目 Data/（省空间）; copy = 完整复制（可脱离项目运行）"
    ask "资源安装方式 (link/copy)" "$INSTALL_DATA_MODE";             INSTALL_DATA_MODE="$REPLY"

    save_config
    cmake_configure
}

cmake_configure() {
    brew_env
    mkdir -p "$BUILD_DIR" "$LOG_DIR"
    info "CMake 配置 -> ${BUILD_DIR#"$ROOT_DIR"/} (${BUILD_TYPE})"
    run_logged configure cmake -S "$ROOT_DIR" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_PREFIX_PATH="$BREW_PREFIX" \
        -DOPENSSL_ROOT_DIR="$BREW_PREFIX/opt/openssl@3" \
        -DWOWEE_BUILD_TESTS="$BUILD_TESTS" \
        || die "CMake 配置失败（依赖缺失时请先执行选项 1），日志见 ${LOG_DIR#"$ROOT_DIR"/}/"
    ok "CMake 配置完成"
}

# ========== 3. 编译 ==========
step_build() {
    info "[3] 编译"
    load_config
    ensure_configured
    brew_env
    local jobs; jobs="$(nproc_mac)"
    info "使用 ${jobs} 个线程编译"
    run_logged build cmake --build "$BUILD_DIR" --parallel "$jobs" \
        || die "编译失败，日志见 ${LOG_DIR#"$ROOT_DIR"/}/"
    [ -x "$BUILD_DIR/bin/wowee" ] || die "编译结束但未找到 $BUILD_DIR/bin/wowee"
    ok "编译完成: ${BUILD_DIR#"$ROOT_DIR"/}/bin/wowee"
}

# ========== 4. 导出资源 ==========
step_extract() {
    info "[4] 导出资源"
    load_config

    if [ -z "$WOW_MPQ_DIR" ]; then
        ask "WoW 客户端 Data 目录（包含 *.MPQ）" ""
        WOW_MPQ_DIR="$REPLY"
        save_config
    fi
    [ -d "$WOW_MPQ_DIR" ] || die "目录不存在: $WOW_MPQ_DIR"
    if ! compgen -G "$WOW_MPQ_DIR/*.MPQ" >/dev/null && ! compgen -G "$WOW_MPQ_DIR/*.mpq" >/dev/null; then
        die "$WOW_MPQ_DIR 中没有 .MPQ 文件，请确认是 WoW 的 Data 目录而不是根目录"
    fi

    local extractor="$BUILD_DIR/bin/asset_extract"
    if [ ! -x "$extractor" ]; then
        ensure_configured
        brew_env
        info "编译 asset_extract"
        run_logged build-asset_extract cmake --build "$BUILD_DIR" --target asset_extract --parallel "$(nproc_mac)"
        [ -x "$extractor" ] || die "asset_extract 未生成，请确认已 brew install stormlib 后重新执行选项 2"
    fi

    set -- --mpq-dir "$WOW_MPQ_DIR" --output "$DATA_DIR" --expansion-subdir
    if [ "$WOW_EXPANSION" != "auto" ]; then
        set -- "$@" --expansion "$WOW_EXPANSION"
        if compgen -G "$DATA_DIR/expansions/$WOW_EXPANSION/db/*.csv" >/dev/null; then
            echo "已存在 CSV 格式的 DBC，跳过 DBC 导出"
            set -- "$@" --skip-dbc
        fi
    fi
    info "从 $WOW_MPQ_DIR 导出到 ${DATA_DIR#"$ROOT_DIR"/}/expansions/"
    run_logged extract "$extractor" "$@" || die "资源导出失败，日志见 ${LOG_DIR#"$ROOT_DIR"/}/"
    ok "资源导出完成"
}

# ========== 5. 安装 ==========
step_install() {
    info "[5] 安装"
    load_config
    if [ ! -x "$BUILD_DIR/bin/wowee" ]; then
        step_build
    fi

    local bin_dir="$INSTALL_PREFIX/bin"
    mkdir -p "$bin_dir" || die "无法创建安装目录 $bin_dir"
    # 与构建目录中可运行的布局保持一致（程序、assets/、addons/），
    # 客户端在安装目录里写的日志、缓存、存档和配置不动
    rsync -a --delete \
        --exclude "/Data" --exclude "/logs/" --exclude "/cache/" --exclude "/saves/" \
        --exclude "/config/" --exclude "portable.txt" --exclude "*.lua.saved" \
        "$BUILD_DIR/bin/" "$bin_dir/" || die "复制程序文件失败"

    if [ -L "$bin_dir/Data" ] || [ -e "$bin_dir/Data" ]; then
        rm -rf "$bin_dir/Data"
    fi
    if [ "$INSTALL_DATA_MODE" = "copy" ]; then
        info "复制资源到 $bin_dir/Data（体积可能很大）"
        rsync -a "$DATA_DIR/" "$bin_dir/Data/" || die "复制 Data 失败"
    else
        ln -s "$DATA_DIR" "$bin_dir/Data" || die "创建 Data 软链接失败"
        echo "Data -> $DATA_DIR（软链接，移动或删除项目后需重新安装）"
    fi

    cat > "$INSTALL_PREFIX/WoWee.command" <<EOF
#!/bin/bash
cd "$bin_dir" && exec ./wowee "\$@"
EOF
    chmod +x "$INSTALL_PREFIX/WoWee.command"
    ok "已安装到 $INSTALL_PREFIX（双击 WoWee.command 即可启动）"
}

# ========== 6. 运行 ==========
step_run() {
    info "[6] 运行"
    load_config

    local bin_dir=""
    if [ "${RUN_INSTALLED:-}" = 1 ] && [ -x "$INSTALL_PREFIX/bin/wowee" ]; then
        bin_dir="$INSTALL_PREFIX/bin"
    elif [ -x "$INSTALL_PREFIX/bin/wowee" ] && [ -x "$BUILD_DIR/bin/wowee" ]; then
        if confirm "运行已安装的版本 ($INSTALL_PREFIX)？选 n 运行构建目录中的版本"; then
            bin_dir="$INSTALL_PREFIX/bin"
        else
            bin_dir="$BUILD_DIR/bin"
        fi
    elif [ -x "$INSTALL_PREFIX/bin/wowee" ]; then
        bin_dir="$INSTALL_PREFIX/bin"
    elif [ -x "$BUILD_DIR/bin/wowee" ]; then
        bin_dir="$BUILD_DIR/bin"
    else
        step_build
        bin_dir="$BUILD_DIR/bin"
    fi
    [ -x "$bin_dir/wowee" ] || die "未找到可运行的 wowee"

    if ! has_extraction \
        && ! compgen -G "$HOME/Library/Application Support/Wowee/Data/expansions/*/manifest.json" >/dev/null; then
        warn "项目 Data/ 中似乎还没有导出的资源；客户端启动后会打开资源构建器，也可先执行选项 4"
    fi

    info "启动 $bin_dir/wowee （日志: $bin_dir/logs/wowee.log）"
    (cd "$bin_dir" && ./wowee)
}

# ========== 7. 一键全部 ==========
step_all() {
    step_setup
    if [ -f "$CONFIG_FILE" ]; then
        load_config
        cmake_configure
    else
        step_configure_interactive
    fi
    step_build
    if has_extraction; then
        ok "已有导出的资源，跳过导出（需要重新导出请单独执行选项 4）"
    elif [ -n "$WOW_MPQ_DIR" ]; then
        step_extract
    else
        warn "未配置 WoW 客户端 Data 目录，跳过资源导出（可用选项 2 配置后执行选项 4）"
    fi
    step_install
    RUN_INSTALLED=1 step_run
}

# 导出完成的标志是 expansions/<资料片>/manifest.json（与客户端判断一致）
has_extraction() {
    if [ "$WOW_EXPANSION" != "auto" ]; then
        [ -f "$DATA_DIR/expansions/$WOW_EXPANSION/manifest.json" ]
    else
        compgen -G "$DATA_DIR/expansions/*/manifest.json" >/dev/null
    fi
}

# ---------- 菜单 ----------
run_choice() {
    # 每一项在子 shell 中运行：die 只结束本项并回到菜单。
    # 不能依赖 set -e —— 在 if / || 里调用的函数中 bash 会忽略它。
    case "$1" in
        1) ( step_setup ) ;;
        2) ( step_configure_interactive ) ;;
        3) ( step_build ) ;;
        4) ( step_extract ) ;;
        5) ( step_install ) ;;
        6) ( step_run ) ;;
        7) ( step_all ) ;;
        0|q|Q) exit 0 ;;
        *) warn "无效选项: $1"; return 1 ;;
    esac
}

show_menu() {
    load_config
    echo ""
    echo "${C_BOLD}======== WoWee macOS 工具 ========${C_RESET}"
    echo "  1) 安装环境   (Xcode CLT / Homebrew 依赖 / 子模块)"
    echo "  2) 配置       (构建类型、WoW 路径、安装目录 + CMake 配置)"
    echo "  3) 编译"
    echo "  4) 导出资源   (从 WoW 客户端 MPQ 导出到 Data/)"
    echo "  5) 安装       (-> ${INSTALL_PREFIX})"
    echo "  6) 运行"
    echo "  7) 一键全部   (1 → 6 依次执行)"
    echo "  0) 退出"
    echo "  临时目录: ${WORK_DIR#"$ROOT_DIR"/}/   WoW Data: ${WOW_MPQ_DIR:-未配置}   资料片: ${WOW_EXPANSION}"
}

[ "$(uname -s)" = "Darwin" ] || die "本脚本仅支持 macOS"
mkdir -p "$WORK_DIR" "$LOG_DIR"
cd "$ROOT_DIR" || exit 1

if [ $# -gt 0 ]; then
    for choice in "$@"; do
        run_choice "$choice" || exit $?
    done
    exit 0
fi

while true; do
    show_menu
    read -r -p "请选择 [0-7]: " choice || exit 0
    if run_choice "$choice"; then
        ok "完成"
    else
        warn "该步骤未成功完成，详见上方输出或 ${LOG_DIR#"$ROOT_DIR"/}/"
    fi
done
