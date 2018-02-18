ARG ALPINE_VERSION=3.7

################
# Build libpng #
################
FROM alpine:$ALPINE_VERSION AS libpng

# Check https://sourceforge.net/projects/libpng/files/libpng12/
ARG LIBPNG_VERSION=1.2.59
ARG LIBPNG_PGPKEY=F54984BFA16C640F

RUN apk --no-cache add \
        curl \
        build-base \
        zlib-dev \
        gnupg \
    ;

WORKDIR /usr/src
RUN curl -LO https://netix.dl.sourceforge.net/project/libpng/libpng12/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz \
         -LO https://netix.dl.sourceforge.net/project/libpng/libpng12/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz.asc && \
    (gpg --keyserver pgp.mit.edu --keyserver-options timeout=10 --recv-keys ${LIBPNG_PGPKEY} || \
     gpg --keyserver keyserver.pgp.com --keyserver-options timeout=10 --recv-keys ${LIBPNG_PGPKEY} || \
     gpg --keyserver ha.pool.sks-keyservers.net --keyserver-options timeout=10 --recv-keys ${LIBPNG_PGPKEY} ) && \
    gpg --trusted-key ${LIBPNG_PGPKEY} --verify libpng-${LIBPNG_VERSION}.tar.gz.asc

RUN tar zxf libpng-${LIBPNG_VERSION}.tar.gz && \
    cd libpng-${LIBPNG_VERSION} && \
    ./configure --build=$CBUILD --host=$CHOST --prefix=/usr --enable-shared --with-libpng-compat && \
    make install V=0 -j`nproc`
 
RUN strip /usr/lib/libpng*.so*


########################
# Build pagespeed psol #
########################
FROM alpine:$ALPINE_VERSION as pagespeed

# Check https://github.com/apache/incubator-pagespeed-mod/tags
ARG MOD_PAGESPEED_TAG=v1.13.35.2

RUN apk add --no-cache \
        py-setuptools \
        git \
        apache2-dev \
        apr-dev \
        apr-util-dev \
        build-base \
        curl \
        gperf \
        gettext-dev \
        icu-dev \
        libjpeg-turbo-dev \
        libressl-dev \
        pcre-dev \
        zlib-dev \
    ;

WORKDIR /usr/src

RUN git clone --depth=1 -b ${MOD_PAGESPEED_TAG} --recurse-submodules -j`nproc` https://github.com/apache/incubator-pagespeed-mod.git modpagespeed

COPY --from=libpng /usr/lib/libpng* /usr/lib/
COPY --from=libpng /usr/lib/pkgconfig/libpng12.pc /usr/lib/pkgconfig/libpng.pc
COPY --from=libpng /usr/include/libpng12 /usr/include/libpng12/

