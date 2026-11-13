#!/bin/bash
# /home/start.sh — 爱快 Docker Ubuntu 容器引导脚本（环境 + SSH + 3x-ui 面板）
# 换源补包 / CA / SSH 配置 / sshd 守护 / 3x-ui 自动安装与参数同步。
# 用法：放到宿主挂载目录（映射到容器 /home），容器启动命令 /bin/bash /home/start.sh
# 幂等：/etc/.init_done 标记 —— restart 跳过装包；重建容器自动重装并恢复 SSH
# 注意：不要用爱快网页面板编辑本文件（会写成 CRLF 导致容器起不来），用 vim 或 SSH 上传

# ══════════════════════════════════════════════════════════════════
#   ★ 配置区
# ══════════════════════════════════════════════════════════════════
# root 密码：留空 = 首启随机生成并回写本行（日志显示一次）；填值 = 每次启动按此同步，日志不打明文
ROOT_PASS=''  # 留空 = 首启随机生成并自动回写本行；填值 = 每次启动按此同步（不显示明文）
# ── 3x-ui 面板（留空 = 首启随机生成并回写本行；填值 = 首启安装与重启同步都按此值） ──
XUI_WEB_PATH=''               # 面板路径，格式 /xxxxxxxxxxxx/；留空 = 首启随机 12 位并回写
XUI_USER=''                   # 面板账号；留空 = 首启随机 8 位并回写
XUI_PASS=''                   # 面板密码；留空 = 首启随机 16 位并回写（首启日志显示一次）
XUI_PORT='9090'               # 面板端口：留空=不改库中现值；填了=同步到库；填错原样传给它，脚本不校验不纠正
XUI_SUB_PORT='2096'           # 订阅端口：同上
XUI_MIXED_PORT='7890'         # 混合入站端口：同上；库中缺该入站时按此端口补建
XUI_MIXED_USER=''             # 混合入站账号；留空 = 库中有时回填，库中无则随机 8 位并回写
XUI_MIXED_PASS=''             # 混合入站密码；留空 = 库中有时回填，库中无则随机 12 位并回写（新建日志显示一次）
ROUTER_GW=''                  # 可选：仅用于启动日志打印访问地址，留空则自动探测
# ══════════════════════════════════════════════════════════════════
#   以下为内部实现
# ══════════════════════════════════════════════════════════════════
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export TZ=${TZ:-CST-8}

MARKER=/etc/.init_done
LOG=/home/init.log
# 本脚本路径：头部回写要用，提前定义，避免调用早于定义时静默写失败
SELF="${BASH_SOURCE[0]:-/home/start.sh}"
SSHD=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
CA=/etc/ssl/certs/ca-certificates.crt

APT_OPTS='-y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o Acquire::Retries=3'

T0_ALL=$(date +%s)
STEP_CUR=0
STEP_TOTAL=1

mkdir -p /home 2>/dev/null
touch "$LOG" 2>/dev/null || LOG=/var/log/init.log

# ---------- 日志符号 ----------
# 爱快 Docker 日志页不渲染 ANSI 转义码（ESC 会被过滤，只剩 [1;36m 这种残渣），
# 故本脚本完全不用 ANSI，改用 Emoji：由浏览器字体直接渲染出颜色，页面与 SSH 终端都能看。
# 若你的终端/字体不支持 Emoji，只会显示成方块，不影响日志可读性。
E_STG='🔷'     # 阶段开始
E_OK='✅'      # 成功 / 关键提示
E_URL='🌐'     # 访问地址
E_PATH='📁'    # 面板路径
E_USER='💠'    # 账号
E_KEY='🔑'     # 密码
E_PORT='🎯'    # 端口
E_SSH='⚡'     # SSH 登录方式
E_WRITE='📌'   # 配置回写

now()  { date '+%F %T'; }
cost() { echo $(( $(date +%s) - $1 )); }
log() {
    local ts msg trim
    ts=$(now); msg="$*"
    # 错误行统一加 ❌ 前缀：爱快 Docker 日志页不渲染 ANSI，改用 emoji 区分；屏幕与文件内容一致
    case "$msg" in
        *'!!!'*)
            case "$msg" in
                *'❌'*) : ;;
                *) trim=${msg#"${msg%%[![:space:]]*}"}; msg="❌ $trim" ;;
            esac
            ;;
    esac
    printf '[%s] %s\n' "$ts" "$msg"
    printf '[%s] %s\n' "$ts" "$msg" >>"$LOG"
}

# 上一轮日志归档，本次从干净文件开始
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 0 ]; then
    mv -f "$LOG" "$LOG.prev" 2>/dev/null
fi

stage() {
    STEP_CUR=$((STEP_CUR + 1))
    ST_T0=$(date +%s)
    log "${E_STG} [${STEP_CUR}/${STEP_TOTAL}] $*"
}
# 修复：不再依赖 RL_DONE，阶段总结总是打印（run_long 的逐条 ✔/✖ 仍保留）
stage_ok() {
    log "     ${E_OK} $*（$(cost "$ST_T0")s）"
}

# ---------- 清理卡死的 apt/dpkg 残留与锁 ----------
# 修复：pkill 是否存在在函数内实时检测（首启装完 procps 后立即生效）
# 修复：无 pkill 分支的 PID 提取错误（${p#/proc/} 得到 "1234/comm"）
_cleanup_apt_leftovers() {
    local p c pid
    if command -v pkill >/dev/null 2>&1; then
        pkill -9 -x dpkg      >/dev/null 2>&1
        pkill -9 -x dpkg-deb  >/dev/null 2>&1
        pkill -9 -x apt-get   >/dev/null 2>&1
        pkill -9 -f 'update-ca-certificates' >/dev/null 2>&1
        pkill -9 -f 'apt-helper'             >/dev/null 2>&1
    else
        for p in /proc/[0-9]*/comm; do
            c=$(cat "$p" 2>/dev/null)
            case "$c" in
                dpkg|dpkg-deb|apt-get)
                    pid=${p#/proc/}; pid=${pid%/comm}
                    kill -9 "$pid" 2>/dev/null
                    ;;
            esac
        done
    fi
    sleep 1
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
          /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
    command -v dpkg >/dev/null 2>&1 && timeout 90 dpkg --configure -a </dev/null >>"$LOG" 2>&1
}

