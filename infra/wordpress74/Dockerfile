FROM wordpress:php7.4-apache

ADD https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz /tmp/ioncube.tar.gz

RUN set -eux; \
    tar -xzf /tmp/ioncube.tar.gz -C /tmp; \
    ext_dir="$(php -r 'echo ini_get("extension_dir");')"; \
    cp /tmp/ioncube/ioncube_loader_lin_7.4.so "$ext_dir/ioncube_loader_lin_7.4.so"; \
    echo "zend_extension=$ext_dir/ioncube_loader_lin_7.4.so" > /usr/local/etc/php/conf.d/00-ioncube.ini; \
    rm -rf /tmp/ioncube /tmp/ioncube.tar.gz; \
    php -v; \
    php -m | grep -i ionCube

COPY zz-performance.ini /usr/local/etc/php/conf.d/zz-performance.ini
