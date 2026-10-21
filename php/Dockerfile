FROM php:8.4-apache

# www-data chay bang UID/GID cua user host, khong dung chmod 777
ARG PUID=1000
ARG PGID=1000

RUN apt-get update && apt-get install -y \
    locales \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev libicu-dev libxml2-dev libxslt1-dev \
    libonig-dev libsodium-dev zlib1g-dev \
    git unzip ghostscript \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    groupmod -o -g "${PGID}" www-data; \
    usermod -o -u "${PUID}" -g "${PGID}" www-data; \
    id www-data

RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && echo "en_AU.UTF-8 UTF-8" >> /etc/locale.gen \
    && echo "vi_VN.UTF-8 UTF-8" >> /etc/locale.gen \
    && echo "km_KH.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# build tu GitHub vi pecl.php.net hay loi; GitHub bi chan thi fallback pecl
ARG PHPREDIS_VERSION=6.3.0

RUN set -eux; \
    if curl -fsSL --retry 3 --retry-delay 2 -o /tmp/phpredis.tar.gz \
        "https://github.com/phpredis/phpredis/archive/refs/tags/${PHPREDIS_VERSION}.tar.gz"; then \
        mkdir -p /tmp/phpredis; \
        tar -xzf /tmp/phpredis.tar.gz -C /tmp/phpredis --strip-components=1; \
        cd /tmp/phpredis; \
        phpize; \
        ./configure; \
        make -j"$(nproc)"; \
        make install; \
        cd /; \
        rm -rf /tmp/phpredis /tmp/phpredis.tar.gz; \
    else \
        echo "[php] GitHub khong truy cap duoc, cai redis qua pecl" >&2; \
        pecl install redis; \
    fi; \
    docker-php-ext-enable redis

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
    gd mysqli opcache zip intl soap xsl mbstring exif bcmath sockets sodium

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
    && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf \
    && a2enmod rewrite

RUN { \
    echo '<Directory "${APACHE_DOCUMENT_ROOT}">'; \
    echo '    Options FollowSymLinks'; \
    echo '    AllowOverride All'; \
    echo '    Require all granted'; \
    echo '    FallbackResource /index.php'; \
    echo '</Directory>'; \
    } >> /etc/apache2/apache2.conf

RUN sed -i 's#^[ \t]*ErrorLog .*#ErrorLog "|/usr/bin/rotatelogs /var/log/moodle/error-%Y-%m-%d.log 86400"#' /etc/apache2/sites-available/000-default.conf \
    && sed -i 's#^[ \t]*CustomLog .*#CustomLog "|/usr/bin/rotatelogs /var/log/moodle/access-%Y-%m-%d.log 86400" combined#' /etc/apache2/sites-available/000-default.conf

RUN { \
    echo 'expose_php=Off'; \
    echo 'display_errors=Off'; \
    echo 'display_startup_errors=Off'; \
    echo 'log_errors=On'; \
    echo 'error_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT'; \
    echo 'error_log=/var/log/php/error.log'; \
    echo 'upload_max_filesize=200M'; \
    echo 'post_max_size=200M'; \
    echo 'max_input_vars=10000'; \
    echo 'memory_limit=1G'; \
    echo 'max_execution_time=300'; \
    echo 'zend.exception_ignore_args=On'; \
    echo 'opcache.enable=1'; \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.interned_strings_buffer=16'; \
    echo 'opcache.max_accelerated_files=20000'; \
    echo 'opcache.validate_timestamps=0'; \
    echo 'opcache.jit=tracing'; \
    echo 'opcache.jit_buffer_size=100M'; \
    } > /usr/local/etc/php/conf.d/moodle-optimizations.ini

# an phien ban Apache trong header va trang loi
RUN { \
    echo 'ServerTokens Prod'; \
    echo 'ServerSignature Off'; \
    echo 'ServerName localhost'; \
    } >> /etc/apache2/conf-available/security.conf

COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /var/www/html
ENTRYPOINT ["entrypoint.sh"]
