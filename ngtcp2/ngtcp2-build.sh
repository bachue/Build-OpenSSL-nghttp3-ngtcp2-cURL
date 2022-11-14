#!/bin/bash
# This script downlaods and builds the Mac, iOS and tvOS ngtcp2 libraries
#
# Credits:
# Jason Cox, @jasonacox
#   https://github.com/jasonacox/Build-OpenSSL-cURL
#
# NGTCP2 - https://github.com/ngtcp2/ngtcp2
#

# > HTTP/3 library written in C
#
# NOTE: pkg-config is required

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

# set trap to help debug build errors
trap 'echo -e "${alert}** ERROR with Build - Check ${TMPDIR}/ngtcp2*.log${alertdim}"; tail -5 ${TMPDIR}/ngtcp2*.log' INT TERM EXIT

# --- Edit this to update default version ---
NGTCP2_VERNUM="0.10.0"
OPENSSL_VERNUM="3.0.7+quic"

# Set defaults
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

if [ -z "${MACOS_X86_64_VERSION}" ]; then
	MACOS_X86_64_VERSION=$(sw_vers -productVersion)
fi
if [ -z "${MACOS_ARM64_VERSION}" ]; then
	MACOS_ARM64_VERSION=$(sw_vers -productVersion)
fi

CORES=$(sysctl -n hw.ncpu)

usage ()
{
	echo
	echo -e "${bold}Usage:${normal}"
	echo
    echo -e "  ${subbold}$0${normal} [-v ${dim}<ngtcp2 version>${normal}] [-o ${dim}<openssl version>${normal}] [-s ${dim}<iOS SDK version>${normal}] [-t ${dim}<tvOS SDK version>${normal}] [-m] [-x] [-h]"
    echo
	echo "         -v   version of ngtcp2 (default $NGTCP2_VERNUM)"
	echo "         -o   version of openssl (default $OPENSSL_VERNUM)"
	echo "         -s   iOS min target version (default $IOS_MIN_SDK_VERSION)"
	echo "         -t   tvOS min target version (default $TVOS_MIN_SDK_VERSION)"
	echo "         -i   macOS 86_64 min target version (default $MACOS_X86_64_VERSION)"
	echo "         -a   macOS arm64 min target version (default $MACOS_ARM64_VERSION)"
	echo "         -m   compile Mac Catalyst library"
	echo "         -u   Mac Catalyst iOS min target version (default $CATALYST_IOS)"
	echo "         -x   disable color output"
	echo "         -h   show usage"
	echo
	trap - INT TERM EXIT
	exit 127
}

while getopts "v:s:t:i:a:o:u:mxh\?" o; do
    case "${o}" in
        v)
            NGTCP2_VERNUM="${OPTARG}"
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

NGTCP2_VERSION="ngtcp2-${NGTCP2_VERNUM}"
DEVELOPER=`xcode-select -print-path`

NGTCP2="${PWD}/../ngtcp2"

# Semantic Version Comparison
version_lte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}
if version_lte $MACOS_ARM64_VERSION 11.0; then
        MACOS_ARM64_VERSION="11.0"      # Min support for Apple Silicon is 11.0
fi

# Check to see if pkg-config is already installed
if (type "pkg-config" > /dev/null 2>&1 ) ; then
	echo "  pkg-config already installed"
else
	echo -e "${alertdim}** WARNING: pkg-config not installed... attempting to install.${dim}"

	# Check to see if Brew is installed
	if (type "brew" > /dev/null 2>&1 ) ; then
		echo "  brew installed - using to install pkg-config"
		brew install pkg-config
	else
		# Build pkg-config from Source
		echo "  Downloading pkg-config-0.29.2.tar.gz"
		curl -LOs https://pkg-config.freedesktop.org/releases/pkg-config-0.29.2.tar.gz
		echo "  Building pkg-config"
		tar xfz pkg-config-0.29.2.tar.gz
		pushd pkg-config-0.29.2 > /dev/null
		./configure --prefix=${TMPDIR}/pkg_config --with-internal-glib 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}.log"
		make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}.log"
		make install 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}.log"
		PATH=$PATH:${TMPDIR}/pkg_config/bin
		popd > /dev/null
	fi

	# Check to see if installation worked
	if (type "pkg-config" > /dev/null 2>&1 ) ; then
		echo "  SUCCESS: pkg-config installed"
	else
		echo -e "${alert}** FATAL ERROR: pkg-config failed to install - exiting.${normal}"
		exit 1
	fi