# ---------- 长命令执行器：60s 一行进度，原始输出落日志 ----------
run_long() {     # $1=描述 $2=超时秒 $3=命令
    local desc="$1" tmo="$2" cmd="$3"
    local t0 el=0 rc cur rpid outf last=0
    t0=$(date +%s)
    outf=$(mktemp /tmp/rl.XXXXXX 2>/dev/null || echo /tmp/rl.out)

    timeout -k 15 "$tmo" bash -c "$cmd" </dev/null >"$outf" 2>&1 &
    rpid=$!

    while kill -0 "$rpid" 2>/dev/null; do
        sleep 3
        kill -0 "$rpid" 2>/dev/null || break
        el=$(( $(date +%s) - t0 ))
        if [ "$el" -ge $((last + 60)) ]; then
            last=$el
            cur=$(grep -E '^(Setting up |Unpacking |Processing triggers|Fetched )' "$outf" 2>/dev/null | tail -1 | cut -c1-70)
            if [ -n "$cur" ]; then
                log "     ⏳ ${desc} 已 ${el}s ｜ ${cur}"
            else
                log "     ⏳ ${desc} 已 ${el}s"
            fi
        fi
    done

    wait "$rpid" 2>/dev/null
    rc=$?
    [ -s "$outf" ] && cat "$outf" >>"$LOG"
    rm -f "$outf"

    if [ "$rc" -eq 0 ]; then
        log "     ✔ ${desc}（$(cost "$t0")s）"
    elif [ "$rc" -eq 124 ]; then
        log "     ✖ 超时 ${desc}（${tmo}s）→ 清理残留与锁后继续"
        _cleanup_apt_leftovers
    else
        log "     ✖ 失败 ${desc}（exit=$rc，$(cost "$t0")s）→ 清理后继续，详见 $LOG"
        _cleanup_apt_leftovers
    fi
    return "$rc"
}

# ---------- 国内 apt 源（兼容 deb822 与旧版 sources.list） ----------
switch_source() {
    local f hit=""
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
        [ -f "$f" ] || continue
        grep -qE 'https?://(archive|security|cn\.archive)\.ubuntu\.com/ubuntu/?' "$f" 2>/dev/null && hit="$hit ${f##*/}"
        sed -i -E 's,https?://(archive|security|cn\.archive)\.ubuntu\.com/ubuntu/?,http://mirrors.aliyun.com/ubuntu/,g' "$f"
        sed -i -E 's|^Components: .*|Components: main restricted universe multiverse|' "$f"
    done
    if [ -n "$hit" ]; then
        log "     · apt 源已换阿里云：${hit# }"
    else
        log "     · apt 源未发现官方源，保持原样（未改动）"
    fi
}

# ══════════════════════════════════════════════════════════════════
#   3x-ui：安装 / 参数同步 / 拉起
# ══════════════════════════════════════════════════════════════════
XUI_HOME=/usr/local/x-ui
XUI_BIN=$XUI_HOME/x-ui
XUI_CONF=/home/xui_config        # 配置与数据持久目录（在 /home 挂载层，容器重建不丢）
XUI_LINK=/etc/x-ui               # x-ui 固定读取路径 → 软链到 XUI_CONF
XUI_DB=$XUI_CONF/x-ui.db
XUI_PKG=/home/xui-linux-amd64.tar.gz
XUI_URL=https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-amd64.tar.gz

# 读取头部变量当前值（去单引号，兼容行尾注释）；用于回写的 read-back 校验
_head_val() {
    local ln
    ln=$(grep -m1 "^$1=" "$SELF" 2>/dev/null) || return 1
    [ -n "$ln" ] || return 1
    ln=${ln#*=}
    case "$ln" in
        \'*) ln=${ln#\'}; ln=${ln%%\'*} ;;
        *)   ln=$(printf '%s' "$ln" | sed -E 's/[[:space:]#].*$//') ;;
    esac
    printf '%s' "$ln"
}

# 回写配置区变量（只替换值，保留行尾注释）；值里的 \ & | 先转义，避免密码含特殊字符时写坏头部
# 返回真实结果：sed 未命中目标行时退出码仍为 0，必须 read-back 确认值已落盘才算成功
_head_set() {
    local v
    grep -q "^$1=" "$SELF" 2>/dev/null || { _HEAD_FAIL="${_HEAD_FAIL:-} $1"; return 1; }
    [ "$(_head_val "$1")" = "$2" ] && { _HEAD_OK="${_HEAD_OK:-} $1"; return 0; }
    v=$(printf '%s' "$2" | sed -e 's/[\\&|]/\\&/g')
    sed -i "s|^\($1=\)[^[:space:]#]*|\1'${v}'|" "$SELF" 2>/dev/null
    [ "$(_head_val "$1")" = "$2" ] && { _HEAD_OK="${_HEAD_OK:-} $1"; return 0; }
    _HEAD_FAIL="${_HEAD_FAIL:-} $1"
    return 1
}

# 库内是否存在某张表（库未生成 / x-ui 尚未初始化时统一返回 1）
_xui_has_table() {
    [ -s "$XUI_DB" ] || return 1
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [ "$(sqlite3 -cmd '.timeout 3000' "$XUI_DB" "select count(*) from sqlite_master where type='table' and name='$1';" 2>/dev/null)" = "1" ]
}

_rand() {   # $1=长度  $2=字符集
    tr -dc "$2" </dev/urandom 2>/dev/null | head -c "$1"
}

