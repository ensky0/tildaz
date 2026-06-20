#!/usr/bin/env bash
# tildaz Linux 릴리즈 artifact 생성 — 4 format 통합 entry.
#
# 입력:
#   --version <ver>                          필수 (예: 0.4.3)
#   --arch x86_64|aarch64                    필수
#   --format tar.gz|deb|rpm|AppImage         필수
#   --bindir <dir>                           optional. 기본 zig-out/bin/
#
# 산출물 (zig-out/release/):
#   tar.gz   → tildaz-v<ver>-linux-<arch>.tar.gz
#   deb      → tildaz_<ver>_<debarch>.deb   (debarch: x86_64→amd64, aarch64→arm64)
#   rpm      → tildaz-<ver>-1.<arch>.rpm
#   AppImage → TildaZ-<ver>-<arch>.AppImage
#
# 각 옆에 .sha256 sidecar 생성 (GNU sha256sum -c 호환).
#
# 호스트 의존성 (format 별):
#   tar.gz   — tar / gzip / sha256sum (POSIX 표준)
#   deb      — dpkg-deb (Ubuntu / Debian runner 기본 포함)
#   rpm      — rpmbuild (apt install rpm 또는 RHEL 계열 native)
#   AppImage — appimagetool (없으면 자동 다운로드 — github continuous release)
#              FUSE 없이 --appimage-extract-and-run 으로 실행
#
# 사용법:
#   dist/linux/package.sh --version 0.4.3 --arch x86_64 --format tar.gz
#   dist/linux/package.sh --version 0.4.3 --arch aarch64 --format deb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION=""
ARCH=""
FORMAT=""
BINDIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --arch)    ARCH="$2";    shift 2 ;;
        --format)  FORMAT="$2";  shift 2 ;;
        --bindir)  BINDIR="$2";  shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -z "$VERSION" ]] && { echo "ERROR: --version required" >&2; exit 2; }
case "$ARCH" in
    x86_64|aarch64) ;;
    *) echo "ERROR: --arch must be x86_64 or aarch64 (got '$ARCH')" >&2; exit 2 ;;
esac
case "$FORMAT" in
    tar.gz|deb|rpm|AppImage|pkg) ;;
    *) echo "ERROR: --format must be tar.gz|deb|rpm|AppImage|pkg (got '$FORMAT')" >&2; exit 2 ;;
esac

BINDIR="${BINDIR:-$REPO_ROOT/zig-out/bin}"
BINARY="$BINDIR/tildaz"
if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: tildaz binary not found at $BINARY" >&2
    echo "       Run 'zig build -Dtarget=${ARCH}-linux-gnu' first" >&2
    exit 1
fi

ICON_SRC="$REPO_ROOT/docs/favicon.svg"
DESKTOP_TEMPLATE="$SCRIPT_DIR/tildaz.desktop"
RELEASE_ROOT="$REPO_ROOT/zig-out/release"
mkdir -p "$RELEASE_ROOT"

# sha256sum sidecar 생성 helper — `sha256sum -c` 호환 포맷.
write_sha256() {
    local target="$1"
    (cd "$(dirname "$target")" && sha256sum "$(basename "$target")") > "$target.sha256"
}

