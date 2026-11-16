#!/bin/sh
# Build the Xclipse RADV driver for Android (arm64) and package it as an
# AdrenoTools-style installable zip (meta.json + driver .so + NOTICE.txt),
# for emulators and apps that load custom Vulkan drivers via libadrenotools.
#
# usage: ./build-adrenotools.sh [--opengl] [--api LEVEL] [--build-type release|debug] [path-to-android-ndk]
#   The NDK can also come from ANDROID_NDK_HOME or ANDROID_NDK_ROOT.
#   --opengl also builds Zink (OpenGL on Vulkan) with EGL and GLESv2 and
#   packages those libraries in the zip.
#   --api LEVEL compiles against that Android API level (default 34, also
#   settable with MIN_API) and writes it as minApi in meta.json. The NDK must
#   ship a compiler for that level, and the driver then requires it or newer.
#   --build-type release|debug selects meson's build type (default: debug;
#   use release for the driver distributed through libadrenotools). It is
#   also settable with MESA_BUILD_TYPE.
#   BUILD_DIR overrides the build directory (default: build-android-adrenotools,
#   build-android-adrenotools-opengl with --opengl).
#   DIST_DIR overrides the output directory (default: dist).
#   RADV_SO, when set to an existing libvulkan_radeon.so, skips the whole
#   build and only (re)packages that file.
#   AUTHOR, PACKAGE_VERSION and MIN_API override the meta.json fields
#   (defaults: JesusChapman, YYYYMMDD, 34).
# Requires: meson, ninja, python3, glslangValidator, zip, and the NDK's
# llvm-strip (the last two only when actually building).
set -eu

cd "$(dirname "$0")/.."

OPENGL=0
NDK_ARG=""
API_ARG=""
BUILD_TYPE_ARG=""
GL_LIBS=""
while [ $# -gt 0 ]; do
	case "$1" in
	--opengl)
		OPENGL=1
		;;
	--api)
		if [ $# -lt 2 ]; then
			echo "error: --api needs an API level" >&2
			exit 1
		fi
		API_ARG="$2"
		shift
		;;
	--api=*)
		API_ARG="${1#--api=}"
		;;
	--build-type)
		if [ $# -lt 2 ]; then
			echo "error: --build-type needs a value (release or debug)" >&2
			exit 1
		fi
		BUILD_TYPE_ARG="$2"
		shift
		;;
	--build-type=*)
		BUILD_TYPE_ARG="${1#--build-type=}"
		;;
	-*)
		echo "error: unknown option $1 (supported: --opengl, --api LEVEL, --build-type release|debug)" >&2
		exit 1
		;;
	*)
		if [ -n "$NDK_ARG" ]; then
			echo "error: unexpected argument $1" >&2
			exit 1
		fi
		NDK_ARG="$1"
		;;
	esac
	shift
done

API="${API_ARG:-${MIN_API:-34}}"
case "$API" in
'' | *[!0-9]*)
	echo "error: invalid API level '$API' (expected a number, e.g. 34)" >&2
	exit 1
	;;
esac
MESA_BUILD_TYPE="${BUILD_TYPE_ARG:-${MESA_BUILD_TYPE:-debug}}"
case "$MESA_BUILD_TYPE" in
release | debug) ;;
*)
	echo "error: invalid --build-type '$MESA_BUILD_TYPE' (release or debug)" >&2
	exit 1
	;;
esac

if [ -n "${RADV_SO:-}" ]; then
	if [ ! -f "$RADV_SO" ]; then
		echo "error: RADV_SO=$RADV_SO not found" >&2
		exit 1
	fi
	NDK=""
else
	NDK="${NDK_ARG:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
	if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
		echo "error: pass the Android NDK path or set ANDROID_NDK_HOME" >&2
		exit 1
	fi
fi

case "$(uname -s)" in
Linux*)
	HOST=linux-x86_64
	EXE=
	WRAP=
	;;
Darwin*)
	HOST=darwin-x86_64
	EXE=
	WRAP=
	;;
MINGW* | MSYS* | CYGWIN*)
	HOST=windows-x86_64
	EXE=.exe
	WRAP=.cmd
	;;
*)
	echo "error: unsupported host $(uname -s)" >&2
	exit 1
	;;
esac