# 变量为空时的取值策略：先查库，库里有值就回填头部（不覆盖库），库里没有才随机
# 返回 0 表示本次有生成随机值；密码是否本次随机另由 XUI_PASS_RANDOM 标记（库中密码是 bcrypt 哈希，无法回显）
_xui_fill_vars() {
    local new=0 p u w dbp="" dbu="" hasuser=0
    XUI_PASS_RANDOM=0
    # 库存在但 sqlite3 缺失时先补装，避免"库有值"被误判为"库空"进而随机覆盖
    if [ -s "$XUI_DB" ] && ! command -v sqlite3 >/dev/null 2>&1; then
        _xui_ensure_sqlite >/dev/null 2>&1 || true
    fi
    if _xui_has_table settings; then
        dbp=$(sqlite3 -cmd '.timeout 3000' "$XUI_DB" "select value from settings where key='webBasePath' limit 1;" 2>/dev/null)
    fi

    if _xui_has_table users; then
        dbu=$(sqlite3 -cmd '.timeout 3000' "$XUI_DB" "select username from users order by id limit 1;" 2>/dev/null)
        [ -n "$dbu" ] && hasuser=1
    fi

    if [ -z "$XUI_WEB_PATH" ]; then
        if [ -n "$dbp" ] && [ "$dbp" != "/" ]; then
            XUI_WEB_PATH="$dbp"; _head_set XUI_WEB_PATH "$XUI_WEB_PATH"
            log "     · 面板路径变量为空，已从库回填：${E_PATH} $XUI_WEB_PATH"
        else
            p=$(_rand 12 'a-z0-9'); [ -n "$p" ] || p="p$(date +%s)"
            XUI_WEB_PATH="/${p}/"; _head_set XUI_WEB_PATH "$XUI_WEB_PATH"; new=1
        fi
    fi
    if [ -z "$XUI_USER" ]; then
        if [ -n "$dbu" ]; then
            XUI_USER="$dbu"; _head_set XUI_USER "$XUI_USER"
            log "     · 面板账号变量为空，已从库回填：${E_USER} $XUI_USER"
        else
            u=$(_rand 8 'a-z0-9'); [ -n "$u" ] || u="u$(date +%s)"
            XUI_USER="$u"; _head_set XUI_USER "$XUI_USER"; new=1
        fi
    fi
    if [ -z "$XUI_PASS" ] && [ "$hasuser" = "0" ]; then
        # 库里没有任何用户 = 真首启，随机生成并回写头部
        w=$(_rand 16 'A-Za-z0-9'); [ -n "$w" ] || w="Xy$(date +%s)Zq9w"
        XUI_PASS="$w"; _head_set XUI_PASS "$XUI_PASS"; new=1; XUI_PASS_RANDOM=1
    fi
    # 反之：XUI_PASS 为空且库里已有用户时既随机也不回写，_xui_apply 不传 -password，密码沿用库中哈希
    [ "$new" = "1" ]
}

# 安装：优先 /home 缓存包，避免容器重建后重复下载 79MB
_xui_install() {
    log "     · 开始安装 3x-ui（首次）"
    if [ -s "$XUI_PKG" ]; then
        log "     · 命中安装包缓存：$XUI_PKG（$(du -h "$XUI_PKG" 2>/dev/null | awk '{print $1}')）"
    else
        run_long "下载 3x-ui 安装包（79MB）" 600 \
            "curl -fL --retry 3 --connect-timeout 20 -o '${XUI_PKG}.part' '$XUI_URL' && mv -f '${XUI_PKG}.part' '$XUI_PKG'"
        if [ ! -s "$XUI_PKG" ]; then
            log "     !!! 安装包获取失败，本次跳过 3x-ui（下次启动重试）"
            return 1
        fi
    fi

    run_long "解压到 /usr/local/x-ui" 240 \
        "rm -rf ${XUI_HOME}.new && mkdir -p ${XUI_HOME}.new && tar xzf '${XUI_PKG}' -C ${XUI_HOME}.new --strip-components=1 && chmod +x ${XUI_HOME}.new/x-ui ${XUI_HOME}.new/bin/xray-linux-amd64 && rm -rf ${XUI_HOME} && mv ${XUI_HOME}.new ${XUI_HOME}"

    if [ ! -x "$XUI_BIN" ]; then
        log "     !!! 解压后未找到 $XUI_BIN，3x-ui 不可用"
        return 1
    fi
    ln -sf "$XUI_BIN" /usr/bin/x-ui
    log "     ✔ 3x-ui 已就位（$(du -sh "$XUI_HOME" 2>/dev/null | awk '{print $1}')）"
    return 0
}

_xui_db_size() {
    local s
    s=$(du -h "$XUI_DB" 2>/dev/null | awk 'NR==1{print $1}')
    echo "${s:-未生成}"
}
_xui_db_wal_size() {
    local s
    s=$(du -h "${XUI_DB}-wal" 2>/dev/null | awk 'NR==1{print $1}')
    case "$s" in ""|0) echo "无" ;; *) echo "$s" ;; esac
}

# 优雅停止：SIGTERM 让 x-ui 正常关库（WAL checkpoint），超时才强杀；顺带清孤儿 xray
_xui_stop() {
    if pgrep -x x-ui >/dev/null 2>&1; then
        pkill -TERM -x x-ui 2>/dev/null
        local i=0
        while [ "$i" -lt 10 ] && pgrep -x x-ui >/dev/null 2>&1; do
            sleep 1
            i=$((i + 1))
        done
        if pgrep -x x-ui >/dev/null 2>&1; then
            log "     · 旧进程 10s 未退出，强制结束（WAL 由 sqlite 下次打开时重放）"
            pkill -9 -x x-ui 2>/dev/null
            sleep 1
        else
            log "     · 旧 x-ui 已停止（${i}s 内退出，WAL 已 checkpoint）"
        fi
    fi
    # 强杀 x-ui 可能留下孤儿 xray 继续占用监听端口，导致下次启动失败
    if pgrep -f '[x]ray-linux' >/dev/null 2>&1; then
        log "     · 检测到残留 xray 进程，一并结束"
        pkill -TERM -f '[x]ray-linux' 2>/dev/null
        sleep 1
        pgrep -f '[x]ray-linux' >/dev/null 2>&1 && pkill -9 -f '[x]ray-linux' 2>/dev/null
    fi
    return 0
}