#-----------------------------------------------------------------------
# Format: tar.gz — portable, distro 독립. extract → install.sh.
#-----------------------------------------------------------------------
build_tar_gz() {
    local NAME="tildaz-v${VERSION}-linux-${ARCH}"
    local STAGE="$RELEASE_ROOT/$NAME"
    local TARBALL="$RELEASE_ROOT/${NAME}.tar.gz"

    rm -rf "$STAGE" "$TARBALL" "$TARBALL.sha256"
    mkdir -p "$STAGE"

    cp "$BINARY" "$STAGE/tildaz"
    chmod 755 "$STAGE/tildaz"
    # .desktop template 의 __TILDAZ_EXE__ 는 install.sh 가 사용자 환경의 binary
    # 절대 경로로 치환 — tarball 안에선 그대로 둠.
    cp "$DESKTOP_TEMPLATE" "$STAGE/tildaz.desktop"
    cp "$ICON_SRC" "$STAGE/tildaz.svg"
    cp "$SCRIPT_DIR/install.sh" "$STAGE/install.sh"
    cp "$SCRIPT_DIR/uninstall.sh" "$STAGE/uninstall.sh" 2>/dev/null || true
    chmod 755 "$STAGE/install.sh"
    [[ -f "$STAGE/uninstall.sh" ]] && chmod 755 "$STAGE/uninstall.sh"

    cat > "$STAGE/README.txt" << END
tildaz v${VERSION} (linux-${ARCH})

Install (user-level, no sudo):
  ./install.sh

  → ~/.local/share/applications/tildaz.desktop  (sed-substituted)
  → ~/.local/share/icons/hicolor/scalable/apps/tildaz.svg

The tildaz binary stays in this directory by default. Move it
to a PATH location (e.g. /usr/local/bin/) if you prefer, then
re-run:
  ./install.sh --exe /usr/local/bin/tildaz

Uninstall:
  ./uninstall.sh

Config: ~/.config/tildaz/config.json (auto-created on first run)
Log:    ~/.config/tildaz/tildaz.log

GitHub: https://github.com/ensky0/tildaz
END

    tar -C "$RELEASE_ROOT" -czf "$TARBALL" "$NAME"
    rm -rf "$STAGE"
    write_sha256 "$TARBALL"
    echo "--- Output ---"
    ls -l "$TARBALL" "$TARBALL.sha256"
}

#-----------------------------------------------------------------------
# Format: deb — Debian / Ubuntu / Mint.
#-----------------------------------------------------------------------
build_deb() {
    command -v dpkg-deb >/dev/null 2>&1 || {
        echo "ERROR: dpkg-deb not found. apt-get install dpkg-dev" >&2
        exit 1
    }
    local DEBARCH
    case "$ARCH" in
        x86_64)  DEBARCH="amd64" ;;
        aarch64) DEBARCH="arm64" ;;
    esac
    local DEB="$RELEASE_ROOT/tildaz_${VERSION}_${DEBARCH}.deb"
    local STAGE="$RELEASE_ROOT/deb-stage-${ARCH}"

    rm -rf "$STAGE" "$DEB" "$DEB.sha256"
    mkdir -p "$STAGE/DEBIAN"
    mkdir -p "$STAGE/usr/bin"
    mkdir -p "$STAGE/usr/share/applications"
    mkdir -p "$STAGE/usr/share/icons/hicolor/scalable/apps"
    mkdir -p "$STAGE/usr/share/doc/tildaz"

    install -m 755 "$BINARY" "$STAGE/usr/bin/tildaz"
    # 시스템 install — Exec 절대 경로 /usr/bin/tildaz 로 치환.
    sed "s|__TILDAZ_EXE__|/usr/bin/tildaz|" "$DESKTOP_TEMPLATE" \
        > "$STAGE/usr/share/applications/tildaz.desktop"
    chmod 644 "$STAGE/usr/share/applications/tildaz.desktop"
    install -m 644 "$ICON_SRC" "$STAGE/usr/share/icons/hicolor/scalable/apps/tildaz.svg"
    if [[ -f "$REPO_ROOT/LICENSE" ]]; then
        install -m 644 "$REPO_ROOT/LICENSE" "$STAGE/usr/share/doc/tildaz/copyright"
    fi

    local INSTALLED_SIZE
    INSTALLED_SIZE=$(du -sk --apparent-size "$STAGE/usr" | cut -f1)

    cat > "$STAGE/DEBIAN/control" << END
