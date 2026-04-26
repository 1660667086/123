#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_URL="${SS_PLUGINS_UPSTREAM_URL:-https://github.com/loyess/Shell/archive/refs/heads/master.tar.gz}"
INSTALL_DIR="${SS_PLUGINS_INSTALL_DIR:-/root/ss-plugins-fixed}"
RUN_AFTER_PATCH="${SS_PLUGINS_RUN:-1}"

info(){ printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn(){ printf '\033[0;33m[警告]\033[0m %s\n' "$*"; }
err(){ printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }

[ "${EUID}" -ne 0 ] && err "请用 root 运行这个安装器。" && exit 1

if [ -f /etc/redhat-release ]; then
    PM="yum"
elif grep -Eqi 'debian|raspbian|ubuntu' /etc/issue /proc/version 2>/dev/null; then
    PM="apt"
else
    err "仅支持 CentOS / Debian / Ubuntu。"
    exit 1
fi

apt_update_safe(){
    export DEBIAN_FRONTEND=noninteractive
    timeout 240 apt-get \
        -o Dpkg::Use-Pty=0 \
        -o APT::Color=0 \
        -o APT::Update::Post-Invoke-Success::= \
        -o APT::Update::Post-Invoke::= \
        -y update
    local status=$?
    if [ ${status} -eq 124 ]; then
        pkill -f /usr/lib/update-notifier/apt-check >/dev/null 2>&1 || true
        warn "apt update 后置检查超时，已跳过 update-notifier apt-check."
        return 0
    fi
    return ${status}
}

install_bootstrap_deps(){
    if [ "${PM}" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt_update_safe
        apt-get -y install ca-certificates curl wget tar gzip patch
    else
        yum install -y ca-certificates curl wget tar gzip patch
    fi
}

download_file(){
    local output=$1
    local url=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 60 -o "${output}" "${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -c -t3 -T60 -O "${output}" "${url}"
    else
        install_bootstrap_deps
        curl -fL --retry 3 --connect-timeout 60 -o "${output}" "${url}"
    fi
}

install_bootstrap_deps

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

info "下载上游 ss-plugins 完整仓库..."
download_file "${TMP_DIR}/shell.tar.gz" "${UPSTREAM_URL}"

tar -xzf "${TMP_DIR}/shell.tar.gz" -C "${TMP_DIR}"
SRC_DIR=$(find "${TMP_DIR}" -maxdepth 1 -type d -name 'Shell-*' | head -n 1)
[ -z "${SRC_DIR}" ] && err "解压失败，未找到 Shell 源码目录。" && exit 1

PATCH_DIR="${TMP_DIR}/ss-plugins-fixed"
rm -rf "${PATCH_DIR}"
mv "${SRC_DIR}" "${PATCH_DIR}"

info "应用依赖安装修复补丁..."
cd "${PATCH_DIR}"
patch -p1 <<'SS_PLUGINS_FIXED_PATCH'
diff -ruN base/RUN_FIXED.md fixed/RUN_FIXED.md
--- base/RUN_FIXED.md	1970-01-01 08:00:00
+++ fixed/RUN_FIXED.md	2026-04-26 10:55:18
@@ -0,0 +1,27 @@
+# ss-plugins fixed runner
+
+This copy runs in local mode, so patched child scripts under `install/`, `utils/`,
+`prepare/`, `service/`, `templates/`, and `webServer/` are used instead of the
+remote versions.
+
+Run it on a Linux VPS as root:
+
+```bash
+cd /path/to/ss-plugins-fixed
+chmod +x ss-plugins.sh
+sudo ./ss-plugins.sh
+```
+
+Important: run it from inside this directory. If you copy only `ss-plugins.sh`,
+the script falls back to online mode and loses these fixes.
+
+Main fixes in this copy:
+
+- Uses `curl` or `wget` automatically for downloads and GitHub API checks.
+- Installs base tools early: `ca-certificates`, `curl`, `wget`, `unzip`, `gzip`,
+  `tar`, `xz/xz-utils`, `jq`, and `qrencode`.
+- Shows package manager errors instead of hiding all dependency-install output.
+- Repairs interrupted `apt/dpkg` state without killing unrelated apt processes.
+- Uses `chrony` instead of relying on `ntpdate`.
+- Fixes mbedTLS install destination so libraries are installed under the normal
+  prefix rather than `/usr/usr/local`.
diff -ruN base/install/shadowsocks_install.sh fixed/install/shadowsocks_install.sh
--- base/install/shadowsocks_install.sh	2026-04-26 10:55:18
+++ fixed/install/shadowsocks_install.sh	2026-04-26 10:55:18
@@ -1,9 +1,29 @@
 install_shadowsocks_libev(){
     cd ${CUR_DIR}
     pushd ${TEMP_DIR_PATH} > /dev/null 2>&1
-    tar zxf ${shadowsocks_libev_file}.tar.gz
+    if [ ! -d "${shadowsocks_libev_file}" ]; then
+        tar zxf ${shadowsocks_libev_file}.tar.gz
+    fi
     cd ${shadowsocks_libev_file}
-    ./configure --disable-documentation && make && make install
+    if [ -x ./configure ]; then
+        ./configure --disable-documentation && make && make install
+    elif [ -f CMakeLists.txt ]; then
+        if [ ! -f libcork/src/libcork/cli/commands.c ] || [ ! -f libipset/src/libipset/general.c ] || [ ! -f libbloom/bloom.c ]; then
+            _echo -i "shadowsocks-libev源码缺少submodule，正在补全libcork/libipset/libbloom."
+            rm -rf libcork libipset libbloom
+            git clone --depth 1 https://github.com/shadowsocks/libcork.git libcork
+            git clone --depth 1 https://github.com/shadowsocks/ipset.git libipset
+            git clone --depth 1 https://github.com/shadowsocks/libbloom.git libbloom
+        fi
+        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
+            -DWITH_STATIC=OFF -DWITH_EMBEDDED_SRC=ON
+        cmake --build build -- -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
+        cmake --install build
+    else
+        _echo -e "未找到 configure 或 CMakeLists.txt，无法编译 shadowsocks-libev."
+        install_cleanup
+        exit 1
+    fi
     if [ $? -eq 0 ]; then
         chmod +x ${SHADOWSOCKS_LIBEV_INIT}
         local service_name=$(basename ${SHADOWSOCKS_LIBEV_INIT})
diff -ruN base/install/simple_obfs_install.sh fixed/install/simple_obfs_install.sh
--- base/install/simple_obfs_install.sh	2026-04-26 10:55:18
+++ fixed/install/simple_obfs_install.sh	2026-04-26 10:55:18
@@ -1,7 +1,7 @@
 install_simple_obfs(){
     cd ${CUR_DIR}
     
-    simple_obfs_ver=$(wget --no-check-certificate -qO- https://api.github.com/repos/shadowsocks/simple-obfs/releases | grep -o '"tag_name": ".*"' | head -n 1| sed 's/"//g;s/v//g' | sed 's/tag_name: //g')
+    simple_obfs_ver=$(download_text "https://api.github.com/repos/shadowsocks/simple-obfs/releases" | grep -o '"tag_name": ".*"' | head -n 1| sed 's/"//g;s/v//g' | sed 's/tag_name: //g')
     [ -z ${simple_obfs_ver} ] && _echo -e "获取 simple-obfs 最新版本失败." && exit 1
         
     pushd ${TEMP_DIR_PATH} > /dev/null 2>&1
@@ -34,4 +34,4 @@
     [ -f ${SIMPLE_OBFS_BIN_PATH} ] && ln -fs ${SIMPLE_OBFS_BIN_PATH} /usr/bin
     _echo -i "simple-obfs-${simple_obfs_ver} 安装成功."
     popd > /dev/null 2>&1
-}
\ No newline at end of file
+}
diff -ruN base/ss-plugins.sh fixed/ss-plugins.sh
--- base/ss-plugins.sh	2026-04-26 10:55:18
+++ fixed/ss-plugins.sh	2026-04-26 10:55:18
@@ -10,7 +10,8 @@
 
 
 # current path
-CUR_DIR=$( pwd )
+CUR_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
+cd "${CUR_DIR}" || exit 1
 
 
 # base url
@@ -457,14 +458,15 @@
     local package_name=$1
     
     if check_sys packageManager yum; then
-        yum install -y $1 > /dev/null 2>&1
+        yum install -y $1
         if [ $? -ne 0 ]; then
             _echo -e "安装 $1 失败."
             exit 1
         fi
     elif check_sys packageManager apt; then
-        apt-get -y update > /dev/null 2>&1
-        apt-get -y install $1 > /dev/null 2>&1
+        export DEBIAN_FRONTEND=noninteractive
+        apt_update_safe
+        apt-get -y install $1
         if [ $? -ne 0 ]; then
             _echo -e "安装 $1 失败."
             exit 1
@@ -473,6 +475,23 @@
     _echo -i "$1 安装完成."
 }
 
+apt_update_safe(){
+    export DEBIAN_FRONTEND=noninteractive
+    timeout 240 apt-get \
+        -o Dpkg::Use-Pty=0 \
+        -o APT::Color=0 \
+        -o APT::Update::Post-Invoke-Success::= \
+        -o APT::Update::Post-Invoke::= \
+        -y update
+    local status=$?
+    if [ ${status} -eq 124 ]; then
+        pkill -f /usr/lib/update-notifier/apt-check > /dev/null 2>&1 || true
+        _echo -t "apt update 后置检查超时，已跳过 update-notifier apt-check."
+        return 0
+    fi
+    return ${status}
+}
+
 improt_package(){
     local package=$1
     local sh_file=$2
@@ -489,6 +508,33 @@
     fi
 }
 
+download_text(){
+    local url=$1
+
+    if [ "$(command -v curl)" ]; then
+        curl -fsSL "${url}"
+    elif [ "$(command -v wget)" ]; then
+        wget --no-check-certificate -qO- "${url}"
+    else
+        package_install "curl" > /dev/null 2>&1
+        curl -fsSL "${url}"
+    fi
+}
+
+download_file(){
+    local output=$1
+    local url=$2
+
+    if [ "$(command -v curl)" ]; then
+        curl -fL --retry 3 --connect-timeout 60 -o "${output}" "${url}"
+    elif [ "$(command -v wget)" ]; then
+        wget --no-check-certificate -c -t3 -T60 -O "${output}" "${url}"
+    else
+        package_install "curl" > /dev/null 2>&1
+        curl -fL --retry 3 --connect-timeout 60 -o "${output}" "${url}"
+    fi
+}
+
 disable_selinux(){
     if [ -s /etc/selinux/config ] && grep -q 'SELINUX=enforcing' /etc/selinux/config; then
         sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
@@ -599,13 +645,13 @@
 check_script_update(){
     local isShow="${1:-"show"}"
 
-    SHELL_VERSION_NEW=$(wget --no-check-certificate -qO- "https://git.io/fjlbl"|grep 'SHELL_VERSION="'|awk -F "=" '{print $NF}'|sed 's/\"//g'|head -1)
+    SHELL_VERSION_NEW=$(download_text "https://git.io/fjlbl" | grep 'SHELL_VERSION="' | awk -F "=" '{print $NF}' | sed 's/\"//g' | head -1)
     [ -z "${SHELL_VERSION_NEW}" ] && _echo -e "无法链接到 Github !" && exit 0
     if version_gt "${SHELL_VERSION_NEW}" "${SHELL_VERSION}"; then
         _echo -u "${Green}当前脚本版本为：${SHELL_VERSION} 检测到有新版本可更新.${suffix}"
         _echo -d "按任意键开始…或按Ctrl+C取消"
         char=`get_char`
-        wget -N --no-check-certificate -O ss-plugins.sh "https://git.io/fjlbl" && chmod +x ss-plugins.sh
+        download_file "ss-plugins.sh" "https://git.io/fjlbl" && chmod +x ss-plugins.sh
         echo -e "脚本已更新为最新版本[ ${SHELL_VERSION_NEW} ] !(注意：因为更新方式为直接覆盖当前运行的脚本，所以可能下面会提示一些报错，无视即可)" && exit 0
     else
         if [ "${isShow}" = "show" ]; then
@@ -631,13 +677,13 @@
 
 get_ip(){
     local IP=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
-    [ -z "${IP}" ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
-    [ -z "${IP}" ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
+    [ -z "${IP}" ] && IP=$( download_text "https://ipv4.icanhazip.com" )
+    [ -z "${IP}" ] && IP=$( download_text "https://ipinfo.io/ip" )
     echo "${IP}"
 }
 
 get_ipv6(){
-    local ipv6=$(wget -qO- -t1 -T2 ipv6.icanhazip.com)
+    local ipv6=$(download_text "https://ipv6.icanhazip.com")
     [ -z "${ipv6}" ] && return 1 || return 0
 }
 
@@ -1581,4 +1627,4 @@
     *)
         usage 1
         ;;
-esac
\ No newline at end of file
+esac
diff -ruN base/utils/dependencies.sh fixed/utils/dependencies.sh
--- base/utils/dependencies.sh	2026-04-26 10:55:18
+++ fixed/utils/dependencies.sh	2026-04-26 10:55:18
@@ -16,13 +16,11 @@
     local command=$1
     local depend=$2
 
-    if [ ! "$(command -v killall)" ]; then
-        # psmisc contains killall & fuser & pstree commands.
-        package_install "psmisc" > /dev/null 2>&1
-    fi
-    sleep 3
-    killall -q apt apt-get
-    ${command} > /dev/null 2>&1
+    export DEBIAN_FRONTEND=noninteractive
+    dpkg --configure -a
+    apt-get -f -y install
+    apt_update_safe
+    ${command}
     if [ $? -ne 0 ]; then
         _echo -e "依赖包${Red}${depend}${suffix}安装失败，请检查. "
         echo "Checking the error message and run the script again."
@@ -40,7 +38,7 @@
     if [ $? -ne 0 ]; then
         if ls -l /var/lib/dpkg/info | grep -qi 'python-sympy'; then
             mv -f /var/lib/dpkg/info/python-sympy.* /tmp
-            apt update > /dev/null 2>&1
+            apt_update_safe > /dev/null 2>&1
         fi
         ${command} > /dev/null 2>&1
         if [ $? -ne 0 ]; then
@@ -55,7 +53,8 @@
     local command=$1
     local depend=`echo "${command}" | awk '{print $4}'`
     _echo -i "开始安装依赖包 ${depend}"
-    ${command} > /dev/null 2>&1
+    export DEBIAN_FRONTEND=noninteractive
+    ${command}
     if [ $? -ne 0 ]; then
         if check_sys sysRelease ubuntu || check_sys sysRelease debian; then
             if [ $(get_version) == '19.10' ] && [ ${depend} == 'asciidoc' ]; then
@@ -77,10 +76,10 @@
     if check_sys packageManager yum; then
         _echo -i "检查EPEL存储库."
         if [ ! -f /etc/yum.repos.d/epel.repo ]; then
-            yum install -y epel-release > /dev/null 2>&1
+            yum install -y epel-release
         fi
         [ ! -f /etc/yum.repos.d/epel.repo ] && _echo -e "安装EPEL存储库失败，请检查它。" && exit 1
-        [ ! "$(command -v yum-config-manager)" ] && yum install -y yum-utils > /dev/null 2>&1
+        [ ! "$(command -v yum-config-manager)" ] && yum install -y yum-utils
         if version_ge $(get_version) 8; then
             [ x"$(yum repolist epel | grep -w epel | awk '{print $NF}')" != x"enabled" ] && yum-config-manager --enable epel > /dev/null 2>&1
         else
@@ -93,7 +92,8 @@
         done
     elif check_sys packageManager apt; then
 
-        apt-get -y update
+        export DEBIAN_FRONTEND=noninteractive
+        apt_update_safe
         for depend in ${depends[@]}; do
             error_detect_depends "apt-get -y install ${depend}"
         done
@@ -101,21 +101,31 @@
 }
 
 install_dependencies_logic(){
+    if check_sys packageManager yum; then
+        local base_depends=(ca-certificates curl wget unzip gzip tar xz jq qrencode)
+    elif check_sys packageManager apt; then
+        local base_depends=(ca-certificates curl wget unzip gzip tar xz-utils jq qrencode)
+    fi
+    install_dependencies "${base_depends[*]}"
+
     if [[ ${SS_VERSION} = "ss-libev" ]] || [[ "${plugin_num}" == "3" ]]; then
         if check_sys packageManager yum; then
             local depends=(
-                gettext gcc pcre pcre-devel autoconf libtool automake make asciidoc xmlto c-ares-devel libev-devel zlib-devel openssl-devel git qrencode jq
+                ca-certificates curl wget unzip gzip tar xz gettext gcc pcre pcre-devel pcre2-devel autoconf libtool automake make cmake pkgconfig asciidoc xmlto c-ares-devel libev-devel zlib-devel openssl-devel git qrencode jq
             )
         elif check_sys packageManager apt; then
             local depends=(
-                gettext gcc build-essential autoconf libtool libpcre3-dev asciidoc xmlto libev-dev libc-ares-dev automake libssl-dev git qrencode jq xz-utils
+                ca-certificates curl wget unzip gzip tar xz-utils gettext gcc build-essential autoconf libtool cmake pkg-config libpcre3-dev libpcre2-dev asciidoc xmlto libev-dev libc-ares-dev automake libssl-dev git qrencode jq
             )
         fi
         install_dependencies "${depends[*]}"
     fi
 
     if [ ! "$(command -v qrencode)" ] || [ ! "$(command -v jq)" ]; then
-        local depends=(qrencode jq)
+        local depends=(ca-certificates curl wget unzip gzip tar xz-utils qrencode jq)
+        if check_sys packageManager yum; then
+            depends=(ca-certificates curl wget unzip gzip tar xz qrencode jq)
+        fi
         install_dependencies "${depends[*]}"
     fi
 
@@ -123,7 +133,7 @@
         if check_sys packageManager yum; then
             local depends=(chrony)
         elif check_sys packageManager apt; then
-            local depends=(ntpdate)
+            local depends=(chrony)
         fi
         install_dependencies "${depends[*]}"
     fi
@@ -182,7 +192,7 @@
     cd ${MBEDTLS_FILE}
     _echo -i "编译安装${MBEDTLS_FILE}."
     make SHARED=1 CFLAGS=-fPIC
-    make DESTDIR=/usr install
+    make DESTDIR= install
     if [ $? -ne 0 ]; then
         _echo -e "${MBEDTLS_FILE} ${installStatus}失败."
         install_cleanup
@@ -244,4 +254,4 @@
     else
         _echo -i "当前熵池熵值大于或等于1000，未进行更多添加."
     fi 
-}
\ No newline at end of file
+}
diff -ruN base/utils/downloads.sh fixed/utils/downloads.sh
--- base/utils/downloads.sh	2026-04-26 10:55:18
+++ fixed/utils/downloads.sh	2026-04-26 10:55:18
@@ -4,7 +4,7 @@
         echo "${filename} [已存在.]"
     else
         echo "${filename} 当前目录中不存在, 现在开始下载."
-        wget --no-check-certificate -c -t3 -T60 -O ${1} ${2}
+        download_file "${1}" "${2}"
         if [ $? -ne 0 ]; then
             _echo -e "下载 ${filename} 失败."
             exit 1
@@ -30,7 +30,7 @@
     local apiUrl allVersion latestVersion
 
     apiUrl="https://api.github.com/repos/${owner}/${repositoryName}/releases"
-    allVersion=$(wget --no-check-certificate -qO- ${apiUrl} | grep -o '"tag_name": ".*"')
+    allVersion=$(download_text "${apiUrl}" | grep -o '"tag_name": ".*"')
     if [ "${repositoryName}" = "shadowsocks-rust" ]; then
         allVersion=$(echo "${allVersion}" | grep -v "alpha")
     fi
@@ -89,9 +89,11 @@
         judge_latest_version_num_is_none_and_output_error_info "${ssName}" "${libev_ver}"
 
         shadowsocks_libev_file="shadowsocks-libev-${libev_ver}"
-        shadowsocks_libev_url="https://github.com/shadowsocks/shadowsocks-libev/releases/download/v${libev_ver}/shadowsocks-libev-${libev_ver}.tar.gz"
+        shadowsocks_libev_url="https://github.com/shadowsocks/shadowsocks-libev.git"
         pushd ${TEMP_DIR_PATH} > /dev/null 2>&1
-        download "${shadowsocks_libev_file}.tar.gz" "${shadowsocks_libev_url}"
+        if [ ! -d "${shadowsocks_libev_file}" ]; then
+            git clone --depth 1 --recursive --shallow-submodules --branch "v${libev_ver}" "${shadowsocks_libev_url}" "${shadowsocks_libev_file}"
+        fi
         popd > /dev/null 2>&1
         download_service_file ${SHADOWSOCKS_LIBEV_INIT} ${SHADOWSOCKS_LIBEV_INIT_ONLINE} ${SHADOWSOCKS_LIBEV_INIT_LOCAL}
     elif [[ ${SS_VERSION} = "ss-rust" ]]; then
@@ -315,4 +317,4 @@
         download "${gun_file}" "${gun_url}"
         popd > /dev/null 2>&1
     fi
-}
\ No newline at end of file
+}
diff -ruN base/utils/gen_certificates.sh fixed/utils/gen_certificates.sh
--- base/utils/gen_certificates.sh	2026-04-26 10:55:18
+++ fixed/utils/gen_certificates.sh	2026-04-26 10:55:18
@@ -205,7 +205,7 @@
     if [ -e "${ipcalc_install_path}" ]; then
         return
     fi
-    wget --no-check-certificate -q -c -t3 -T60 -O "${ipcalc_install_path}" "${ipcalc_download_url}"
+    download_file "${ipcalc_install_path}" "${ipcalc_download_url}"
     if [ $? -ne 0 ]; then
         _echo -e "Dependency package ipcalc download failed."
         exit 1
@@ -274,4 +274,4 @@
         exit 1
     fi
     acme_get_certificate_by_manual "${domain}" "${algorithmType}" "${isForce}"
-}
\ No newline at end of file
+}
diff -ruN base/utils/update.sh fixed/utils/update.sh
--- base/utils/update.sh	2026-04-26 10:55:18
+++ fixed/utils/update.sh	2026-04-26 10:55:18
@@ -248,7 +248,7 @@
     local caddyVerFlag latestVersion
 
     cd ${CUR_DIR}