fi

buildMac()
{
	ARCH=$1

	TARGET="darwin-i386-cc"
	BUILD_MACHINE=`uname -m`
	export CC="${BUILD_TOOLS}/usr/bin/gcc -fembed-bitcode"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
	export LDFLAGS="-arch ${ARCH}"
	export PKG_CONFIG_PATH="${TMPDIR}/openssl-${OPENSSL_VERNUM}-${ARCH}"/lib/pkgconfig:"${PWD}/../nghttp3/Mac/${ARCH}"/lib/pkgconfig

	if [[ $ARCH == "x86_64" ]]; then
		TARGET="darwin64-x86_64-cc"
		MACOS_VER="${MACOS_X86_64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - cross compile
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		else
			# Apple x86_64 Build Machine Detected - native build
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
		fi
	fi
	if [[ $ARCH == "arm64" ]]; then
		TARGET="darwin64-arm64-cc"
		MACOS_VER="${MACOS_ARM64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
		else
			# Apple x86_64 Build Machine Detected - cross compile
			TARGET="darwin64-arm64-cc"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		fi
	fi

	echo -e "${subbold}Building ${NGTCP2_VERSION} for ${archbold}${ARCH}${dim} (MacOS ${MACOS_VER})"

	pushd . > /dev/null
	cd "${NGTCP2_VERSION}"
	autoreconf -fi 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-${ARCH}.log"
	if [[ $ARCH != ${BUILD_MACHINE} ]]; then
		# cross compile required
		if [[ "${ARCH}" == "arm64" || "${ARCH}" == "arm64e"  ]]; then
			./configure --disable-shared --enable-lib-only --prefix="${NGTCP2}/Mac/${ARCH}" --host="arm-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-${ARCH}.log"
		else
			./configure --disable-shared --enable-lib-only --prefix="${NGTCP2}/Mac/${ARCH}" --host="${ARCH}-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-${ARCH}.log"
		fi
	else
		./configure --disable-shared --enable-lib-only --prefix="${NGTCP2}/Mac/${ARCH}" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-${ARCH}.log"
	fi
	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-${ARCH}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-${ARCH}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-${ARCH}.log"
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
	export PKG_CONFIG_PATH=""
}

buildCatalyst()
{
	ARCH=$1

	TARGET="darwin64-${ARCH}-cc"
	BUILD_MACHINE=`uname -m`

	export CC="${BUILD_TOOLS}/usr/bin/gcc"
    export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
    export LDFLAGS="-arch ${ARCH}"
	export PKG_CONFIG_PATH="${TMPDIR}/openssl-${OPENSSL_VERNUM}-catalyst-${ARCH}"/lib/pkgconfig:"${PWD}/../nghttp3/Catalyst/${ARCH}"/lib/pkgconfig

	if [[ $ARCH == "x86_64" ]]; then
		TARGET="darwin64-x86_64-cc"
		MACOS_VER="${MACOS_X86_64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - cross compile
			TARGET="darwin64-x86_64-cc"
			MACOS_VER="${MACOS_X86_64_VERSION}"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		else
			# Apple x86_64 Build Machine Detected - native build
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
		fi
	fi
	if [[ $ARCH == "arm64" ]]; then
		TARGET="darwin64-arm64-cc"
		MACOS_VER="${MACOS_ARM64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - native build
			TARGET="darwin64-arm64-cc"
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
		else
			# Apple x86_64 Build Machine Detected - cross compile
			TARGET="darwin64-arm64-cc"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		fi
	fi

	echo -e "${subbold}Building ${NGTCP2_VERSION} for ${archbold}${ARCH}${dim} (MacOS ${MACOS_VER} Catalyst iOS ${CATALYST_IOS})"

	pushd . > /dev/null
	cd "${NGTCP2_VERSION}"
	autoreconf -fi 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-catalyst-${ARCH}.log"

	# Cross compile required for Catalyst
	if [[ "${ARCH}" == "arm64" ]]; then
		./configure --disable-shared --enable-lib-only --prefix="${NGTCP2}/Catalyst/${ARCH}" --host="arm-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-catalyst-${ARCH}.log"
	else
		./configure --disable-shared --enable-lib-only --prefix="${NGTCP2}/Catalyst/${ARCH}" --host="${ARCH}-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-catalyst-${ARCH}.log"
	fi

	make -j${CORES} 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-catalyst-${ARCH}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-catalyst-${ARCH}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-catalyst-${ARCH}.log"
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
	export PKG_CONFIG_PATH=""
}

