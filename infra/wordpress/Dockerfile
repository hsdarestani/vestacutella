FROM wordpress:php8.2-apache

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) ion_arch="x86-64" ;; \
      arm64) ion_arch="aarch64" ;; \
      *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${ion_arch}.tar.gz" -o /tmp/ioncube.tar.gz; \
    tar -xzf /tmp/ioncube.tar.gz -C /tmp; \
    ext_dir="$(php -r 'echo ini_get("extension_dir");')"; \
    cp /tmp/ioncube/ioncube_loader_lin_8.2.so "$ext_dir/ioncube_loader_lin_8.2.so"; \
    echo "zend_extension=$ext_dir/ioncube_loader_lin_8.2.so" > /usr/local/etc/php/conf.d/00-ioncube.ini; \
    rm -rf /tmp/ioncube /tmp/ioncube.tar.gz; \
    php -v; \
    php -m | grep -i ionCube