# Newer NDKs ship native arm64 prebuilts on Apple Silicon Macs.
if [ -n "$NDK" ] && [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] &&
	[ -d "$NDK/toolchains/llvm/prebuilt/darwin-aarch64" ]; then
	HOST=darwin-aarch64
fi

PYTHON=python3
command -v "$PYTHON" >/dev/null 2>&1 || PYTHON=python
for tool in "$PYTHON" zip; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: $tool not found in PATH" >&2
		exit 1
	fi
done

if [ -n "${BUILD_DIR:-}" ]; then
	BUILD="$BUILD_DIR"
elif [ "$OPENGL" = 1 ]; then
	BUILD=build-android-adrenotools-opengl
else
	BUILD=build-android-adrenotools
fi
DIST="${DIST_DIR:-dist}"
mkdir -p "$BUILD" "$DIST"
case "$DIST" in
/*) ;;
*) DIST="$(pwd)/$DIST" ;;
esac

if [ -z "${RADV_SO:-}" ]; then
	for tool in meson ninja glslangValidator; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "error: $tool not found in PATH" >&2
			exit 1
		fi
	done

	# Never reuse a build directory configured for another NDK, API level or
	# library set: meson setup keeps the old options and would silently build
	# for the previous configuration.
	BUILD_CONFIG="ndk=$(basename "$NDK") host=$HOST api=$API opengl=$OPENGL buildtype=$MESA_BUILD_TYPE"
	if [ -f "$BUILD/.xclipse-build-config" ]; then
		if [ "$(cat "$BUILD/.xclipse-build-config")" != "$BUILD_CONFIG" ]; then
			echo "build configuration changed (was: $(cat "$BUILD/.xclipse-build-config"))"
			echo "discarding $BUILD and configuring from scratch"
			rm -rf "$BUILD"
			mkdir -p "$BUILD"
		fi
	elif [ -f "$BUILD/build.ninja" ] || [ -d "$BUILD/meson-private" ]; then
		echo "discarding $BUILD: configuration unknown (no .xclipse-build-config)"
		rm -rf "$BUILD"
		mkdir -p "$BUILD"
	fi

	BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
	if [ ! -e "$BIN/aarch64-linux-android$API-clang$WRAP" ]; then
		echo "error: NDK has no arm64 compiler for API $API in $BIN" >&2
		echo "available levels: $(ls "$BIN" | sed -n 's/^aarch64-linux-android\([0-9][0-9]*\)-clang.*/\1/p' | sort -n | uniq | tr '\n' ' ')" >&2
		exit 1
	fi
	if [ ! -f "$BIN/llvm-strip$EXE" ]; then
		echo "error: llvm-strip not found in $BIN" >&2
		exit 1
	fi

	cat >"$BUILD/cross.ini" <<EOF
[binaries]
c = '$BIN/aarch64-linux-android$API-clang$WRAP'
cpp = '$BIN/aarch64-linux-android$API-clang++$WRAP'
ar = '$BIN/llvm-ar$EXE'
strip = '$BIN/llvm-strip$EXE'

[properties]
cpp_link_args = ['-static-libstdc++']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

	if [ "$OPENGL" = 1 ]; then
		GALLIUM_DRIVERS=zink
		EGL_STATE=enabled
		GLES2_STATE=enabled
	else
		GALLIUM_DRIVERS=
		EGL_STATE=disabled
		GLES2_STATE=disabled
	fi

	if [ ! -f "$BUILD/build.ninja" ]; then
		meson setup "$BUILD" --cross-file "$BUILD/cross.ini" \
			-Dbuildtype=$MESA_BUILD_TYPE \
			-Dplatforms=android -Dplatform-sdk-version=$API -Dandroid-stub=true -Dandroid-strict=false \
			-Dandroid-libbacktrace=disabled \
			-Dvulkan-drivers=amd -Dgallium-drivers="$GALLIUM_DRIVERS" -Dvulkan-layers= -Dtools= \
			-Dllvm=disabled -Dzstd=disabled -Dlmsensors=disabled -Dperfetto=false \
			-Dglx=disabled -Dgbm=disabled -Degl="$EGL_STATE" -Dgles1=disabled -Dgles2="$GLES2_STATE" \
			-Dallow-fallback-for=libdrm,perfetto --force-fallback-for=expat,libdrm,zlib \
			-Dlibdrm:default_library=static -Dexpat:default_library=static -Dzlib:default_library=static \
			-Dc_args=-march=armv8.2-a -Dcpp_args=-march=armv8.2-a
		# Only a completed configure is safe to reuse.
		printf '%s\n' "$BUILD_CONFIG" >"$BUILD/.xclipse-build-config"
	fi

	if [ "$OPENGL" = 1 ]; then
		ninja -C "$BUILD"
	else
		ninja -C "$BUILD" src/amd/vulkan/libvulkan_radeon.so
	fi

	"$BIN/llvm-strip$EXE" -o "$BUILD/vulkan.radeon.so" "$BUILD/src/amd/vulkan/libvulkan_radeon.so"
	RADV_SO="$BUILD/vulkan.radeon.so"
	if [ "$OPENGL" = 1 ]; then
		for lib in $(find "$BUILD/src" -name 'libEGL.so' -o -name 'libGLESv2.so'); do
			"$BIN/llvm-strip$EXE" -o "$BUILD/$(basename "$lib")" "$lib"
		done
	fi