buildIOS()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${NGTCP2_VERSION}"
	autoreconf -fi 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"

	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="iPhoneSimulator"
	else
		PLATFORM="iPhoneOS"
	fi

        if [[ "${BITCODE}" == "nobitcode" ]]; then
                CC_BITCODE_FLAG=""
        else
                CC_BITCODE_FLAG="-fembed-bitcode"
        fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${IOS_MIN_SDK_VERSION} ${CC_BITCODE_FLAG}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK}"
	export PKG_CONFIG_PATH="${TMPDIR}/openssl-${OPENSSL_VERNUM}-iOS-${ARCH}"/lib/pkgconfig:"${PWD}/../nghttp3/iOS/${ARCH}"/lib/pkgconfig

	echo -e "${subbold}Building ${NGTCP2_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} (iOS ${IOS_MIN_SDK_VERSION})"
	if [[ "${ARCH}" == "arm64" || "${ARCH}" == "arm64e"  ]]; then
		./configure --disable-shared --enable-lib-only --prefix="${NGTCP2}/iOS/${ARCH}" --host="arm-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	else
		./configure --disable-shared --enable-lib-only --prefix="${NGTCP2}/iOS/${ARCH}" --host="${ARCH}-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	fi

	make -j8 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
	export PKG_CONFIG_PATH=""
}

buildIOSsim()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${NGTCP2_VERSION}"
	autoreconf -fi 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"

  	PLATFORM="iPhoneSimulator"
	export $PLATFORM

	TARGET="darwin-i386-cc"
	RUNTARGET=""
	MIPHONEOS="${IOS_MIN_SDK_VERSION}"
	if [[ $ARCH != "i386" ]]; then
		TARGET="darwin64-${ARCH}-cc"
		RUNTARGET="-target ${ARCH}-apple-ios${IOS_MIN_SDK_VERSION}-simulator"
			# e.g. -target arm64-apple-ios11.0-simulator
	fi

	if [[ "${BITCODE}" == "nobitcode" ]]; then
			CC_BITCODE_FLAG=""
	else
			CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${MIPHONEOS} ${CC_BITCODE_FLAG} ${RUNTARGET}  "
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK}"
	export PKG_CONFIG_PATH="${TMPDIR}/openssl-${OPENSSL_VERNUM}-iOS-Simulator-${ARCH}"/lib/pkgconfig:"${PWD}/../nghttp3/iOS-simulator/${ARCH}"/lib/pkgconfig

	echo -e "${subbold}Building ${NGTCP2_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} (iOS ${IOS_MIN_SDK_VERSION})"
	if [[ "${ARCH}" == "arm64" || "${ARCH}" == "arm64e"  ]]; then
	./configure --disable-shared --disable-app --disable-threads --enable-lib-only --prefix="${NGTCP2}/iOS-simulator/${ARCH}" --host="arm-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	else
	./configure --disable-shared --disable-app --disable-threads --enable-lib-only --prefix="${NGTCP2}/iOS-simulator/${ARCH}" --host="${ARCH}-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	fi

	make -j8 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	make install 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
	export PKG_CONFIG_PATH=""
}

buildTVOS()
{
	ARCH=$1

	pushd . > /dev/null
	cd "${NGTCP2_VERSION}"
	autoreconf -fi 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"

	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="AppleTVSimulator"
	else
		PLATFORM="AppleTVOS"
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${TVOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} -fembed-bitcode"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} ${NGTCP2LIB}"
	export LC_CTYPE=C
	export PKG_CONFIG_PATH="${TMPDIR}/openssl-${OPENSSL_VERNUM}-tvOS-${ARCH}"/lib/pkgconfig:"${PWD}/../nghttp3/tvOS/${ARCH}"/lib/pkgconfig

	echo -e "${subbold}Building ${NGTCP2_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS ${TVOS_MIN_SDK_VERSION})"

	# Patch apps/speed.c to not use fork() since it's not available on tvOS
	# LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "./apps/speed.c"

	# Patch Configure to build for tvOS, not iOS
	# LANG=C sed -i -- 's/D\_REENTRANT\:iOS/D\_REENTRANT\:tvOS/' "./Configure"
	# chmod u+x ./Configure

	./configure --disable-shared --disable-app --disable-threads --enable-lib-only --prefix="${NGTCP2}/tvOS/${ARCH}" --host="arm-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"
	LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "config.h"

	# add -isysroot to CC=
	#sed -ie "s!^CFLAG=!CFLAG=-isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} !" "Makefile"

	make -j8 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"
	make install  2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
	export PKG_CONFIG_PATH=""
}