WORKDIR /usr/src/modpagespeed
COPY patches/modpagespeed/*.patch ./

RUN for i in *.patch; do printf "\r\nApplying patch ${i%%.*}\r\n"; patch -p1 < $i || exit 1; done && \
    cd tools/gyp && \
    python setup.py install && \
    cd ../.. && \
    python build/gyp_chromium --depth=. -D use_system_libs=1 

RUN cd pagespeed/automatic && \
    make psol BUILDTYPE=Release CXXFLAGS=" -I/usr/include/libpng12 -I/usr/include/apr-1 -fPIC -DUCHAR_TYPE=uint16_t" CFLAGS=" -I/usr/include/apr-1 -I/usr/include/libpng12 -fPIC" -j`nproc`

RUN mkdir -p /usr/src/ngxpagespeed/psol/lib/Release/linux/x64 && \
    mkdir -p /usr/src/ngxpagespeed/psol/include/out/Release && \
    cp -r /usr/src/modpagespeed/out/Release/obj /usr/src/ngxpagespeed/psol/include/out/Release/ && \
    cp -r /usr/src/modpagespeed/net /usr/src/ngxpagespeed/psol/include/ && \
    cp -r /usr/src/modpagespeed/testing /usr/src/ngxpagespeed/psol/include/ && \
    cp -r /usr/src/modpagespeed/pagespeed /usr/src/ngxpagespeed/psol/include/ && \
    cp -r /usr/src/modpagespeed/third_party /usr/src/ngxpagespeed/psol/include/ && \
    cp -r /usr/src/modpagespeed/tools /usr/src/ngxpagespeed/psol/include/ && \
    cp -r /usr/src/modpagespeed/pagespeed/automatic/pagespeed_automatic.a /usr/src/ngxpagespeed/psol/lib/Release/linux/x64 && \
    cp -r /usr/src/modpagespeed/url /usr/src/ngxpagespeed/psol/include/


##########################################
# Build Nginx with support for PageSpeed #
##########################################
FROM alpine:$ALPINE_VERSION AS nginx

# Check https://github.com/apache/incubator-pagespeed-ngx/tags
ARG NGX_PAGESPEED_TAG=v1.13.35.2-stable

# Check http://nginx.org/en/download.html for the latest version.
ARG NGINX_VERSION=1.12.2
ARG NGINX_PGPKEY=520A9993A1C052F8

RUN apk add --no-cache \
        apr-dev \
        apr-util-dev \
        build-base \
        ca-certificates \
        git \
        gnupg \
        icu-dev \
        libjpeg-turbo-dev \
        linux-headers \
        libressl-dev \
        pcre-dev \
        tar \
        zlib-dev \
        libxslt-dev \
        gd-dev \
        geoip-dev \
    ;
COPY --from=libpng  /usr/lib/libpng* /usr/lib/

WORKDIR /usr/src
RUN git clone --depth=1 -b ${NGX_PAGESPEED_TAG} --recurse-submodules -j`nproc` https://github.com/apache/incubator-pagespeed-ngx.git ngxpagespeed
COPY --from=pagespeed /usr/src/ngxpagespeed /usr/src/ngxpagespeed/ 

RUN wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz \
         http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc && \
    (gpg --keyserver pgp.mit.edu --keyserver-options timeout=10 --recv-keys ${NGINX_PGPKEY} || \
     gpg --keyserver keyserver.pgp.com --keyserver-options timeout=10 --recv-keys ${NGINX_PGPKEY} || \
     gpg --keyserver ha.pool.sks-keyservers.net --keyserver-options timeout=10 --recv-keys $NGINX_PGPKEY} ) && \
    gpg --trusted-key ${NGINX_PGPKEY} --verify nginx-${NGINX_VERSION}.tar.gz.asc

WORKDIR /usr/src/nginx

RUN tar zxf ../nginx-${NGINX_VERSION}.tar.gz --strip-components=1 -C . && \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module \
        --with-http_xslt_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --with-stream_geoip_module=dynamic \
        --with-http_slice_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-compat \
        --with-file-aio \
        --with-http_v2_module \
        --add-module=/usr/src/ngxpagespeed \
        --with-cc-opt="-fPIC -I /usr/include/apr-1" \
        --with-ld-opt="-Wl,--start-group -luuid -lapr-1 -laprutil-1 -licudata -licuuc -lpng12 -lturbojpeg -ljpeg" && \
    make install -j`nproc`

RUN rm -rf /etc/nginx/html/ && \
    mkdir /etc/nginx/conf.d/ && \
    mkdir -p /usr/share/nginx/html/ && \
    sed -i 's|^</body>|<p><a href="https://www.ngxpagespeed.com/"><img src="pagespeed.png" title="Nginx module for rewriting web pages to reduce latency and bandwidth" /></a></p>\n</body>|' html/index.html && \
    install -m644 html/index.html /usr/share/nginx/html/ && \
    install -m644 html/50x.html /usr/share/nginx/html/ && \
    ln -s ../../usr/lib/nginx/modules /etc/nginx/modules && \
    strip /usr/sbin/nginx* && \
    strip /usr/lib/nginx/modules/*.so

COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/nginx.vh.default.conf /etc/nginx/conf.d/default.conf
COPY pagespeed.png /usr/share/nginx/html/

##########################################
# Combine everything with minimal layers #
##########################################
FROM alpine:$ALPINE_VERSION
LABEL maintainer="Nico Berlee <nico.berlee@on2it.net>"
LABEL version.nginx="1.12.2"
LABEL version.mod-pagespeed="1.13.35.2 stable"
LABEL version.ngx-pagespeed="1.13.35.2 stable"

COPY --from=libpng  /usr/lib/libpng*.so* /usr/local/lib/
COPY --from=pagespeed /usr/bin/envsubst /usr/local/bin
COPY --from=nginx /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx /usr/lib/nginx/modules/ /usr/lib/nginx/modules/
COPY --from=nginx /etc/nginx /etc/nginx
COPY --from=nginx /usr/share/nginx/html/ /usr/share/nginx/html/

RUN apk --no-cache upgrade && \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' /usr/sbin/nginx /usr/lib/nginx/modules/*.so /usr/local/bin/envsubst /usr/local/lib/libpng12.so \
            | tr ',' '\n' \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" && \
    apk add --no-cache $runDeps

RUN addgroup -S nginx && \
    adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx && \
    mkdir -p /var/log/nginx && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    mkdir -p /var/cache/ngx_pagespeed && \
    chown -R nginx:nginx /var/cache/ngx_pagespeed

EXPOSE 80 443

STOPSIGNAL SIGTERM

CMD ["/usr/sbin/nginx", "-g", "daemon off;"]
