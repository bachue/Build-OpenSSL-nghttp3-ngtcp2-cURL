#!/bin/bash
echo "Cleaning Build-OpenSSL-cURL"
rm -fr curl/curl-* curl/include curl/lib openssl/openssl-openssl-* openssl/openssl-1* openssl/openssl-3* openssl/openssl-ios* openssl/Mac openssl/iOS* openssl/tvOS* openssl/Catalyst \
        nghttp3/nghttp3-0* nghttp3/Mac nghttp3/iOS* nghttp3/tvOS* nghttp3/lib nghttp3/Catalyst nghttp3/pkg-config* \
        example/iOS\ Test\ App/build/* *.tgz *.pkg \
        /tmp/curl /tmp/openssl /tmp/openssl-*  /tmp/nghttp3-* /tmp/pkg_config /tmp/openssl-extract