buildTVOSsim()
{
	ARCH=$1

	pushd . > /dev/null
	cd "${NGTCP2_VERSION}"
	autoreconf -fi 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-simulator${ARCH}.log"

	PLATFORM="AppleTVSimulator"

	TARGET="darwin64-${ARCH}-cc"
	RUNTARGET="-target ${ARCH}-apple-tvos${TVOS_MIN_SDK_VERSION}-simulator"

	export $PLATFORM
	export SYSROOT=$(xcrun --sdk appletvsimulator --show-sdk-path)
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${SYSROOT} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} -fembed-bitcode ${RUNTARGET}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${SYSROOT} ${NGTCP2LIB}"
	export LC_CTYPE=C
	export PKG_CONFIG_PATH="${TMPDIR}/openssl-${OPENSSL_VERNUM}-tvOS-Simulator-${ARCH}"/lib/pkgconfig:"${PWD}/../nghttp3/tvOS-simulator/${ARCH}"/lib/pkgconfig

	echo -e "${subbold}Building ${NGTCP2_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS Simulator ${TVOS_MIN_SDK_VERSION})"

	# Patch apps/speed.c to not use fork() since it's not available on tvOS
	# LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "./apps/speed.c"

	# Patch Configure to build for tvOS, not iOS
	# LANG=C sed -i -- 's/D\_REENTRANT\:iOS/D\_REENTRANT\:tvOS/' "./Configure"
	# chmod u+x ./Configure

	if [[ "${ARCH}" == "arm64" ]]; then
	./configure --disable-shared --disable-app --disable-threads --enable-lib-only  --prefix="${NGTCP2}/tvOS-simulator/${ARCH}" --host="arm-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-simulator${ARCH}.log"
	else
	./configure --disable-shared --disable-app --disable-threads --enable-lib-only  --prefix="${NGTCP2}/tvOS-simulator/${ARCH}" --host="${ARCH}-apple-darwin" 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-simulator${ARCH}.log"
	fi

	LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "config.h"

	# add -isysroot to CC=
	#sed -ie "s!^CFLAG=!CFLAG=-isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} !" "Makefile"

	make -j8 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"
	make install  2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"
	make clean 2>&1 | tee -a "${TMPDIR}/${NGTCP2_VERSION}-tvOS-${ARCH}.log"
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
	export PKG_CONFIG_PATH=""
}

