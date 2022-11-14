#!/bin/bash

# This script downlaods and builds the Mac, iOS and tvOS libcurl libraries with Bitcode enabled

# Credits:
#
# Felix Schwarz, IOSPIRIT GmbH, @@felix_schwarz.
#   https://gist.github.com/c61c0f7d9ab60f53ebb0.git
# Bochun Bai
#   https://github.com/sinofool/build-libcurl-ios
# Jason Cox, @jasonacox
#   https://github.com/jasonacox/Build-OpenSSL-cURL
# Preston Jennings
#   https://github.com/prestonj/Build-OpenSSL-cURL

set -ex

# Formatting
default="\033[39m"
wihte="\033[97m"
green="\033[32m"
red="\033[91m"
yellow="\033[33m"

bold="\033[0m${green}\033[1m"
subbold="\033[0m${green}"
archbold="\033[0m${yellow}\033[1m"
normal="${white}\033[0m"
dim="\033[0m${white}\033[2m"
alert="\033[0m${red}\033[1m"
alertdim="\033[0m${red}\033[2m"

# Set trap to help debug any build errors
trap 'echo -e "${alert}** ERROR with Build - Check ${TMPDIR}/curl*.log${alertdim}"; tail -3 ${TMPDIR}/curl*.log' INT TERM EXIT

# Set defaults
CURL_VERSION="curl-7.86.0"
OPENSSL_VERNUM="3.0.7+quic"
nohttp3="0"
catalyst="0"

# Set minimum OS versions for target
MACOS_X86_64_VERSION=""			# Empty = use host version
MACOS_ARM64_VERSION=""			# Min supported is MacOS 11.0 Big Sur
CATALYST_IOS="15.0"				# Min supported is iOS 15.0 for Mac Catalyst
IOS_MIN_SDK_VERSION="8.0"
IOS_SDK_VERSION=""
TVOS_MIN_SDK_VERSION="9.0"
TVOS_SDK_VERSION=""

CORES=$(sysctl -n hw.ncpu)

# Semantic Version Comparison
version_lte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

# Usage Instructions
usage ()
{
	echo
	echo -e "${bold}Usage:${normal}"
	echo
	echo -e "  ${subbold}$0${normal} [-v ${dim}<curl version>${normal}] [-o ${dim}<openssl version>${normal}] [-s ${dim}<version>${normal}] [-t ${dim}<version>${normal}] [-i ${dim}<version>${normal}] [-a ${dim}<version>${normal}] [-u ${dim}<version>${normal}] [-b] [-m] [-x] [-n] [-h]"
    echo
	echo "         -v   version of curl (default $CURL_VERSION)"
	echo "         -o   version of openssl (default $OPENSSL_VERNUM)"
	echo "         -s   iOS min target version (default $IOS_MIN_SDK_VERSION)"
	echo "         -t   tvOS min target version (default $TVOS_MIN_SDK_VERSION)"
	echo "         -i   macOS 86_64 min target version (default $MACOS_X86_64_VERSION)"
	echo "         -a   macOS arm64 min target version (default $MACOS_ARM64_VERSION)"
	echo "         -b   compile without bitcode"
	echo "         -n   compile with nghttp3 & ngtcp2"
	echo "         -u   Mac Catalyst iOS min target version (default $CATALYST_IOS)"
	echo "         -m   compile Mac Catalyst library [beta]"
	echo "         -x   disable color output"
	echo "         -h   show usage"
	echo
	trap - INT TERM EXIT
	exit 127
}

while getopts "v:s:t:i:a:u:o:nmbxh\?" o; do
    case "${o}" in
        v)
			CURL_VERSION="curl-${OPTARG}"
            ;;
		s)
			IOS_MIN_SDK_VERSION="${OPTARG}"
			;;
		t)
			TVOS_MIN_SDK_VERSION="${OPTARG}"
			;;
		i)
			MACOS_X86_64_VERSION="${OPTARG}"
			;;
		a)
			MACOS_ARM64_VERSION="${OPTARG}"
			;;
		n)
			nohttp3="1"
			;;
		m)
			catalyst="1"
			;;
		u)
			catalyst="1"
			CATALYST_IOS="${OPTARG}"
			;;
        o)
            OPENSSL_VERNUM="${OPTARG}"
            ;;
		b)
			NOBITCODE="yes"
			;;
		x)
			bold=""
			subbold=""
			normal=""
			dim=""
			alert=""
			alertdim=""
			archbold=""
			;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z "${MACOS_X86_64_VERSION}" ]; then
	MACOS_X86_64_VERSION=$(sw_vers -productVersion)
