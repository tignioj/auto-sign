#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
context="$project_dir/dist/AnisetteBuild"
image="local.autosign.windows-anisette:12.13.11.1"
container="autosign-anisette-local"
network="autosign-anisette-loopback"
port="${AUTOSIGN_ANISETTE_PORT:-6969}"
command -v docker >/dev/null || { echo '请先安装并启动 Docker Desktop。' >&2; exit 1; }
docker info >/dev/null
[[ "$port" == <-> && "$port" -ge 1024 && "$port" -le 65535 ]] || { echo '端口需在 1024–65535 之间。' >&2; exit 1; }
mkdir -p "$context"
chmod 700 "$context"
cp "$project_dir/SelfHostedAnisette/"{Dockerfile,coreadi-helper.c,server.py,test_server.py} "$context/"
installer="$context/iTunes64Setup.exe"
checksum="25b28905a81406a5edbf482f7f3ee4831a8641d32d29dceda5d1eb3e8d534c08"
if [[ ! -f "$installer" ]] || [[ "$(shasum -a 256 "$installer" | awk '{print $1}')" != "$checksum" ]]; then
    curl --fail --location --proto '=https' --proto-redir '=https' --max-time 600 --retry 2 \
        'https://secure-appldnld.apple.com/itunes12/140-75773-20260908-6e5e0165-99cb-4b30-b541-1b615fccfc1a/iTunes64Setup.exe' -o "$installer"
fi
[[ "$(shasum -a 256 "$installer" | awk '{print $1}')" == "$checksum" ]] || { echo 'Apple 组件校验失败。' >&2; exit 1; }
docker build --platform linux/amd64 -t "$image" "$context"
if docker network inspect "$network" >/dev/null 2>&1; then
    [[ "$(docker network inspect "$network" --format '{{index .Labels "local.autosign.purpose"}}')" == anisette ]] || { echo '同名 Docker 网络不属于 AutoSign，已停止。' >&2; exit 1; }
else
    docker network create --label local.autosign.purpose=anisette "$network" >/dev/null
fi
if docker inspect "$container" >/dev/null 2>&1; then
    [[ "$(docker inspect "$container" --format '{{index .Config.Labels "local.autosign.purpose"}}')" == anisette ]] || { echo '同名容器不属于 AutoSign，已停止。' >&2; exit 1; }
    docker rm -f "$container" >/dev/null
fi
if docker inspect autosign-anisette-test >/dev/null 2>&1; then
    [[ "$(docker inspect autosign-anisette-test --format '{{index .Config.Labels "local.autosign.purpose"}}')" == anisette-test ]] || { echo '测试容器归属不匹配，已停止。' >&2; exit 1; }
    docker rm -f autosign-anisette-test >/dev/null
fi
docker run -d --init --platform linux/amd64 --name "$container" --restart unless-stopped \
    --label local.autosign.purpose=anisette --network "$network" \
    -p "127.0.0.1:$port:6969" --cap-drop ALL --security-opt no-new-privileges \
    --memory=768m --cpus=1 \
    --tmpfs '/opt/autosign/wine/drive_c/ProgramData/Apple Computer/iTunes/adi:rw,nosuid,noexec,size=32m,mode=0700' \
    "$image" >/dev/null
for attempt in {1..30}; do
    if curl --fail --silent "http://127.0.0.1:$port/v3/client_info" >/dev/null; then
        echo "本机 Windows 认证服务已启动：http://127.0.0.1:$port"
        exit 0
    fi
    sleep 1
done
echo '服务未就绪，请检查 Docker 容器启动状态。' >&2
exit 1