-    latestVersion=$(wget --no-check-certificate -qO- https://api.github.com/repos/caddyserver/caddy/releases | grep -o '"tag_name": ".*"' | sed 's/"//g;s/v//g' | sed 's/tag_name: //g' | grep -E '^2' | head -n 1)
+    latestVersion=$(download_text "https://api.github.com/repos/caddyserver/caddy/releases" | grep -o '"tag_name": ".*"' | sed 's/"//g;s/v//g' | sed 's/tag_name: //g' | grep -E '^2' | head -n 1)
 
     judge_current_version_num_is_none_and_output_error_info "${appName}" "${currentVersion}"
     judge_latest_version_num_is_none_and_output_error_info "${appName}" "${latestVersion}"
diff -ruN base/webServer/caddy_install.sh fixed/webServer/caddy_install.sh
--- base/webServer/caddy_install.sh	2026-04-26 10:55:18
+++ fixed/webServer/caddy_install.sh	2026-04-26 10:55:18
@@ -44,7 +44,7 @@
 }
 
 install_caddy_v2(){
-    caddy_ver=$(wget --no-check-certificate -qO- https://api.github.com/repos/caddyserver/caddy/releases | grep -o '"tag_name": ".*"' | sed 's/"//g;s/v//g' | sed 's/tag_name: //g' | grep -E '^2' | head -n 1)
+    caddy_ver=$(download_text "https://api.github.com/repos/caddyserver/caddy/releases" | grep -o '"tag_name": ".*"' | sed 's/"//g;s/v//g' | sed 's/tag_name: //g' | grep -E '^2' | head -n 1)
     [ -z ${caddy_ver} ] && _echo -e "获取 caddy 最新版本失败." && exit 1
     caddy_file="caddy_${caddy_ver}_linux_${ARCH}"
     caddy_url="https://github.com/caddyserver/caddy/releases/download/v${caddy_ver}/caddy_${caddy_ver}_linux_${ARCH}.tar.gz"
diff -ruN base/webServer/nginx_install.sh fixed/webServer/nginx_install.sh
--- base/webServer/nginx_install.sh	2026-04-26 10:55:18
+++ fixed/webServer/nginx_install.sh	2026-04-26 10:55:18
@@ -77,7 +77,7 @@
         fi
         
         # 安装nginx
-        apt update
+        apt_update_safe
         apt install -y nginx
         
         if [ $? -eq 0 ]; then
@@ -121,7 +121,7 @@
         fi
         
         # 安装nginx
-        apt update
+        apt_update_safe
         apt install -y nginx
         
         if [ $? -eq 0 ]; then
SS_PLUGINS_FIXED_PATCH

chmod +x ss-plugins.sh

if [ -e "${INSTALL_DIR}" ]; then
    BACKUP_DIR="${INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    info "已存在 ${INSTALL_DIR}，备份到 ${BACKUP_DIR}"
    mv "${INSTALL_DIR}" "${BACKUP_DIR}"
fi

mkdir -p "$(dirname "${INSTALL_DIR}")"
mv "${PATCH_DIR}" "${INSTALL_DIR}"

info "修复版已准备好：${INSTALL_DIR}"
info "以后可直接运行：cd ${INSTALL_DIR} && ./ss-plugins.sh"

if [ "${RUN_AFTER_PATCH}" = "1" ]; then
    cd "${INSTALL_DIR}"
    exec ./ss-plugins.sh "$@"
fi