Package: tildaz
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEBARCH}
Installed-Size: ${INSTALLED_SIZE}
Depends: libxkbcommon0, libfreetype6, libfontconfig1
Recommends: libharfbuzz0b, libdbus-1-3, libglib2.0-0, xdg-desktop-portal
Maintainer: ensky0 <bongjun.yi@navercorp.com>
Homepage: https://github.com/ensky0/tildaz
Description: Quake-style drop-down terminal for Wayland
 TildaZ is a drop-down terminal with native Wayland support
 (layer-shell) and HarfBuzz-based ligature rendering. Cross-platform
 with Windows and macOS using the same ghostty-vt terminal core.
END

    cat > "$STAGE/DEBIAN/postinst" << 'END'
#!/bin/sh
set -e
if [ -x /usr/bin/update-desktop-database ]; then
    /usr/bin/update-desktop-database -q /usr/share/applications || true
fi
if [ -x /usr/bin/gtk-update-icon-cache ]; then
    /usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
END
    chmod 755 "$STAGE/DEBIAN/postinst"

    cat > "$STAGE/DEBIAN/postrm" << 'END'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    if [ -x /usr/bin/update-desktop-database ]; then
        /usr/bin/update-desktop-database -q /usr/share/applications || true
    fi
    if [ -x /usr/bin/gtk-update-icon-cache ]; then
        /usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
    fi
fi
END
    chmod 755 "$STAGE/DEBIAN/postrm"

    dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
    rm -rf "$STAGE"
    write_sha256 "$DEB"
    echo "--- Output ---"
    ls -l "$DEB" "$DEB.sha256"
}