# 库状态判定：ok / corrupt / maybe / absent
# 关键：只有"确认损坏"才留档重建；锁占用、0字节主库+非空WAL 等一律判 maybe 交给 sqlite 自愈
_xui_db_state() {
    local wal="${XUI_DB}-wal"
    if [ ! -e "$XUI_DB" ]; then
        # 主库没了，WAL 单独存在也无法恢复（缺页头），按损坏留档
        if [ -s "$wal" ]; then echo "corrupt"; else echo "absent"; fi
        return 0
    fi
    local sz
    sz=$(stat -c %s "$XUI_DB" 2>/dev/null || echo 0)
    if [ "$sz" -eq 0 ]; then
        # 实测：0 字节主库缺页头，SQLite 不会重放 WAL（打开后仍无表）→ 直接判损坏留档重建，
        # WAL 一并改名保留，若有价值可人工提取
        echo "corrupt"
        return 0
    fi
    if command -v sqlite3 >/dev/null 2>&1; then
        local r mode
        # 库小于 16MB 用 integrity_check（连数据页一起校验）；更大的库退回 quick_check 控制耗时
        if [ $((sz / 1048576)) -le 16 ]; then mode="integrity_check"; else mode="quick_check"; fi
        r=$(sqlite3 -cmd '.timeout 5000' "$XUI_DB" "pragma ${mode};" 2>&1 | head -3)
        case "$r" in
            ok*) echo "ok" ;;
            *locked*|*busy*|*"disk I/O"*|*"unable to open"*) echo "maybe" ;;
            *malformed*|*corrupt*|*"not a database"*|*"*** "*) echo "corrupt" ;;
            *)
                if [ "$(head -c 15 "$XUI_DB" 2>/dev/null)" = "SQLite format 3" ]; then echo "maybe"; else echo "corrupt"; fi
                ;;
        esac
        return 0
    fi
    if [ "$(head -c 15 "$XUI_DB" 2>/dev/null)" = "SQLite format 3" ]; then echo "ok"; else echo "corrupt"; fi
}

# 按状态处置：只有 corrupt 才改名留档（绝不卡死启动），其余原样放行并留痕
_xui_db_guard() {
    local st quiet="${1:-}"
    st=$(_xui_db_state)
    case "$st" in
        ok)
            [ -n "$quiet" ] || log "     · 数据库校验通过：${XUI_DB}（$(_xui_db_size)）"
            # 未装 sqlite3 时只能做文件头校验，深度校验要等 sqlite3 就绪，此处留痕便于排查
            if [ -z "$quiet" ] && ! command -v sqlite3 >/dev/null 2>&1; then
                log "     · 未装 sqlite3，本次仅做文件头校验（深度校验在写入阶段之后）"
            fi
            ;;
        absent)  [ -n "$quiet" ] || log "     · 无既有数据库（首次初始化）：${XUI_DB}" ;;
        maybe)   [ -n "$quiet" ] || log "     · 数据库暂不可读（可能被其他进程占用），本次不改名，交由 x-ui 打开时自行处理（库 $(_xui_db_size)，WAL $(_xui_db_wal_size)）" ;;
        corrupt)
            local bad="${XUI_DB}.bad.$(date +%Y%m%d%H%M%S)"
            mv -f "$XUI_DB" "$bad" 2>/dev/null
            mv -f "${XUI_DB}-wal" "${bad}-wal" 2>/dev/null
            mv -f "${XUI_DB}-shm" "${bad}-shm" 2>/dev/null
            log "     !!! 数据库确认为损坏，已改名留档：${bad}（将重新初始化）"
            ;;
    esac
    return 0
}

# /etc/x-ui → $XUI_CONF 软链：老布局真实目录先迁移（cp -an 不覆盖已有），再改名留档
_xui_link_config() {
    if ! mkdir -p "$XUI_CONF" 2>/dev/null || [ ! -d "$XUI_CONF" ]; then
        log "     !!! 持久目录不可用（$XUI_CONF 无法创建或不是目录）"
        return 1
    fi
    if [ -L "$XUI_CONF" ]; then
        log "     !!! 持久目录本身是软链（→ $(readlink "$XUI_CONF" 2>/dev/null)），存在互相指向死循环风险"
    fi
    if [ ! -w "$XUI_CONF" ]; then
        log "     !!! 持久目录不可写：$XUI_CONF"
        return 1
    fi

    if [ -L "$XUI_LINK" ]; then
        local cur
        cur=$(readlink -f "$XUI_LINK" 2>/dev/null)
        if [ "$cur" = "$(readlink -f "$XUI_CONF" 2>/dev/null)" ]; then
            log "     · 配置软链已就位：/etc/x-ui → ${cur}（目录 $(ls -A "$cur" 2>/dev/null | wc -l) 项）"
            return 0
        fi
        log "     · 配置软链指向异常（${cur:-断链}），重建"
        if [ -n "$cur" ] && [ -d "$cur" ]; then
            # 指的是另一个真实目录：先把里面数据搬过来，否则旧配置会被孤立丢失
            cp -a -n "$cur"/. "$XUI_CONF"/ 2>/dev/null && log "     · 已从 ${cur} 迁移既有配置到持久目录"
        fi
        rm -f "$XUI_LINK"
    elif [ -d "$XUI_LINK" ]; then
        log "     · 检测到真实配置目录 /etc/x-ui，迁移到持久层"
        cp -a -n "$XUI_LINK"/. "$XUI_CONF"/ 2>/dev/null
        local dbak="${XUI_LINK}.dirbak.$(date +%Y%m%d%H%M%S)"
        mv -f "$XUI_LINK" "$dbak" 2>/dev/null && log "     · 旧目录已改名留档：$dbak"
    elif [ -e "$XUI_LINK" ]; then
        mv -f "$XUI_LINK" "${XUI_LINK}.filebak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        log "     · /etc/x-ui 为异常残留文件（非目录），已改名留档"
    fi

    mkdir -p "$XUI_CONF" 2>/dev/null
    ln -sfn "$XUI_CONF" "$XUI_LINK" 2>/dev/null
    if [ -L "$XUI_LINK" ] && [ -d "$XUI_LINK" ]; then
        log "     · 配置软链已建立：/etc/x-ui → ${XUI_CONF}"
    else
        log "     !!! 配置软链建立失败（$XUI_LINK）"
        return 1
    fi
    return 0
}

# sqlite3：setting 命令不支持订阅端口，只能写库
_xui_ensure_sqlite() {
    command -v sqlite3 >/dev/null 2>&1 && return 0
    log "     · 安装 sqlite3（写订阅端口用）"
    apt-get install ${APT_OPTS} sqlite3 </dev/null >>"$LOG" 2>&1
    command -v sqlite3 >/dev/null 2>&1
}