fi
if [ -z "${MACOS_ARM64_VERSION}" ]; then
	MACOS_ARM64_VERSION=$(sw_vers -productVersion)
fi

OPENSSL="${PWD}/../openssl"
DEVELOPER=`xcode-select -print-path`

# Semantic Version Comparison
version_lte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}
if version_lte $MACOS_ARM64_VERSION 11.0; then
        MACOS_ARM64_VERSION="11.0"      # Min support for Apple Silicon is 11.0
fi

# HTTP3 support
if [ $nohttp3 == "1" ]; then
	# nghttp3 will be in ../nghttp3/{Platform}/{arch}
	NGHTTP3="${PWD}/../nghttp3"
	# ngtcp2 will be in ../ngtcp2/{Platform}/{arch}
	NGTCP2="${PWD}/../ngtcp2"
fi

if [ $nohttp3 == "1" ]; then
	echo "Building with HTTP3 Support (nghttp3 & ngtcp2)"
else
	echo "Building without HTTP3 Support (nghttp3 & ngtcp2)"
	NGHTTP3CFG=""
	NGHTTP3LIB=""
	NGTCP2CFG=""
	NGTCP2LIB=""
fi

# Check to see if pkg-config is already installed
PATH=$PATH:${TMPDIR}/pkg_config/bin
if ! (type "pkg-config" > /dev/null 2>&1 ) ; then
	echo -e "${alertdim}** WARNING: pkg-config not installed... attempting to install.${dim}"

	# Check to see if Brew is installed
	if (type "brew" > /dev/null 2>&1 ) ; then
		echo "  brew installed - using to install pkg-config"
		brew install pkg-config
	else
		# Build pkg-config from Source
		curl -LOs https://pkg-config.freedesktop.org/releases/pkg-config-0.29.2.tar.gz
		echo "  Building pkg-config"
		tar xfz pkg-config-0.29.2.tar.gz
		pushd pkg-config-0.29.2 > /dev/null
		./configure --prefix=${TMPDIR}/pkg_config --with-internal-glib 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}.log"
		make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}.log"
		make install 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}.log"
		popd > /dev/null
	fi

	# Check to see if installation worked
	if (type "pkg-config" > /dev/null 2>&1 ) ; then
		echo "  SUCCESS: pkg-config now installed"
	else
		echo -e "${alert}** FATAL ERROR: pkg-config failed to install - exiting.${normal}"
		exit 1
	fi
fi

