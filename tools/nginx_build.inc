# BEGIN NGINX BUILD
# Shared by the explicit source-install path and the local packager.
nginx_build_jobs() {
    python3 - <<'PY_JOBS'
import os
from pathlib import Path
mem = {p[0].rstrip(':'): int(p[1]) for line in Path('/proc/meminfo').read_text().splitlines() if (p := line.split()) and p[0] in ('MemTotal:', 'MemAvailable:')}
available = mem.get('MemAvailable', mem['MemTotal']) * 1024
cpus = len(os.sched_getaffinity(0))
# Walk the current v2 cgroup and its ancestors: nested quotas also apply.
for line in Path('/proc/self/cgroup').read_text().splitlines():
    if line.startswith('0::'):
        current = Path('/sys/fs/cgroup') / line[3:].lstrip('/')
        while current.is_relative_to('/sys/fs/cgroup'):
            try:
                limit = (current / 'memory.max').read_text().strip()
                used = int((current / 'memory.current').read_text())
                if limit != 'max': available = min(available, max(0, int(limit) - used))
                quota, period = (current / 'cpu.max').read_text().split()
                if quota != 'max': cpus = min(cpus, max(1, int(quota) // int(period)))
            except (OSError, ValueError): pass
            current = current.parent
print(max(1, min(cpus, (available - 256 * 1024**2) // (512 * 1024**2))))
PY_JOBS
}

nginx_compile_stage() (
    local work=$1 stage=$2 jobs=$3 openssl_version=$4
    # A caller's shell flags must not silently change a cached/native payload.
    export CC=gcc CXX=g++
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS MFLAGS
    cmake -S "$work/brotli/deps/brotli" -B "$work/brotli/deps/brotli/out" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBROTLI_DISABLE_TESTS=ON
    cmake --build "$work/brotli/deps/brotli/out" --target brotlienc brotlicommon --parallel "$jobs"
    cd "$work/nginx-$NGX_VERSION"
    ./configure --build=local-quic-brotli --prefix=/usr/local/nginx --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/local/nginx/modules --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log \
        --pid-path=/run/nginx.pid --lock-path=/run/nginx.lock --user=nginx --group=nginx \
        --http-client-body-temp-path=/var/cache/nginx/client_temp --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp --with-file-aio --with-threads --with-compat --with-pcre-jit \
        --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module \
        --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module \
        --with-http_slice_module --with-http_stub_status_module --with-stream --with-stream_ssl_module \
        --with-stream_realip_module --with-stream_ssl_preread_module \
        --add-dynamic-module="$work/geoip2" --add-dynamic-module="$work/brotli" \
        --with-openssl="$work/openssl-$openssl_version" --with-openssl-opt='enable-ktls no-shared no-tests no-apps' \
        --with-cc-opt='-O2 -pipe -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
        --with-ld-opt='-Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -ldl -lpthread -lstdc++'
    make -j"$jobs"
    make install DESTDIR="$stage"
    strip --strip-unneeded "$stage/usr/sbin/nginx" "$stage"/usr/local/nginx/modules/*.so
    "$stage/usr/sbin/nginx" -V
)

nginx_build_stage() {
    local work=$1 cache=$2 stage=$3 jobs recipe cached started=$SECONDS
    local openssl_version=3.5.7
    local openssl_sha=a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8
    local geoip_commit=445df24ef3781e488cee3dfe8a1e111997fc1dfe
    local brotli_commit=a71f9312c2deb28875acc7bacfdd5695a111aa53
    need gcc; need cmake; need git; need perl; need pkg-config; need strip
    read_os
    NGX_ARCH=$(dpkg --print-architecture)
    [[ $NGX_ARCH == amd64 || $NGX_ARCH == arm64 ]] || die 'Nginx 构建仅支持 amd64 / arm64。'
    [[ ! -L $cache ]] || die 'Nginx 缓存目录不能是符号链接。'
    install -d -m 700 "$cache"
    nginx_source "$work"
    # Include every recipe function, source identity, native toolchain and installed
    # dependency version. Never reuse solely on the upstream version number.
    recipe=$({
        declare -f nginx_compile_stage nginx_build_stage nginx_package_tool
        printf '%s\n' "$ID" "$VERSION_ID" "$NGX_ARCH" "$NGX_VERSION" "$openssl_sha" "$geoip_commit" "$brotli_commit"
        sha256sum "$work/nginx.tar.gz" | cut -d' ' -f1
        gcc -v 2>&1
        ld --version
        cmake --version
        make --version
        dpkg-query -W -f='${binary:Package}=${Version}\n' | LC_ALL=C sort
    } | sha256sum); recipe=${recipe%% *}
    export NGX_RECIPE=$recipe
    cached=$cache/$recipe.tar.gz
    if [[ -f $cached && -f $cached.sha256 && ! -L $cached && ! -L $cached.sha256 ]]; then
        (cd "$cache"; sha256sum -c "$recipe.tar.gz.sha256") || die 'Nginx 构建缓存损坏，请移走对应缓存后重试。'
        nginx_package_tool extract "$cached" "$stage" "$ID" "$VERSION_ID" "$NGX_ARCH" "$recipe" >/dev/null
        say "复用已校验 Nginx 构建缓存；准备耗时 $((SECONDS-started)) 秒。"
        return
    fi
    download_verified "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
        "$cache/openssl-$openssl_version.tar.gz" "$openssl_sha" 1
    cp "$cache/openssl-$openssl_version.tar.gz" "$work/openssl.tar.gz"
    tar -xzf "$work/openssl.tar.gz" -C "$work" --no-same-owner
    nginx_module_source https://github.com/leev/ngx_http_geoip2_module.git "$work/geoip2" "$geoip_commit"
    nginx_module_source https://github.com/google/ngx_brotli.git "$work/brotli" "$brotli_commit"
    git -C "$work/brotli" -c protocol.file.allow=never submodule update --init --recursive --depth=1
    # Archive corresponding sources before generating any compiler output.
    tar -czf "$work/sources.tar.gz" --exclude=.git -C "$work" nginx.tar.gz nginx.tar.gz.asc \
        signature.status nginx.sha256 openssl.tar.gz geoip2 brotli
    jobs=$(nginx_build_jobs)
    say "源码准备耗时 $((SECONDS-started)) 秒；使用 $jobs 个编译任务。"
    started=$SECONDS
    nginx_compile_stage "$work" "$stage" "$jobs" "$openssl_version"
    nginx_package_tool seal "$stage" "$ID" "$VERSION_ID" "$NGX_ARCH" "$NGX_VERSION" "$recipe"
    nginx_package_tool pack "$stage" "$cached.part"
    mv -T "$cached.part" "$cached"
    cp "$work/sources.tar.gz" "$cache/$recipe.sources.tar.gz"
    (cd "$cache"; sha256sum "$recipe.tar.gz" "$recipe.sources.tar.gz" > "$recipe.tar.gz.sha256")
    say "编译与暂存耗时 $((SECONDS-started)) 秒；已保存校验缓存。"
}
# END NGINX BUILD