#-----------------------------------------------------------------------
# Format: rpm — Fedora / RHEL / openSUSE.
#-----------------------------------------------------------------------
build_rpm() {
    command -v rpmbuild >/dev/null 2>&1 || {
        echo "ERROR: rpmbuild not found. apt-get install rpm  (Ubuntu)  /  dnf install rpm-build  (Fedora)" >&2
        exit 1
    }
    local RPMARCH="$ARCH"  # rpm 이 x86_64 / aarch64 그대로 사용
    local RPM="$RELEASE_ROOT/tildaz-${VERSION}-1.${RPMARCH}.rpm"
    local RPMTREE="$RELEASE_ROOT/rpmtree-${ARCH}"

    rm -rf "$RPMTREE" "$RPM" "$RPM.sha256"
    mkdir -p "$RPMTREE"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

    # SOURCES 에 binary / icon / desktop (사전 치환) 복사 — spec 의 %install 이
    # 여기서 buildroot 로 install.
    install -m 755 "$BINARY" "$RPMTREE/SOURCES/tildaz"
    install -m 644 "$ICON_SRC" "$RPMTREE/SOURCES/tildaz.svg"
    sed "s|__TILDAZ_EXE__|/usr/bin/tildaz|" "$DESKTOP_TEMPLATE" \
        > "$RPMTREE/SOURCES/tildaz.desktop"
    chmod 644 "$RPMTREE/SOURCES/tildaz.desktop"

    cat > "$RPMTREE/SPECS/tildaz.spec" << END
Name:           tildaz
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Quake-style drop-down terminal for Wayland

License:        GPL-3.0-or-later AND LicenseRef-Commons-Clause
URL:            https://github.com/ensky0/tildaz
BuildArch:      ${RPMARCH}
# native 의존성은 모두 runtime dlopen 이라 rpmbuild 자동 dep 추출은 비활성.
AutoReqProv:    no
# 단, core 라이브러리(키보드/폰트)는 명시 Requires. distro 간 패키지명 차이
# (Fedora freetype ↔ openSUSE libfreetype6) 를 피하려 이름 대신 SONAME
# capability 를 쓴다 — rpm 이 각 lib 에 대해 자동 Provides 하므로 distro 무관.
# ligature / hotkey 용 lib 와 portal 서비스는 dlopen graceful degrade 라 weak Recommends.
Requires:       libxkbcommon.so.0()(64bit) libfreetype.so.6()(64bit) libfontconfig.so.1()(64bit)
Recommends:     libharfbuzz.so.0()(64bit) libdbus-1.so.3()(64bit) libgio-2.0.so.0()(64bit) xdg-desktop-portal

%description
TildaZ is a drop-down terminal with native Wayland support (layer-shell)
and HarfBuzz-based ligature rendering. Cross-platform with Windows and
macOS using the same ghostty-vt terminal core.

%install
install -D -m 0755 %{_sourcedir}/tildaz       %{buildroot}/usr/bin/tildaz
install -D -m 0644 %{_sourcedir}/tildaz.desktop %{buildroot}/usr/share/applications/tildaz.desktop
install -D -m 0644 %{_sourcedir}/tildaz.svg   %{buildroot}/usr/share/icons/hicolor/scalable/apps/tildaz.svg

%post
if [ -x /usr/bin/update-desktop-database ]; then
    /usr/bin/update-desktop-database -q /usr/share/applications || :
fi
if [ -x /usr/bin/gtk-update-icon-cache ]; then
    /usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || :
fi

%postun
if [ \$1 -eq 0 ]; then
    if [ -x /usr/bin/update-desktop-database ]; then
        /usr/bin/update-desktop-database -q /usr/share/applications || :
    fi
    if [ -x /usr/bin/gtk-update-icon-cache ]; then
        /usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || :
    fi
fi

%files
/usr/bin/tildaz
/usr/share/applications/tildaz.desktop
/usr/share/icons/hicolor/scalable/apps/tildaz.svg
END

    # Ubuntu runner 환경에선 dist tag 가 안 붙어 출력 이름이 tildaz-<ver>-1.<arch>.rpm.
    # %{?dist} 를 빈 string 으로 강제 — 출력 이름 결정적 (RHEL native 빌드 시 'el8' 등 추가 회피).
    #
    # cross-arch (Ubuntu x86_64 runner 에서 aarch64 target rpm 빌드) 시
    # `rpmbuild --target aarch64` 만으로는 ubuntu rpm package 의 `/usr/lib/rpm/platform`
    # table 에 aarch64-linux entry 가 없어 `No compatible architectures found
    # for build` fail. `_target_cpu` / `_target_os` / `_target_platform` 명시로
    # platform lookup 우회.
    local RPM_TARGET_PLATFORM
    case "$RPMARCH" in
        x86_64)  RPM_TARGET_PLATFORM="x86_64-linux"  ;;
        aarch64) RPM_TARGET_PLATFORM="aarch64-linux" ;;
        *)       RPM_TARGET_PLATFORM="$RPMARCH-linux";;
    esac
    rpmbuild -bb \
        --define "_topdir $RPMTREE" \
        --define "dist %{nil}" \
        --define "_target_cpu $RPMARCH" \
        --define "_target_os linux" \
        --define "_target_platform $RPM_TARGET_PLATFORM" \
        --target "$RPMARCH" \
        "$RPMTREE/SPECS/tildaz.spec"

    local RPM_BUILT="$RPMTREE/RPMS/$RPMARCH/tildaz-${VERSION}-1.$RPMARCH.rpm"
    if [[ ! -f "$RPM_BUILT" ]]; then
        echo "ERROR: rpmbuild succeeded but expected output missing: $RPM_BUILT" >&2
        ls -la "$RPMTREE/RPMS/" >&2
        exit 1
    fi
    cp "$RPM_BUILT" "$RPM"
    rm -rf "$RPMTREE"
    write_sha256 "$RPM"
    echo "--- Output ---"
    ls -l "$RPM" "$RPM.sha256"
}