buildMac()
{
	ARCH=$1
	HOST="x86_64-apple-darwin"

	if [ $nohttp3 == "1" ]; then
		NGHTTP3CFG="--with-nghttp3=${NGHTTP3}/Mac/${ARCH}"
		NGHTTP3LIB="-L${NGHTTP3}/Mac/${ARCH}/lib"
		NGTCP2CFG="--with-ngtcp2=${NGTCP2}/Mac/${ARCH}"
		NGTCP2LIB="-L${NGTCP2}/Mac/${ARCH}/lib"
	fi

	TARGET="darwin-i386-cc"
	BUILD_MACHINE=`uname -m`
	export CC="clang"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
	export LDFLAGS="-arch ${ARCH} -L${OPENSSL}/Mac/lib ${NGHTTP3LIB} ${NGTCP2LIB}"

	if [[ $ARCH == "x86_64" ]]; then
		TARGET="darwin64-x86_64-cc"
		MACOS_VER="${MACOS_X86_64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - cross compile
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -L${OPENSSL}/Mac/lib ${NGHTTP3LIB} ${NGTCP2LIB} "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		else
			# Apple x86_64 Build Machine Detected - native build
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
		fi
	fi
	if [[ $ARCH == "arm64" ]]; then
		TARGET="darwin64-arm64-cc"
		MACOS_VER="${MACOS_ARM64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - native build
			export CC="${DEVELOPER}/usr/bin/gcc"
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
		else
			# Apple x86_64 Build Machine Detected - cross compile
			TARGET="darwin64-arm64-cc"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -L${OPENSSL}/Mac/lib ${NGHTTP3LIB} ${NGTCP2LIB} "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		fi
	fi

	echo -e "${subbold}Building ${CURL_VERSION} for ${archbold}${ARCH}${dim} (MacOS ${MACOS_VER})"

	pushd . > /dev/null
	cd "${CURL_VERSION}"
	./configure -prefix="${TMPDIR}/${CURL_VERSION}-${ARCH}" --disable-shared --enable-static --disable-headers-api -with-random=/dev/urandom --with-ssl=${OPENSSL}/Mac ${NGHTTP3CFG} ${NGTCP2CFG} --host=${HOST} --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-${ARCH}.log"

	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-${ARCH}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-${ARCH}.log"
	# Save curl binary for Mac Version
	cp "${TMPDIR}/${CURL_VERSION}-${ARCH}/bin/curl" "${TMPDIR}/curl-${ARCH}"
	cp "${TMPDIR}/${CURL_VERSION}-${ARCH}/bin/curl" "${TMPDIR}/curl"
	make clean 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-${ARCH}.log"
	popd > /dev/null

	# test binary
	if [ $ARCH == ${BUILD_MACHINE} ]; then
		echo -e "Testing binary for ${BUILD_MACHINE}:"
		${TMPDIR}/curl -V
	fi
}

buildCatalyst()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="MacOSX"
	TARGET="${ARCH}-apple-ios${CATALYST_IOS}-macabi"
	BUILD_MACHINE=`uname -m`

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	if [ $nohttp3 == "1" ]; then
		NGHTTP3CFG="--with-nghttp3=${NGHTTP3}/Catalyst/${ARCH}"
		NGHTTP3LIB="-L${NGHTTP3}/Catalyst/${ARCH}/lib"
		NGTCP2CFG="--with-ngtcp2=${NGTCP2}/Catalyst/${ARCH}"
		NGTCP2LIB="-L${NGTCP2}/Catalyst/${ARCH}/lib"
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -target $TARGET ${CC_BITCODE_FLAG}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/catalyst/lib ${NGHTTP3LIB} ${NGTCP2LIB}"

	echo -e "${subbold}Building ${CURL_VERSION} for ${archbold}${ARCH}${dim} ${BITCODE} (Mac Catalyst iOS ${CATALYST_IOS})"

	if [[ "${ARCH}" == "arm64" ]]; then
		./configure -prefix="${TMPDIR}/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}" --disable-shared --enable-static --disable-headers-api -with-random=/dev/urandom --with-ssl=${OPENSSL}/catalyst ${NGHTTP3CFG} ${NGTCP2CFG} --host="arm-apple-darwin" --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log"
	else
		./configure -prefix="${TMPDIR}/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}" --disable-shared --enable-static --disable-headers-api -with-random=/dev/urandom --with-ssl=${OPENSSL}/catalyst ${NGHTTP3CFG} ${NGTCP2CFG} --host="${ARCH}-apple-darwin" --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log"
	fi

	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log"
	popd > /dev/null
}


buildIOS()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="iPhoneOS"
	PLATFORMDIR="iOS"

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	if [ $nohttp3 == "1" ]; then
		NGHTTP3CFG="--with-nghttp3=${NGHTTP3}/${PLATFORMDIR}/${ARCH}"
		NGHTTP3LIB="-L${NGHTTP3}/${PLATFORMDIR}/${ARCH}/lib"
		NGTCP2CFG="--with-ngtcp2=${NGTCP2}/${PLATFORMDIR}/${ARCH}"
		NGTCP2LIB="-L${NGTCP2}/${PLATFORMDIR}/${ARCH}/lib"
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${IOS_MIN_SDK_VERSION} ${CC_BITCODE_FLAG}"

	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} ${BITCODE} (iOS ${IOS_MIN_SDK_VERSION})"

	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/${PLATFORMDIR}/lib ${NGHTTP3LIB} ${NGTCP2LIB}"

	if [[ "${ARCH}" == *"arm64"* || "${ARCH}" == "arm64e" ]]; then
		./configure -prefix="${TMPDIR}/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}" --disable-shared --enable-static --disable-headers-api -with-random=/dev/urandom --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP3CFG} ${NGTCP2CFG} --host="arm-apple-darwin" --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	else
		./configure -prefix="${TMPDIR}/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}" --disable-shared --enable-static --disable-headers-api -with-random=/dev/urandom --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP3CFG} ${NGTCP2CFG} --host="${ARCH}-apple-darwin" --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	fi

	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	popd > /dev/null
}