# 把头部变量写进面板服务（先在停止状态写，避免并发写库）
_xui_apply() {
    # 变量优先、变量留空则沿用持久库现值：空值不传给 setting，避免把库里配置清空
    local args=() blank=""
    [ -n "$XUI_PORT" ]     || blank="$blank 端口"
    [ -n "$XUI_USER" ]     || blank="$blank 账号"
    [ -n "$XUI_PASS" ]     || blank="$blank 密码"
    [ -n "$XUI_WEB_PATH" ] || blank="$blank 路径"
    [ -n "$blank" ] && log "     · 以下变量留空，沿用持久库现值：${blank# }"
    [ -n "$XUI_PORT" ]     && args+=(-port "$XUI_PORT")
    [ -n "$XUI_USER" ]     && args+=(-username "$XUI_USER")
    [ -n "$XUI_PASS" ]     && args+=(-password "$XUI_PASS")
    [ -n "$XUI_WEB_PATH" ] && args+=(-webBasePath "$XUI_WEB_PATH")
    if [ "${#args[@]}" -gt 0 ]; then
        "$XUI_BIN" setting "${args[@]}" >>"$LOG" 2>&1
    else
        log "     · 脚本变量全空，沿用持久库中现有参数"
    fi

    if [ ! -f "$XUI_DB" ]; then
        log "     !!! 数据库未生成：$XUI_DB"
        return 1
    fi

    if _xui_ensure_sqlite; then
        local oldv curv
        if ! _xui_has_table settings; then
            # 首装/库重建：x-ui 本次启动后才建表，此处写入必然失败，明确告知而不是报错
            log "     · 库尚无 settings 表（x-ui 本次启动后初始化），订阅端口 ${XUI_SUB_PORT:-未配置} 下次启动生效"
        else
        oldv=$(sqlite3 "$XUI_DB" "select value from settings where key='subPort';" 2>/dev/null)
        if [ -z "$XUI_SUB_PORT" ]; then
            # 留空即不碰库：既不改写也不回填，保持库中现值
            log "     · 订阅端口变量留空，不改动库中现值（${oldv:-库中未设置}）"
        elif [ "$oldv" != "$XUI_SUB_PORT" ]; then
            sqlite3 "$XUI_DB" "insert into settings(key,value) select 'subPort','${XUI_SUB_PORT}' where not exists(select 1 from settings where key='subPort');" 2>/dev/null
            sqlite3 "$XUI_DB" "update settings set value='${XUI_SUB_PORT}' where key='subPort';" 2>/dev/null
            curv=$(sqlite3 "$XUI_DB" "select value from settings where key='subPort';" 2>/dev/null)
            if [ "$curv" = "$XUI_SUB_PORT" ]; then
                log "     · 订阅端口：${oldv:-未设置} → ${XUI_SUB_PORT}"
            else
                log "     !!! 订阅端口写入失败（当前 ${curv:-未知}）"
            fi
        fi
        fi
    else
        log "     !!! 无 sqlite3，订阅端口无法写入"
    fi
    return 0
}

_xui_sub_info() {
    # 订阅参数不再读取与显示（属 x-ui 自管项）
    return 0
}

# 混合入站：按 protocol 定位（端口可变，避免改号后留下双 mixed）；库中凭据不动，缺失才补建
_xui_mixed_ensure() {
    local port="$XUI_MIXED_PORT" tag="in-${XUI_MIXED_PORT}-tcp"
    if [ -z "$port" ]; then
        log "     · 混合入站端口变量留空，跳过混合入站检查"
        return 0
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log "     !!! 无 sqlite3，跳过混合入站检查（端口 ${port}）"
        return 0
    fi
    if ! _xui_has_table inbounds; then
        log "     · 库尚无 inbounds 表（x-ui 本次启动后初始化），混合入站下次启动检查"
        return 0
    fi

    local row id dport dtag dset dbuser dbpass
    row=$(sqlite3 -cmd '.timeout 3000' "$XUI_DB" "select id||'~'||port||'~'||coalesce(tag,'')||'~'||coalesce(settings,'') from inbounds where protocol='mixed' order by id limit 1;" 2>/dev/null)
    if [ -n "$row" ]; then
        id=$(printf '%s' "$row" | cut -d'~' -f1)
        dport=$(printf '%s' "$row" | cut -d'~' -f2)
        dtag=$(printf '%s' "$row" | cut -d'~' -f3)
        dset=$(printf '%s' "$row" | cut -d'~' -f4)
        dbuser=$(printf '%s' "$dset" | sed -n 's/.*"user":"\([^"]*\)".*/\1/p')
        dbpass=$(printf '%s' "$dset" | sed -n 's/.*"pass":"\([^"]*\)".*/\1/p')
        # 头部留空 → 用库里现有凭据回填，保证脚本头部与实际一致
        if [ -z "$XUI_MIXED_USER" ] && [ -n "$dbuser" ]; then
            XUI_MIXED_USER="$dbuser"; _head_set XUI_MIXED_USER "$dbuser"
            log "     · 混合入站账号已回填脚本头部：${dbuser}"
        fi
        if [ -z "$XUI_MIXED_PASS" ] && [ -n "$dbpass" ]; then
            XUI_MIXED_PASS="$dbpass"; _head_set XUI_MIXED_PASS "$dbpass"
            log "     · 混合入站密码已回填脚本头部（不显示明文）"
        fi

        # 端口不一致 → 原地迁移（不新增第二条），tag 同步
        if [ "$dport" != "$port" ]; then
            sqlite3 "$XUI_DB" "update inbounds set port=${port}, tag='${tag}' where id=${id};" 2>/dev/null
            if [ -n "$(sqlite3 "$XUI_DB" "select 1 from inbounds where id=${id} and port=${port};" 2>/dev/null)" ]; then
                log "     · 混合入站端口迁移：${dport} → ${port}（id=${id}，tag=${tag}，账号 ${XUI_MIXED_USER:-未识别}）"
                dport="$port"
            else
                log "     !!! 混合入站端口迁移失败（id=${id}，当前仍为 ${dport}）"
            fi
        else
            log "     · 混合入站已存在：端口 ${port}（id=${id}，tag=${dtag}，账号 ${XUI_MIXED_USER:-未识别}），未改动数据库"
        fi

        # settings 缺 ip 字段时补齐（面板新建入站默认带 ip，缺字段后续改端口可能异常）
        if ! printf '%s' "$dset" | grep -q '"ip"'; then
            sqlite3 "$XUI_DB" "update inbounds set settings=substr(settings,1,length(settings)-1)||',\"ip\":\"127.0.0.1\"}' where id=${id} and settings not like '%\"ip\"%';" 2>/dev/null
            if sqlite3 "$XUI_DB" "select settings from inbounds where id=${id};" 2>/dev/null | grep -q '"ip"'; then
                log "     · 混合入站 settings 已补齐 \"ip\" 字段"
            else
                log "     !!! 混合入站 settings 补 \"ip\" 字段失败（id=${id}）"
            fi
        fi
        return 0
    fi

    # 库中缺失：变量优先，留空则随机
    local nu="$XUI_MIXED_USER" np="$XUI_MIXED_PASS" gen=0
    if [ -z "$nu" ]; then
        nu=$(_rand 8 'a-z0-9'); [ -n "$nu" ] || nu="m$(date +%s)"
        XUI_MIXED_USER="$nu"; _head_set XUI_MIXED_USER "$nu"; gen=1
    fi
    if [ -z "$np" ]; then
        np=$(_rand 12 'a-z0-9'); [ -n "$np" ] || np="Mp$(date +%s)Qz"
        XUI_MIXED_PASS="$np"; _head_set XUI_MIXED_PASS "$np"; gen=1
    fi

    local js="{\"auth\":\"password\",\"accounts\":[{\"user\":\"${nu}\",\"pass\":\"${np}\"}],\"udp\":false,\"ip\":\"127.0.0.1\"}"
    sqlite3 "$XUI_DB" "insert into inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing,share_addr_strategy) values (1,0,0,0,'',1,0,'',${port},'mixed','${js}','','${tag}','{\"enabled\":false}','listen');" 2>/dev/null

    local chk
    chk=$(sqlite3 "$XUI_DB" "select id from inbounds where protocol='mixed' and port=${port};" 2>/dev/null)
    if [ -n "$chk" ]; then
        log "     · 已补建混合入站：端口 ${port}（id=${chk}，tag=${tag}，账号 ${nu}）"
        if [ "$gen" = "1" ]; then
            log "     ${E_OK} 混合入站凭据为随机生成，仅本次显示密码 ${E_KEY} ${np}"
            log "     ${E_WRITE} 以上凭据已回写脚本头部：$SELF"
        fi
    else
        log "     !!! 混合入站补建失败（端口 ${port}）"
    fi
    return 0
}