#-----------------------------------------------------------------------
# Format: AppImage — distro 독립 single-file.
#-----------------------------------------------------------------------
build_appimage() {
    local APPIMAGE="$RELEASE_ROOT/TildaZ-${VERSION}-${ARCH}.AppImage"
    local APPDIR="$RELEASE_ROOT/TildaZ-${ARCH}.AppDir"

    rm -rf "$APPDIR" "$APPIMAGE" "$APPIMAGE.sha256"
    mkdir -p "$APPDIR/usr/bin"
    mkdir -p "$APPDIR/usr/share/applications"
    mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/apps"

    install -m 755 "$BINARY" "$APPDIR/usr/bin/tildaz"
    install -m 644 "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/scalable/apps/tildaz.svg"

    # AppImage 가 root 의 .desktop / icon symlink 자동 인식. Exec 은 단순
    # "tildaz" — AppRun 이 PATH 에 usr/bin 추가하거나 직접 호출.
    cat > "$APPDIR/tildaz.desktop" << END
[Desktop Entry]
Type=Application
Name=TildaZ
GenericName=Drop-down Terminal
Comment=Quake-style drop-down terminal for Wayland
Exec=tildaz
Icon=tildaz
Terminal=false
Categories=System;TerminalEmulator;
StartupWMClass=tildaz
StartupNotify=true
END
    # AppImage root icon — appimagetool 가 hicolor 트리에 자동 인식 시켰지만
    # 일부 환경에서 fallback 용으로 root 에 직접 둠.
    cp "$ICON_SRC" "$APPDIR/tildaz.svg"

    cat > "$APPDIR/AppRun" << 'END'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/tildaz" "$@"
END
    chmod 755 "$APPDIR/AppRun"

    # appimagetool 위치 — 시스템 / 캐시 / 다운로드 순.
    local APPIMAGETOOL
    APPIMAGETOOL="$(command -v appimagetool || echo "")"
    if [[ -z "$APPIMAGETOOL" ]]; then
        # host arch 의 appimagetool — target arch 와 별개. host x86_64 에서
        # target aarch64 AppImage 도 만들 수 있음 (runtime 만 target arch).
        local HOST_ARCH
        HOST_ARCH=$(uname -m)
        case "$HOST_ARCH" in
            x86_64|aarch64) ;;
            *) echo "ERROR: unsupported host arch '$HOST_ARCH' for appimagetool" >&2; exit 1 ;;
        esac
        APPIMAGETOOL="$RELEASE_ROOT/appimagetool-${HOST_ARCH}.AppImage"
        if [[ ! -x "$APPIMAGETOOL" ]]; then
            local URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${HOST_ARCH}.AppImage"
            echo "Downloading appimagetool from $URL"
            curl -sSL -o "$APPIMAGETOOL" "$URL"
            chmod +x "$APPIMAGETOOL"
        fi
    fi

    # ARCH env 가 AppImage runtime 의 arch 결정. FUSE 없는 CI 에선
    # --appimage-extract-and-run 으로 self-mount 회피.
    ARCH="$ARCH" "$APPIMAGETOOL" --appimage-extract-and-run "$APPDIR" "$APPIMAGE"
    rm -rf "$APPDIR"
    write_sha256 "$APPIMAGE"
    echo "--- Output ---"
    ls -l "$APPIMAGE" "$APPIMAGE.sha256"
}