fi

# With --opengl, take matching EGL/GLES libraries from beside the driver .so.
if [ "$OPENGL" = 1 ]; then
	GL_DIR="$(dirname "$RADV_SO")"
	for lib in "$GL_DIR"/libEGL.so "$GL_DIR"/libGLESv2.so; do
		if [ -f "$lib" ] && [ "$(basename "$lib")" != "$(basename "$RADV_SO")" ]; then
			GL_LIBS="${GL_LIBS:+$GL_LIBS }$(basename "$lib")"
			if [ "$lib" != "$BUILD/$(basename "$lib")" ]; then
				cp "$lib" "$BUILD/$(basename "$lib")"
			fi
		fi
	done
	if [ -z "$GL_LIBS" ]; then
		echo "error: --opengl requested but no libEGL.so/libGLESv2.so next to $RADV_SO" >&2
		exit 1
	fi
fi

MESA_VERSION="$(cat VERSION)"
VK_HEADER="$(sed -n 's/^#define VK_HEADER_VERSION \([0-9]*\)/\1/p' include/vulkan/vulkan_core.h | head -n 1)"
DRIVER_VERSION="Vulkan 1.4.$VK_HEADER"
if git rev-parse --git-dir >/dev/null 2>&1; then
	COMMIT="$(git rev-parse --short HEAD)"
else
	COMMIT="nogit"
fi

AUTHOR="${AUTHOR:-JesusChapman}"
PACKAGE_VERSION="${PACKAGE_VERSION:-$(date +%Y%m%d)}"
LIBNAME="vulkan.radeon.so"

if [ "$OPENGL" = 1 ]; then
	ZIPNAME="radv-xclipse-driver+opengl-$MESA_VERSION-$COMMIT.zip"
	DRIVER_DESC="Vulkan and OpenGL ZInk driver only"
else
	ZIPNAME="radv-xclipse-driver-$MESA_VERSION-$COMMIT.zip"
	DRIVER_DESC="Vulkan driver only"
fi

"$PYTHON" - >"$BUILD/meta.json" <<EOF
import json
meta = {
    "schemaVersion": 1,
    "name": "RADV Samsung Xclipse (Mesa $MESA_VERSION)",
    "description": "AMD RADV for Samsung Xclipse GPUs on Android, $DRIVER_DESC",
    "author": "$AUTHOR",
    "packageVersion": "$PACKAGE_VERSION",
    "vendor": "Mesa",
    "driverVersion": "$DRIVER_VERSION",
    "minApi": $API,
    "libraryName": "$LIBNAME",
}
print(json.dumps(meta, indent=2))
EOF

cat >"$BUILD/NOTICE.txt" <<EOF
RADV Samsung Xclipse driver package
Based on Mesa $MESA_VERSION (https://mesa3d.org).
Mesa is MIT licensed; see https://docs.mesa3d.org/license.html
for the full license texts.
EOF

if [ "$RADV_SO" != "$BUILD/$LIBNAME" ]; then
	cp "$RADV_SO" "$BUILD/$LIBNAME"
fi
rm -f "$DIST/$ZIPNAME"
# shellcheck disable=SC2086 (intentional word splitting of $GL_LIBS)
(cd "$BUILD" && zip -j -q "$DIST/$ZIPNAME" meta.json "$LIBNAME" NOTICE.txt $GL_LIBS)
echo "wrote $DIST/$ZIPNAME"