# 拉起（cwd 必须在 /usr/local/x-ui，xray 配置写 bin/ 用相对路径）
_xui_start() {
    # 日志超过 2MB 轮转，避免 watchdog 反复重启撑爆磁盘
    local xl=/home/xui.log
    if [ -f "$xl" ] && [ "$(stat -c %s "$xl" 2>/dev/null || echo 0)" -gt 2097152 ]; then
        mv -f "$xl" "${xl}.prev" 2>/dev/null
    fi
    ( cd "$XUI_HOME" && setsid nohup "$XUI_BIN" >> "$xl" 2>&1 < /dev/null & )
    local i=0
    while [ "$i" -lt 8 ]; do
        pgrep -x x-ui >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# 主入口：缺二进制就装；每次启动同步头部变量并拉起；按需回显
ensure_xui() {
    local vars_new=0
    stage "部署 3x-ui 面板"

    if [ ! -x "$XUI_BIN" ]; then
        _xui_install || { log "     !!! 3x-ui 未就绪，本次跳过"; return 1; }
    fi

    # 空间预检：首次安装约需 350MB（包 + 解压）
    local avail
    avail=$(df -Pm /home 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$avail" ] && log "     · /home 可用空间：${avail}MB"
    if [ ! -x "$XUI_BIN" ] && [ -n "$avail" ] && [ "$avail" -lt 400 ]; then
        log "     !!! /home 剩余 ${avail}MB，安装 3x-ui 约需 350MB，可能失败"
    fi

    # 停旧进程（优雅退出，保证 WAL 落盘）→ 配置持久化 → 变量生成 → 库校验
    _xui_stop
    if ! _xui_link_config; then
        log "     !!! 配置持久化不可用，本次退化为非持久模式（配置落 /etc/x-ui，容器重建会丢）"
        rm -f "$XUI_LINK" 2>/dev/null
        mkdir -p "$XUI_LINK" 2>/dev/null
        XUI_DB=/etc/x-ui/x-ui.db
    fi
    _xui_db_guard
    log "     · 生效库路径：${XUI_DB}（库 $(_xui_db_size)，WAL $(_xui_db_wal_size)）"

    _xui_fill_vars && vars_new=1

    # 路径规范化（用户可能只填 xxxx）
    case "$XUI_WEB_PATH" in /*) ;; *) XUI_WEB_PATH="/$XUI_WEB_PATH" ;; esac
    case "$XUI_WEB_PATH" in */) ;; *) XUI_WEB_PATH="$XUI_WEB_PATH/" ;; esac

    # 仅覆盖脚本变量里有的项；其余设置（subPath/subEnable/域名等）与 inbounds/用户/流量
    # 全部沿用 /home/xui_config 里的库，不动
    _xui_apply || return 1

    # 混合入站：库中缺 mixed 时补建，端口变更时原地迁移（x-ui 已停，写库安全）
    _xui_mixed_ensure

    if _xui_start; then
        log "     · ${E_URL} 面板地址：http://${GW_ADDR}:${XUI_PORT}${XUI_WEB_PATH:-/}"
        log "     · 面板账号：${E_USER} ${XUI_USER}"
        if [ "${XUI_PASS_RANDOM:-0}" = "1" ]; then
            log "     ${E_OK} 面板密码（首启随机，仅本次显示） ${E_KEY} ${XUI_PASS}"
        elif [ -n "$XUI_PASS" ]; then
            log "     · 面板密码已同步（请到start.sh内查看）"
        else
            log "     · 面板密码变量留空，沿用库中现值（bcrypt 哈希，不回显；如需重置请在头部填值）"
        fi
        if [ -n "${_HEAD_FAIL:-}" ]; then
            log "     !!! 头部回写失败（本次仅内存生效，重启会变）：${_HEAD_FAIL# }"
        elif [ "$vars_new" = "1" ]; then
            log "     ${E_WRITE} 已回写脚本头部：${_HEAD_OK# }（$SELF）"
        fi
        if [ "$XUI_PORT" = "9090" ] && [ "$XUI_SUB_PORT" = "2096" ] && [ "$XUI_MIXED_PORT" = "7890" ]; then
            log "     · 端口仍为默认值 9090/2096/7890，如需更换请修改本脚本头部对应行后重启"
        fi
        log "     ${E_PORT} 订阅端口 ${XUI_SUB_PORT}　混合入站 ${XUI_MIXED_PORT}（${E_USER} ${XUI_MIXED_USER:-未配置}　${E_KEY} ${XUI_MIXED_PASS:-未配置}）"
        log "     · 配置持久层：/etc/x-ui → ${XUI_DB}（库 $(_xui_db_size)，WAL $(_xui_db_wal_size)）"
    else
        log "     !!! 3x-ui 启动失败，见 /home/xui.log"
        if [ -f /home/xui.log ]; then
            tail -3 /home/xui.log 2>/dev/null | while read -r l; do log "       $l"; done
        else
            log "     !!! /home/xui.log 不存在，说明进程未产生任何输出（可能是二进制不可执行）"
        fi
        local pl p1 p2 p3
        # 端口变量可能为空（首启占位模式），空值用哨兵避免 index($4,":") 命中任意监听项
        p1="@@none@@"; p2="@@none@@"; p3="@@none@@"
        [ -n "$XUI_PORT" ] && p1=":${XUI_PORT}"
        [ -n "$XUI_SUB_PORT" ] && p2=":${XUI_SUB_PORT}"
        [ -n "$XUI_MIXED_PORT" ] && p3=":${XUI_MIXED_PORT}"
        pl=$(ss -ltn 2>/dev/null | awk -v p1="$p1" -v p2="$p2" -v p3="$p3" 'NR>1 && (index($4,p1) || index($4,p2) || index($4,p3)) {print $4}' | head -3 | tr '\n' ' ')
        [ -n "$pl" ] && log "     !!! 面板/订阅/混合端口已被其他进程占用：${pl}"
        return 1
    fi
    return 0
}