buildIOSsim()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="iPhoneSimulator"
	PLATFORMDIR="iOS-simulator"

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	if [ $nohttp3 == "1" ]; then
		NGHTTP3CFG="--with-nghttp3=${NGHTTP3}/${PLATFORMDIR}/${ARCH}"
		NGHTTP3LIB="-L${NGHTTP3}/${PLATFORMDIR}/${ARCH}/lib"
		NGTCP2CFG="--with-ngtcp2=${NGTCP2}/${PLATFORMDIR}/${ARCH}"
		NGTCP2LIB="-L${NGTCP2}/${PLATFORMDIR}/${ARCH}/lib"
	fi

	TARGET="darwin-i386-cc"
	RUNTARGET=""
	MIPHONEOS="${IOS_MIN_SDK_VERSION}"
	if [[ $ARCH != "i386" ]]; then
		TARGET="darwin64-${ARCH}-cc"
		RUNTARGET="-target ${ARCH}-apple-ios${IOS_MIN_SDK_VERSION}-simulator"
	fi

	# set up exports for build
	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CXX="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${MIPHONEOS} ${CC_BITCODE_FLAG} ${RUNTARGET} "
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/${PLATFORMDIR}/lib ${NGHTTP3LIB} ${NGTCP2LIB} "
	export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk "

	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} ${BITCODE} (iOS ${IOS_MIN_SDK_VERSION})"

	if [[ "${ARCH}" == *"arm64"* || "${ARCH}" == "arm64e" ]]; then
		./configure -prefix="${TMPDIR}/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}" --disable-shared --enable-static --disable-headers-api -with-random=/dev/urandom --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP3CFG} ${NGTCP2CFG} --host="arm-apple-darwin" --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log"
	else
		./configure -prefix="${TMPDIR}/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}" --disable-shared --enable-static --disable-headers-api -with-random=/dev/urandom --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP3CFG} ${NGTCP2CFG} --host="${ARCH}-apple-darwin" --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log"
	fi

	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log"
	popd > /dev/null
}

buildTVOS()
{
	ARCH=$1

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="AppleTVSimulator"
	else
		PLATFORM="AppleTVOS"
	fi

	if [ $nohttp3 == "1" ]; then
		NGHTTP3CFG="--with-nghttp3=${NGHTTP3}/tvOS/${ARCH}"
		NGHTTP3LIB="-L${NGHTTP3}/tvOS/${ARCH}/lib"
		NGTCP2CFG="--with-ngtcp2=${NGTCP2}/tvOS/${ARCH}"
		NGTCP2LIB="-L${NGTCP2}/tvOS/${ARCH}/lib"
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${TVOS_SDK_VERSION}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} -fembed-bitcode"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/tvOS/lib ${NGHTTP3LIB} ${NGTCP2LIB}"
#	export PKG_CONFIG_PATH

	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS ${TVOS_MIN_SDK_VERSION})"

	./configure -prefix="${TMPDIR}/${CURL_VERSION}-tvOS-${ARCH}" --host="arm-apple-darwin" --disable-shared -with-random=/dev/urandom --disable-ntlm-wb --with-ssl="${OPENSSL}/tvOS" ${NGHTTP3CFG} ${NGTCP2CFG} --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-${ARCH}.log"

	# Patch to not use fork() since it's not available on tvOS
        LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "./lib/curl_config.h"
        LANG=C sed -i -- 's/HAVE_FORK"]=" 1"/HAVE_FORK\"]=" 0"/' "config.status"

	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-${ARCH}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-${ARCH}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-${ARCH}.log"
	popd > /dev/null
}