echo -e "${bold}Cleaning up${dim}"
rm -rf include/ngtcp2/* lib/*
rm -fr Mac
rm -fr iOS
rm -fr tvOS
rm -fr Catalyst

mkdir -p lib
mkdir -p Mac
mkdir -p iOS
mkdir -p tvOS
mkdir -p Catalyst

rm -rf "${TMPDIR}/${NGTCP2_VERSION}-*"
rm -rf "${TMPDIR}/${NGTCP2_VERSION}-*.log"

rm -rf "${NGTCP2_VERSION}"

if [ ! -e ${NGTCP2_VERSION}.tar.gz ]; then
	echo "Downloading ${NGTCP2_VERSION}.tar.gz"
	curl -Ls -o "${NGTCP2_VERSION}.tar.gz.tmp" https://github.com/ngtcp2/ngtcp2/archive/refs/tags/v${NGTCP2_VERNUM}.tar.gz
	mv "${NGTCP2_VERSION}.tar.gz.tmp" "${NGTCP2_VERSION}.tar.gz"
else
	echo "Using ${NGTCP2_VERSION}.tar.gz"
fi

echo "Unpacking ngtcp2"
tar xfz "${NGTCP2_VERSION}.tar.gz"

echo -e "${bold}Building Mac libraries${dim}"
buildMac "x86_64"
buildMac "arm64"

lipo \
        "${NGTCP2}/Mac/x86_64/lib/libngtcp2.a" \
		"${NGTCP2}/Mac/arm64/lib/libngtcp2.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_Mac.a"
lipo \
        "${NGTCP2}/Mac/x86_64/lib/libngtcp2_crypto_openssl.a" \
		"${NGTCP2}/Mac/arm64/lib/libngtcp2_crypto_openssl.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_Mac.a"

if [ $catalyst == "1" ]; then
echo -e "${bold}Building Catalyst libraries${dim}"
buildCatalyst "x86_64"
buildCatalyst "arm64"

lipo \
        "${NGTCP2}/Catalyst/x86_64/lib/libngtcp2.a" \
		"${NGTCP2}/Catalyst/arm64/lib/libngtcp2.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_Catalyst.a"
lipo \
        "${NGTCP2}/Catalyst/x86_64/lib/libngtcp2_crypto_openssl.a" \
		"${NGTCP2}/Catalyst/arm64/lib/libngtcp2_crypto_openssl.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_Catalyst.a"
fi

echo -e "${bold}Building iOS libraries (bitcode)${dim}"
buildIOS "armv7" "bitcode"
buildIOS "armv7s" "bitcode"
buildIOS "arm64" "bitcode"
buildIOS "arm64e" "bitcode"

buildIOSsim "x86_64" "bitcode"
buildIOSsim "arm64" "bitcode"
buildIOSsim "i386" "bitcode"

lipo \
	"${NGTCP2}/iOS/armv7/lib/libngtcp2.a" \
	"${NGTCP2}/iOS/armv7s/lib/libngtcp2.a" \
	"${NGTCP2}/iOS-simulator/i386/lib/libngtcp2.a" \
	"${NGTCP2}/iOS/arm64/lib/libngtcp2.a" \
	"${NGTCP2}/iOS/arm64e/lib/libngtcp2.a" \
	"${NGTCP2}/iOS-simulator/x86_64/lib/libngtcp2.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_iOS-fat.a"
lipo \
	"${NGTCP2}/iOS/armv7/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS/armv7s/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS-simulator/i386/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS/arm64/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS/arm64e/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS-simulator/x86_64/lib/libngtcp2_crypto_openssl.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_iOS-fat.a"

lipo \
	"${NGTCP2}/iOS/armv7/lib/libngtcp2.a" \
	"${NGTCP2}/iOS/armv7s/lib/libngtcp2.a" \
	"${NGTCP2}/iOS/arm64/lib/libngtcp2.a" \
	"${NGTCP2}/iOS/arm64e/lib/libngtcp2.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_iOS.a"
lipo \
	"${NGTCP2}/iOS/armv7/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS/armv7s/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS/arm64/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS/arm64e/lib/libngtcp2_crypto_openssl.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_iOS.a"

lipo \
	"${NGTCP2}/iOS-simulator/i386/lib/libngtcp2.a" \
	"${NGTCP2}/iOS-simulator/x86_64/lib/libngtcp2.a" \
	"${NGTCP2}/iOS-simulator/arm64/lib/libngtcp2.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_iOS-simulator.a"
lipo \
	"${NGTCP2}/iOS-simulator/i386/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS-simulator/x86_64/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/iOS-simulator/arm64/lib/libngtcp2_crypto_openssl.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_iOS-simulator.a"

echo -e "${bold}Building tvOS libraries${dim}"
buildTVOS "arm64"

lipo \
        "${NGTCP2}/tvOS/arm64/lib/libngtcp2.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_tvOS.a"
lipo \
        "${NGTCP2}/tvOS/arm64/lib/libngtcp2_crypto_openssl.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_tvOS.a"

buildTVOSsim "x86_64"
buildTVOSsim "arm64"

lipo \
        "${NGTCP2}/tvOS/arm64/lib/libngtcp2.a" \
        "${NGTCP2}/tvOS-simulator/x86_64/lib/libngtcp2.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_tvOS-fat.a"
lipo \
        "${NGTCP2}/tvOS/arm64/lib/libngtcp2_crypto_openssl.a" \
        "${NGTCP2}/tvOS-simulator/x86_64/lib/libngtcp2_crypto_openssl.a" \
        -create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_tvOS-fat.a"

lipo \
	"${NGTCP2}/tvOS-simulator/x86_64/lib/libngtcp2.a" \
	"${NGTCP2}/tvOS-simulator/arm64/lib/libngtcp2.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_tvOS-simulator.a"
lipo \
	"${NGTCP2}/tvOS-simulator/x86_64/lib/libngtcp2_crypto_openssl.a" \
	"${NGTCP2}/tvOS-simulator/arm64/lib/libngtcp2_crypto_openssl.a" \
	-create -output "${NGTCP2}/lib/libngtcp2_crypto_openssl_tvOS-simulator.a"

echo -e "${bold}Cleaning up${dim}"
rm -rf ${TMPDIR}/${NGTCP2_VERSION}-*
rm -rf ${NGTCP2_VERSION}

#reset trap
trap - INT TERM EXIT

echo -e "${normal}Done"