mkdir -p /run/sshd
chmod 0755 /run/sshd 2>/dev/null

# ============ 修复：marker 存在但 sshd 缺失 → 重置 marker 触发重装 ============
if [ -f "$MARKER" ] && [ ! -x "$SSHD" ]; then
    log "!!! marker 存在但 sshd 缺失（$SSHD），重置 marker 以便本次重装"
    rm -f "$MARKER"
    NEED_APT=1
fi

# ============ 判断本次模式（同时确定 STEP_TOTAL，修复 [4/3] 计数错位） ============
NEED_APT=${NEED_APT:-0}
[ -f "$MARKER" ] || NEED_APT=1
[ -f "$CA" ] || NEED_APT=1

if [ ! -f "$MARKER" ]; then
    MODE="首启初始化（1~3 分钟）"
    STEP_TOTAL=4
elif [ "$NEED_APT" = "1" ]; then
    MODE="证书/索引修复（1~2 分钟）"
    STEP_TOTAL=3
else
    MODE="常规启动（5~15 秒）"
    STEP_TOTAL=2
fi

log "════════ Ubuntu 容器 ｜ 环境+SSH ｜ 模式：${MODE}"
log "════════ 启动于 $(now) ════════"

# ---------- 1. apt 索引与 CA ----------
if [ "$NEED_APT" = "1" ]; then
    stage "切换国内 apt 源并刷新索引"
    switch_source
    # 修复：update 失败自动重试一次，避免索引不完整导致后续装包连锁失败
    if ! run_long "apt-get update" 240 "apt-get update"; then
        log "     ↻ apt-get update 失败，重试一次"
        run_long "apt-get update（重试）" 240 "apt-get update"
    fi

    if [ ! -f "$CA" ] || ! command -v curl >/dev/null 2>&1; then
        stage "安装 CA 证书与 curl"
        if dpkg -s ca-certificates >/dev/null 2>&1; then
            run_long "安装 ca-certificates/curl" 180 "apt-get install ${APT_OPTS} --reinstall ca-certificates curl"
        else
            run_long "安装 ca-certificates/curl" 180 "apt-get install ${APT_OPTS} ca-certificates curl"
        fi
        command -v update-ca-certificates >/dev/null 2>&1 && \
            timeout 120 update-ca-certificates </dev/null >>"$LOG" 2>&1
        [ -f "$CA" ] || log "     !!! ca-store 仍缺失"
    fi
fi