buildTVOSsim()
{
	ARCH=$1

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="AppleTVSimulator"
	PLATFORMDIR="tvOS-simulator"

	if [ $nohttp3 == "1" ]; then
		NGHTTP3CFG="--with-nghttp3=${NGHTTP3}/${PLATFORMDIR}/${ARCH}"
		NGHTTP3LIB="-L${NGHTTP3}/${PLATFORMDIR}/${ARCH}/lib"
		NGTCP2CFG="--with-ngtcp2=${NGTCP2}/${PLATFORMDIR}/${ARCH}"
		NGTCP2LIB="-L${NGTCP2}/${PLATFORMDIR}/${ARCH}/lib"
	fi

	TARGET="darwin64-${ARCH}-cc"
	RUNTARGET="-target ${ARCH}-apple-tvos${TVOS_MIN_SDK_VERSION}-simulator"

	export $PLATFORM
	export SYSROOT=$(xcrun --sdk appletvsimulator --show-sdk-path)
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CXX="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${SYSROOT} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} -fembed-bitcode ${RUNTARGET}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${SYSROOT} -L${OPENSSL}/${PLATFORMDIR}/lib ${NGHTTP3LIB} ${NGTCP2LIB}"
	export CPPFLAGS=" -I.. -isysroot ${SYSROOT} "


	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS SIM ${TVOS_MIN_SDK_VERSION})"

	if [[ "${ARCH}" == "arm64" ]]; then
		./configure --prefix="${TMPDIR}/${CURL_VERSION}-tvOS-simulator-${ARCH}" --host="arm-apple-darwin" --disable-shared -with-random=/dev/urandom --disable-ntlm-wb --with-ssl="${OPENSSL}/${PLATFORMDIR}" ${NGHTTP3CFG} ${NGTCP2CFG} --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-simulator-${ARCH}.log"
	else
		./configure --prefix="${TMPDIR}/${CURL_VERSION}-tvOS-simulator-${ARCH}" --host="${ARCH}-apple-darwin" --disable-shared  -with-random=/dev/urandom --disable-ntlm-wb --with-ssl="${OPENSSL}/${PLATFORMDIR}" ${NGHTTP3CFG} ${NGTCP2CFG} --enable-optimize --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 --disable-sspi --disable-cookies --disable-progress-meter --enable-dnsshuffle --disable-alt-svc --disable-hsts --without-librtmp --without-libidn2 --without-hyper 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-simulator-${ARCH}.log"
	fi

	# Patch to not use fork() since it's not available on tvOS
        LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "./lib/curl_config.h"
        LANG=C sed -i -- 's/HAVE_FORK"]=" 1"/HAVE_FORK\"]=" 0"/' "config.status"

	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-simulator-${ARCH}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-simulator-${ARCH}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${CURL_VERSION}-tvOS-simulator-${ARCH}.log"
	popd > /dev/null
}