#-----------------------------------------------------------------------
# Format: pkg — Arch Linux (.pkg.tar.zst via makepkg). x86_64 전용.
# (Arch 공식 아키텍처는 x86_64 뿐 — aarch64 는 Arch Linux ARM 별도 프로젝트.)
# makepkg 는 root 로 실행을 거부 → CI 는 비root builder 로 호출 (release.yml
# build-arch job). 우린 이미 빌드된 $BINARY 를 -bin 방식으로 패키징만 한다.
#-----------------------------------------------------------------------
build_pkg() {
    command -v makepkg >/dev/null 2>&1 || {
        echo "ERROR: makepkg not found — Arch package needs base-devel (pacman -S base-devel)" >&2
        exit 1
    }
    if [[ "$ARCH" != "x86_64" ]]; then
        echo "ERROR: Arch .pkg only supports x86_64 (got '$ARCH')" >&2
        exit 1
    fi
    local BUILD="$RELEASE_ROOT/arch-build"
    local PKG="$RELEASE_ROOT/tildaz-${VERSION}-1-x86_64.pkg.tar.zst"

    rm -rf "$BUILD" "$PKG" "$PKG.sha256"
    mkdir -p "$BUILD"

    cp "$BINARY" "$BUILD/tildaz"
    cp "$DESKTOP_TEMPLATE" "$BUILD/tildaz.desktop"
    cp "$ICON_SRC" "$BUILD/tildaz.svg"

    # 의존성은 deb/rpm 과 동일 정책: core(키보드/폰트) hard depends, ligature/
    # hotkey 용은 optdepends (dlopen graceful). \$srcdir / \$pkgdir 는 makepkg
    # 런타임 변수라 heredoc 에서 escape — \${VERSION} 만 여기서 확장.
    cat > "$BUILD/PKGBUILD" << END
# Maintainer: ensky0 <bongjun.yi@navercorp.com>
pkgname=tildaz
pkgver=${VERSION}
pkgrel=1
pkgdesc='Quake-style drop-down terminal for Wayland'
arch=('x86_64')
url='https://github.com/ensky0/tildaz'
license=('GPL3' 'custom:Commons-Clause')
depends=('libxkbcommon' 'freetype2' 'fontconfig')
optdepends=('harfbuzz: ligature rendering'
            'dbus: KDE portal / KGlobalAccel global hotkey'
            'glib2: GNOME/Cinnamon gsettings global hotkey'
            'xdg-desktop-portal: portal-based global hotkey')
source=('tildaz' 'tildaz.desktop' 'tildaz.svg')
sha256sums=('SKIP' 'SKIP' 'SKIP')
options=('!strip' '!debug')
package() {
  install -Dm755 "\$srcdir/tildaz"         "\$pkgdir/usr/bin/tildaz"
  install -Dm644 "\$srcdir/tildaz.desktop" "\$pkgdir/usr/share/applications/tildaz.desktop"
  install -Dm644 "\$srcdir/tildaz.svg"     "\$pkgdir/usr/share/icons/hicolor/scalable/apps/tildaz.svg"
}
END

    # --noextract: source 가 로컬 복사본이라 추출 불필요. --nodeps: 빌드 호스트에
    # depends 설치 안 함 (패키징만). --nosign: 서명 skip. PKGDEST 로 출력 고정.
    #
    # makepkg 는 root 실행을 거부한다. CI(archlinux 컨테이너)는 root 라 비root
    # `builder` 유저로 떨어뜨려 실행 (root 는 무암호 sudo 가능). 로컬에서 비root
    # 로 돌리면 그대로 직접 실행.
    if [[ "$(id -u)" -eq 0 ]]; then
        id builder >/dev/null 2>&1 || useradd -m builder
        chown -R builder:builder "$BUILD"
        sudo -u builder env PKGDEST="$BUILD" bash -c "cd '$BUILD' && makepkg -f --noextract --nodeps --nosign"
    else
        ( cd "$BUILD" && PKGDEST="$BUILD" makepkg -f --noextract --nodeps --nosign )
    fi

    local OUT
    OUT=$(ls "$BUILD"/tildaz-${VERSION}-1-x86_64.pkg.tar.zst 2>/dev/null | head -1)
    if [[ -z "$OUT" ]]; then
        echo "ERROR: makepkg did not produce the expected package" >&2
        ls -la "$BUILD" >&2
        exit 1
    fi
    mv "$OUT" "$PKG"
    rm -rf "$BUILD"
    write_sha256 "$PKG"
    echo "--- Output ---"
    ls -l "$PKG" "$PKG.sha256"
}

case "$FORMAT" in
    tar.gz)   build_tar_gz ;;
    deb)      build_deb ;;
    rpm)      build_rpm ;;
    AppImage) build_appimage ;;
    pkg)      build_pkg ;;
esac