# ---------- 2. 首启装齐组件 + 配置 SSH ----------
if [ ! -f "$MARKER" ]; then
    stage "安装基础组件（首启最慢一步）"
    timeout 60 dpkg --configure -a </dev/null >>"$LOG" 2>&1

    echo 'tzdata tzdata/Areas select Asia'          | debconf-set-selections 2>/dev/null
    echo 'tzdata tzdata/Zones/Asia select Shanghai' | debconf-set-selections 2>/dev/null

    run_long "安装 openssh 等基础包" 600 \
        "apt-get install ${APT_OPTS} ca-certificates openssl iproute2 lsof openssh-server openssh-client procps netcat-openbsd curl wget vim iputils-ping net-tools cron tzdata dnsutils socat"

    command -v update-ca-certificates >/dev/null 2>&1 && \
        timeout 120 update-ca-certificates </dev/null >>"$LOG" 2>&1

    if command -v sshd >/dev/null 2>&1; then
        SSHD=$(command -v sshd)

        # 清掉可能覆盖的 drop-in 限制
        for c in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$c" ] || continue
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/;
                    s/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$c"
        done

        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'               /etc/ssh/sshd_config
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        grep -q '^PermitRootLogin'        /etc/ssh/sshd_config || echo 'PermitRootLogin yes'        >> /etc/ssh/sshd_config
        grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config

        # 安全相关改写必须可追溯：改了几个 drop-in、最终生效值是什么
        PR=$(grep -hsiE '^[[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'NR==1{print $2}')
        PA=$(grep -hsiE '^[[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'NR==1{print $2}')
        log "     · sshd 配置已改写：PermitRootLogin=${PR:-未设置} PasswordAuthentication=${PA:-未设置}（drop-in $(ls /etc/ssh/sshd_config.d/*.conf 2>/dev/null | wc -l) 个）"

        [ -f /usr/share/zoneinfo/Asia/Shanghai ] && ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        touch "$MARKER"
        log "     ✔ SSH 配置完成，marker 已置位"
    else
        log "     !!! openssh-server 未装上，marker 不置位，下次启动重试"
    fi
    stage_ok "基础组件 + SSH 配置就绪"
else
    log "⏭ 已初始化过，跳过装包"
fi

# ---------- root 密码：头部为空 → 首启随机生成并回写本脚本头部 ----------
SELF="${SELF:-${BASH_SOURCE[0]:-/home/start.sh}}"
# 脚本内含面板/root 明文密码，权限收敛为 600（每次启动校正一次）
chmod 600 "$SELF" 2>/dev/null
PASS_NEW=0
if [ -z "$ROOT_PASS" ]; then
    ROOT_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)
    [ -n "$ROOT_PASS" ] || ROOT_PASS="Xy$(date +%s)Zq9"
    PASS_NEW=1
    if _head_set ROOT_PASS "$ROOT_PASS"; then
        log "     ${E_WRITE} 首启随机密码已回写脚本头部：$SELF"
    else
        log "     !!! 密码回写失败，本次仅内存生效（重启会重新随机）"
    fi
fi

# 每次启动同步密码（改配置区后 restart 即生效）
# 修复：检查 chpasswd 返回值，避免密码含 ":" / 换行时静默失败
if printf '%s' "$ROOT_PASS" | grep -q '[:[:cntrl:]]'; then
    log "     !!! ROOT_PASS 含冒号或控制字符，chpasswd 无法处理，请改为字母数字后重启"
elif echo "root:${ROOT_PASS}" | chpasswd 2>/dev/null; then
    if [ "$PASS_NEW" = "1" ]; then
        log "     ${E_OK} root 密码（首启随机，仅本次显示） ${E_KEY} ${ROOT_PASS}"
    else
        log "     · root 密码已同步（请到start.sh内查看）"
    fi
else
    log "     !!! root 密码同步失败，请检查 ROOT_PASS 是否含特殊字符（冒号/换行）"
fi

# ---------- 3. 启动 sshd（固定 22 端口） ----------
stage "启动 sshd"
if [ -x "$SSHD" ]; then
    [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >>"$LOG" 2>&1
    if pgrep -x sshd >/dev/null 2>&1; then
        log "     · sshd 已在运行"
    else
        # 修复：用 -D 前台 + & 后台化，确保 stderr 日志真正落到 init.log
        "$SSHD" -D -e 2>>"$LOG" &
        sleep 1
        if pgrep -x sshd >/dev/null 2>&1; then
            log "     · sshd 已启动"
        else
            log "     !!! sshd 启动失败，见 $LOG"
        fi
    fi
    # 时区（重建后 /etc/localtime 可能丢失）
    [ -f /usr/share/zoneinfo/Asia/Shanghai ] && ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    stage_ok "SSH 就绪（22 端口）"
else
    log "     !!! sshd not found, SSH 不可用"
fi

# ---------- 4. cron（为后续证书续期预留） ----------
if command -v cron >/dev/null 2>&1 || [ -x /usr/sbin/cron ]; then
    pgrep -x cron >/dev/null 2>&1 || { /usr/sbin/cron 2>>"$LOG"; log "     · cron 已启动"; }
fi

# ---------- 4. 3x-ui 面板（缺装 / 同步参数 / 保活） ----------
GW_ADDR="${ROUTER_GW}"
[ -z "$GW_ADDR" ] && GW_ADDR=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
ensure_xui

# ---------- 收尾 ----------
GW="${ROUTER_GW}"
[ -z "$GW" ] && GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
[ -x "$XUI_BIN" ] && log "════════ 3x-ui 面板 ${E_URL} http://${GW_ADDR:-<网关>}:${XUI_PORT}${XUI_WEB_PATH:-/}"
log "════════ ${E_OK} 全部就绪 ｜ 总 $(cost "$T0_ALL")s ｜ ${E_SSH} SSH root@${GW:-<网关>}（默认 22 端口）"
log "════════ 日志：/home/init.log（上一轮 init.log.prev）"

trap 'log "收到退出信号，容器结束"; exit 0' TERM INT
while true; do
    sleep 60 & wait $!   # 后台等待，docker stop 可即时响应 SIGTERM
    if ! pgrep -x sshd >/dev/null 2>&1; then
        log "watchdog: sshd 不在，正在重启"
        mkdir -p /run/sshd; chmod 0755 /run/sshd 2>/dev/null
        "$SSHD" -D -e 2>>"$LOG" &
    fi
    if command -v cron >/dev/null 2>&1 || [ -x /usr/sbin/cron ]; then
        pgrep -x cron >/dev/null 2>&1 || /usr/sbin/cron 2>>"$LOG"
    fi
    if [ -x "$XUI_BIN" ] && ! pgrep -x x-ui >/dev/null 2>&1; then
        log "watchdog: 3x-ui 不在，正在重启"
        if [ ! -L "$XUI_LINK" ] || [ ! -d "$XUI_LINK" ]; then
            log "watchdog: 配置软链异常（$(readlink "$XUI_LINK" 2>/dev/null || echo 非软链)），尝试修复"
            _xui_link_config || log "watchdog: 配置软链修复失败，本次以非持久模式拉起"
        fi
        _xui_db_guard quiet
        _xui_stop
        _xui_start || log "watchdog: 3x-ui 重启失败，见 /home/xui.log"
    fi
done