echo -e "${bold}Cleaning up${dim}"
rm -rf include/curl/* lib/*

mkdir -p lib
mkdir -p include/curl/

rm -fr "${TMPDIR}/curl"
rm -rf "${TMPDIR}/${CURL_VERSION}-*"
rm -rf "${TMPDIR}/${CURL_VERSION}-*.log"

rm -rf "${CURL_VERSION}"

if [ ! -e ${CURL_VERSION}.tar.gz ]; then
	echo "Downloading ${CURL_VERSION}.tar.gz"
	curl -Ls -o "${CURL_VERSION}.tar.gz.tmp" https://curl.haxx.se/download/${CURL_VERSION}.tar.gz
	mv "${CURL_VERSION}.tar.gz.tmp" "${CURL_VERSION}.tar.gz"
else
	echo "Using ${CURL_VERSION}.tar.gz"
fi

echo "Unpacking curl"
tar xfz "${CURL_VERSION}.tar.gz"

echo -e "${bold}Building Mac libraries${dim}"
buildMac "x86_64"
buildMac "arm64"

echo "  Copying headers"
cp ${TMPDIR}/${CURL_VERSION}-x86_64/include/curl/* include/curl/

lipo \
	"${TMPDIR}/${CURL_VERSION}-x86_64/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-arm64/lib/libcurl.a" \
	-create -output lib/libcurl_Mac.a

if [ $catalyst == "1" ]; then
echo -e "${bold}Building Catalyst libraries${dim}"
buildCatalyst "x86_64" "bitcode"
buildCatalyst "arm64" "bitcode"

lipo \
	"${TMPDIR}/${CURL_VERSION}-catalyst-x86_64-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-catalyst-arm64-bitcode/lib/libcurl.a" \
	-create -output lib/libcurl_Catalyst.a
fi

echo -e "${bold}Building iOS libraries (bitcode)${dim}"
buildIOS "armv7" "bitcode"
buildIOS "armv7s" "bitcode"
buildIOS "arm64" "bitcode"
buildIOS "arm64e" "bitcode"

lipo \
	"${TMPDIR}/${CURL_VERSION}-iOS-armv7-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-armv7s-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-arm64-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-arm64e-bitcode/lib/libcurl.a" \
	-create -output lib/libcurl_iOS.a

buildIOSsim "i386" "bitcode"
buildIOSsim "x86_64" "bitcode"
buildIOSsim "arm64" "bitcode"

lipo \
	"${TMPDIR}/${CURL_VERSION}-iOS-simulator-i386-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-simulator-x86_64-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-simulator-arm64-bitcode/lib/libcurl.a" \
	-create -output lib/libcurl_iOS-simulator.a

lipo \
	"${TMPDIR}/${CURL_VERSION}-iOS-armv7-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-armv7s-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-arm64-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-arm64e-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-simulator-i386-bitcode/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-iOS-simulator-x86_64-bitcode/lib/libcurl.a" \
	-create -output lib/libcurl_iOS-fat.a

if [[ "${NOBITCODE}" == "yes" ]]; then
	echo -e "${bold}Building iOS libraries (nobitcode)${dim}"
	buildIOS "armv7" "nobitcode"
	buildIOS "armv7s" "nobitcode"
	buildIOS "arm64" "nobitcode"
	buildIOS "arm64e" "nobitcode"
	buildIOSsim "x86_64" "nobitcode"
	buildIOSsim "i386" "nobitcode"

	lipo \
		"${TMPDIR}/${CURL_VERSION}-iOS-armv7-nobitcode/lib/libcurl.a" \
		"${TMPDIR}/${CURL_VERSION}-iOS-armv7s-nobitcode/lib/libcurl.a" \
		"${TMPDIR}/${CURL_VERSION}-iOS-simulator-i386-nobitcode/lib/libcurl.a" \
		"${TMPDIR}/${CURL_VERSION}-iOS-arm64-nobitcode/lib/libcurl.a" \
		"${TMPDIR}/${CURL_VERSION}-iOS-arm64e-nobitcode/lib/libcurl.a" \
		"${TMPDIR}/${CURL_VERSION}-iOS-simulator-x86_64-nobitcode/lib/libcurl.a" \
		-create -output lib/libcurl_iOS_nobitcode.a

fi

echo -e "${bold}Building tvOS libraries${dim}"
buildTVOS "arm64"

lipo \
	"${TMPDIR}/${CURL_VERSION}-tvOS-arm64/lib/libcurl.a" \
	-create -output lib/libcurl_tvOS.a

buildTVOSsim "x86_64"
buildTVOSsim "arm64"

lipo \
	"${TMPDIR}/${CURL_VERSION}-tvOS-arm64/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-tvOS-simulator-x86_64/lib/libcurl.a" \
	-create -output lib/libcurl_tvOS-fat.a

lipo \
	"${TMPDIR}/${CURL_VERSION}-tvOS-simulator-x86_64/lib/libcurl.a" \
	"${TMPDIR}/${CURL_VERSION}-tvOS-simulator-arm64/lib/libcurl.a" \
	-create -output lib/libcurl_tvOS-simulator.a

echo -e "${bold}Cleaning up${dim}"
rm -rf ${TMPDIR}/${CURL_VERSION}-*
rm -rf ${CURL_VERSION}

echo "Checking libraries"
xcrun -sdk iphoneos lipo -info lib/*.a

#reset trap
trap - INT TERM EXIT

echo -e "${normal}Done"
