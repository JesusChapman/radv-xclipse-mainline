#!/bin/sh
# Build the Xclipse RADV driver for Android (arm64) and package it as an
# AdrenoTools-style installable zip (meta.json + driver .so + NOTICE.txt),
# for emulators and apps that load custom Vulkan drivers via libadrenotools.
#
# usage: ./build-adrenotools.sh [--opengl] [path-to-android-ndk]
#   The NDK can also come from ANDROID_NDK_HOME or ANDROID_NDK_ROOT.
#   --opengl also builds Zink (OpenGL on Vulkan) with EGL and GLESv2 and
#   packages those libraries in the zip.
#   BUILD_DIR overrides the build directory (default: build-android-adrenotools,
#   build-android-adrenotools-opengl with --opengl).
#   DIST_DIR overrides the output directory (default: dist).
#   RADV_SO, when set to an existing libvulkan_radeon.so, skips the whole
#   build and only (re)packages that file.
#   AUTHOR, PACKAGE_VERSION and MIN_API override the meta.json fields
#   (defaults: JimVulkan, YYYYMMDD, 34).
# Requires: meson, ninja, python3, glslangValidator, zip, and the NDK's
# llvm-strip (the last two only when actually building).
set -eu

cd "$(dirname "$0")/.."

OPENGL=0
NDK_ARG=""
GL_LIBS=""
for arg in "$@"; do
	case "$arg" in
	--opengl)
		OPENGL=1
		;;
	-*)
		echo "error: unknown option $arg (only --opengl is supported)" >&2
		exit 1
		;;
	*)
		if [ -n "$NDK_ARG" ]; then
			echo "error: unexpected argument $arg" >&2
			exit 1
		fi
		NDK_ARG="$arg"
		;;
	esac
done

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

	BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
	if [ ! -x "$BIN/aarch64-linux-android34-clang$WRAP" ] && [ ! -f "$BIN/aarch64-linux-android34-clang$WRAP" ]; then
		echo "error: no API 34 arm64 compiler in $BIN" >&2
		exit 1
	fi
	if [ ! -f "$BIN/llvm-strip$EXE" ]; then
		echo "error: llvm-strip not found in $BIN" >&2
		exit 1
	fi

	cat >"$BUILD/cross.ini" <<EOF
[binaries]
c = '$BIN/aarch64-linux-android34-clang$WRAP'
cpp = '$BIN/aarch64-linux-android34-clang++$WRAP'
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
			-Dbuildtype=debugoptimized -Db_ndebug=true \
			-Dplatforms=android -Dplatform-sdk-version=34 -Dandroid-stub=true -Dandroid-strict=false \
			-Dandroid-libbacktrace=disabled \
			-Dvulkan-drivers=amd -Dgallium-drivers="$GALLIUM_DRIVERS" -Dvulkan-layers= -Dtools= \
			-Dllvm=disabled -Dzstd=disabled -Dlmsensors=disabled -Dperfetto=false \
			-Dglx=disabled -Dgbm=disabled -Degl="$EGL_STATE" -Dgles1=disabled -Dgles2="$GLES2_STATE" \
			-Dallow-fallback-for=libdrm,perfetto --force-fallback-for=expat,libdrm,zlib \
			-Dlibdrm:default_library=static -Dexpat:default_library=static -Dzlib:default_library=static \
			-Dc_args=-march=armv8.2-a -Dcpp_args=-march=armv8.2-a
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
MIN_API="${MIN_API:-34}"
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
    "minApi": $MIN_API,
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
