#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

# --------------------------
# User-editable Variables
# --------------------------
MATCHA="${MATCHA:-/mnt/matcha}"
DISK="${DISK:-/dev/sda}"
ROOT_PART="${ROOT_PART:-}"
HOME_PART="${HOME_PART:-}"
SWAP_PART="${SWAP_PART:-}"
HOSTNAME="${HOSTNAME:-matcha}"
MATCHA_RELEASE="12.4"
KVER="${KVER:-6.16.1}"  # kernel version label
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/var/log/matcha-build}"

# --------------------------
# Constants & Sanity Checks
# --------------------------
: "${ROOT_PART:?Set ROOT_PART environment variable (e.g. /dev/sda2)}"
: "${HOME_PART:?Set HOME_PART environment variable (e.g. /dev/sda3)}"
: "${SWAP_PART:?Set SWAP_PART environment variable (e.g. /dev/sda1)}"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

mkdir -pv "$BUILD_LOG_DIR"

# --------------------------
# Helper Functions
# --------------------------

# Logging function
log() {
    echo "[$(date +%FT%T)] $*"
}

# Wrapper to run a step and use a marker file for resuming
run_step() {
    local id="$1"
    local func_name="$2"
    local marker="$MATCHA/.build_done_${id}"

    if [[ -f "$marker" ]]; then
        log "SKIP $id (already done)"
        return 0
    fi
    log "START $id"
    if "$func_name"; then
        touch "$marker"
        log "DONE $id"
    else
        log "FAIL $id"
        return 1
    fi
}

# Helper to find and extract a tarball from the sources directory
extract() {
    local arc="$1"
    if [[ -f "$arc" ]]; then
        tar -xf "$arc"
    else
        local found=("$MATCHA/sources"/$arc)
        if [[ ${#found[@]} -eq 0 ]]; then
            echo "Archive not found: $arc"
            return 1
        fi
        tar -xf "${found[0]}"
    fi
}

# Common build pattern: configure, make, make install
build_configure_make_install() {
    local pkgdir="$1"
    shift
    pushd "$pkgdir" >/dev/null
    ./configure "$@" 2>&1 | tee "$BUILD_LOG_DIR/${pkgdir}-configure.log"
    make -j"$(nproc)" 2>&1 | tee "$BUILD_LOG_DIR/${pkgdir}-make.log"
    make install 2>&1 | tee "$BUILD_LOG_DIR/${pkgdir}-install.log"
    popd >/dev/null
}

# Common build pattern: make, make install
build_make_install() {
    local pkgdir="$1"
    shift
    pushd "$pkgdir" >/dev/null
    make -j"$(nproc)" 2>&1 | tee "$BUILD_LOG_DIR/${pkgdir}-make.log"
    make install 2>&1 | tee "$BUILD_LOG_DIR/${pkgdir}-install.log"
    popd >/dev/null
}

# --------------------------
# Phase 1: Prepare Filesystems and Mounts
# --------------------------
prepare_filesystems() {
    log "Formatting and mounting filesystems."
    if ! blkid "$ROOT_PART" >/dev/null 2>&1; then mkfs -v -t ext4 "$ROOT_PART"; fi
    if ! blkid "$HOME_PART" >/dev/null 2>&1; then mkfs -v -t ext4 "$HOME_PART"; fi
    if ! swapon --show --noheadings | grep -q "^$SWAP_PART\$" 2>/dev/null; then mkswap "$SWAP_PART"; swapon "$SWAP_PART"; fi

    mkdir -pv "$MATCHA"
    mountpoint -q "$MATCHA" || mount -v -t ext4 "$ROOT_PART" "$MATCHA"
    mkdir -pv "$MATCHA"/home
    mountpoint -q "$MATCHA"/home || mount -v -t ext4 "$HOME_PART" "$MATCHA"/home
}

# --------------------------
# Phase 2: Base Directories, User, and Environment
# --------------------------
setup_matcha_user() {
    log "Setting up MATCHA base directories and user."
    chown root:root "$MATCHA"
    chmod 755 "$MATCHA"
    mkdir -pv "$MATCHA"/{sources,tools}
    chmod -v a+wt "$MATCHA"/sources

    getent group matcha >/dev/null || groupadd matcha
    id -u matcha >/dev/null 2>&1 || useradd -s /bin/bash -g matcha -m -k /dev/null matcha
    touch "$MATCHA"/.matcha_setup_done
}

write_matcha_profile() {
    log "Creating .bash_profile and .bashrc for the matcha user."
    sudo -u matcha bash -lc "
        cat > ~/.bash_profile <<'EOF'
exec env -i HOME=\$HOME TERM=\$TERM PS1=\"\\u:\\w\\$ \" /bin/bash
EOF
        cat > ~/.bashrc <<'EOF'
set +h
MATCHA=$MATCHA
LC_ALL=POSIX
MATCHA_TGT=$(uname -m)-matcha-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:\$PATH; fi
PATH=\$MATCHA/tools/bin:\$PATH
CONFIG_SITE=\$MATCHA/usr/share/config.site
export MATCHA LC_ALL MATCHA_TGT PATH CONFIG_SITE
EOF
        if command -v nproc >/dev/null 2>&1; then
            grep -q '^export MAKEFLAGS' ~/.bashrc || echo 'export MAKEFLAGS=-j$(nproc)' >> ~/.bashrc
        fi
    "
}

# --------------------------
# Phase 3: Mount Pseudo-Filesystems
# --------------------------
mount_pseudos() {
    log "Mounting pseudo-filesystems."
    mkdir -pv "$MATCHA"/{dev,proc,sys,run}
    mount -v --bind /dev "$MATCHA"/dev
    mount -vt devpts devpts -o gid=5,mode=0620 "$MATCHA"/dev/pts
    mount -vt proc proc "$MATCHA"/proc
    mount -vt sysfs sysfs "$MATCHA"/sys
    mount -vt tmpfs tmpfs "$MATCHA"/run
    if [ -h "$MATCHA"/dev/shm ]; then
        install -v -d -m 1777 "$MATCHA"$(realpath /dev/shm)
    else
        mount -vt tmpfs -o nosuid,nodev tmpfs "$MATCHA"/dev/shm || true
    fi
}

# --------------------------
# Phase 4 & 5: Build Initial Temporary Toolchain (Host-Side)
# --------------------------
build_temp_toolchain() {
    log "Building the initial temporary toolchain (Binutils, GCC, Glibc)."
    cd "$MATCHA"/sources
    if [[ -z $(ls -1) ]]; then
        echo "No sources found in $MATCHA/sources."
        exit 1
    fi

    # BINUTILS (Pass 1)
    extract binutils- || exit 1
    bdir=$(echo binutils-* | head -n1)
    mkdir -v build-binutils
    pushd build-binutils >/dev/null
    "../$bdir/configure" --prefix=/usr --enable-gold --enable-ld=default --enable-plugins --disable-werror
    make -j"$(nproc)"
    make install
    popd >/dev/null

    # GCC prerequisites (mpfr, gmp, mpc)
    extract mpfr- || true
    extract gmp- || true
    extract mpc- || true

    # GCC (Pass 1)
    extract gcc- || exit 1
    gdir=$(echo gcc-* | head -n1)
    cd "$gdir"
    ./contrib/download_prerequisites || true
    cd ..
    mkdir -v build-gcc
    pushd build-gcc >/dev/null
    "../$gdir/configure" --target="$MATCHA_TGT" --prefix=/usr --disable-nls --enable-languages=c,c++ --without-headers
    make -j"$(nproc)" all-gcc
    make -j"$(nproc)" all-target-libgcc
    make install-gcc
    make install-target-libgcc
    popd >/dev/null

    # LINUX HEADERS
    extract linux- || true
    ldir=$(echo linux-* | head -n1)
    if [[ -d "$ldir" ]]; then
        pushd "$ldir" >/dev/null
        make mrproper
        make headers_install INSTALL_HDR_PATH="$MATCHA"/usr
        popd >/dev/null
    fi

    # GLIBC
    extract glibc- || true
    gldir=$(echo glibc-* | head -n1)
    if [[ -d "$gldir" ]]; then
        mkdir -v build-glibc
        pushd build-glibc >/dev/null
        ../"$gldir"/configure --prefix=/usr --host="$MATCHA_TGT" --build=$(../"$gldir"/scripts/config.guess) --disable-profile --enable-kernel=2.6.32
        make -j"$(nproc)"
        make DESTDIR="$MATCHA" install
        popd >/dev/null
    fi
}

# --------------------------
# Phase 6: Create Chroot Automation Scripts
# --------------------------
create_chroot_scripts() {
    log "Creating chroot automation scripts."

    # MATCHA Chroot Build Script
    CHROOT_SCRIPT="/root/matcha-chroot-auto.sh"
    cat > "$CHROOT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

MATCHA="${MATCHA:-/mnt/matcha}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/var/log/matcha-build}"

# Helper function for running and marking steps inside chroot
run_step() {
    local id="$1"; shift
    local marker="$MATCHA/.build_done_${id}"
    if [[ -f "$marker" ]]; then echo "SKIP $id"; return 0; fi
    echo "START $id"
    if "$@"; then touch "$marker"; echo "DONE $id"; else echo "FAIL $id"; exit 1; fi
}

# Helper to find and extract the first matching tarball pattern
extract_first() {
    pattern="$1"
    for ext in tar.xz tar.gz tar.bz2 tar.lz tar.zst tar; do
        for f in $MATCHA/sources/${pattern}*.$ext; do
            if [[ -f "$f" ]]; then tar -xf "$f"; return 0; fi
        done
    done
    echo "Error: no archive found for pattern '$pattern'." >&2
    return 1
}

# Main build loop
build_packages() {
    cd "$MATCHA/sources"

    local packages=(
        "bzip2" "coreutils" "diffutils" "findutils" "gawk" "grep" "gzip" "make"
        "patch" "tar" "xz" "binutils" "gcc" "linux" "util-linux" "e2fsprogs"
        "shadow" "sysklogd" "procps-ng" "man-db" "perl" "python3" "bash"
    )

    for pkg in "${packages[@]}"; do
        case "$pkg" in
            bzip2)
                run_step bzip2 bash -lc '
                    extract_first bzip2- && cd bzip2-*
                    make -f Makefile-libbz2_so
                    make clean
                    make PREFIX=/usr install
                '
                ;;
            coreutils)
                run_step coreutils bash -lc '
                    extract_first coreutils- && cd coreutils-*
                    ./configure --prefix=/usr --enable-no-install-program=kill,uptime
                    make -j"$(nproc)"
                    make install
                '
                ;;
            make)
                run_step make bash -lc '
                    extract_first make- && cd make-*
                    ./configure --prefix=/usr
                    make -j"$(nproc)"
                    make install
                '
                ;;
            gcc)
                run_step gcc-final bash -lc '
                    extract_first gcc- && cd gcc-*
                    ./contrib/download_prerequisites || true
                    mkdir -v build && cd build
                    ../configure --prefix=/usr --enable-languages=c,c++ --disable-multilib --disable-bootstrap --with-system-zlib
                    make -j"$(nproc)"
                    make install
                '
                ;;
            linux)
                run_step linux-build bash -lc '
                    extract_first linux- && cd linux-*
                    make mrproper
                    make defconfig
                    make -j"$(nproc)"
                    make modules_install INSTALL_MOD_PATH=/
                '
                ;;
            util-linux)
                run_step util-linux bash -lc '
                    extract_first util-linux- && cd util-linux-*
                    ./configure --prefix=/usr --sysconfdir=/etc --with-rootlibdir=/lib
                    make -j"$(nproc)"
                    make install
                '
                ;;
            e2fsprogs)
                run_step e2fsprogs bash -lc '
                    extract_first e2fsprogs- && cd e2fsprogs-*
                    mkdir -v build && cd build
                    ../configure --prefix=/usr --enable-elf-shlibs
                    make -j"$(nproc)"
                    make install
                '
                ;;
            bash)
                run_step bash bash -lc '
                    extract_first bash- && cd bash-*
                    ./configure --prefix=/usr --without-bash-malloc
                    make -j"$(nproc)"
                    make install
                '
                ;;
            *)
                echo "No automated recipe for $pkg." >&2
                ;;
        esac
    done
}

# Run the package build process
build_packages
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $(cat /etc/hostname 2>/dev/null || echo matcha)" >> /etc/hosts
EOF

    chmod +x "$CHROOT_SCRIPT"
    log "Created chroot automation script at $CHROOT_SCRIPT"

    # Chroot helper script
    cat > /root/enter-chroot.sh <<'EOF'
#!/bin/bash
set -euo pipefail
MATCHA="${MATCHA:-/mnt/matcha}"
chroot "$MATCHA" /usr/bin/env -i HOME=/root TERM="$TERM" PS1="(matcha chroot) \u:\w\$ " PATH=/usr/bin:/usr/sbin:/bin:/sbin /bin/bash --login
EOF
    chmod +x /root/enter-chroot.sh

    # Kernel installation script
    cat > /root/kernel-install-auto.sh <<'EOF'
#!/bin/bash
set -euo pipefail
MATCHA="${MATCHA:-/mnt/matcha}"
KVER="${KVER:-6.16.1}"
cd /usr/src/linux || exit 1
make defconfig
make -j"$(nproc)"
make modules_install INSTALL_MOD_PATH=/
cp -v arch/$(uname -m)/boot/bzImage /boot/vmlinuz-$KVER-matcha-$MATCHA_RELEASE
cp -v System.map /boot/System.map-$KVER
cp -v .config /boot/config-$KVER
grub-install "$DISK"
cat > /boot/grub/grub.cfg << "EOF_GRUB"
set default=0
set timeout=5
set root=(hd0,2)
menuentry "MATCHA $MATCHA_RELEASE ($KVER)" {
  linux /boot/vmlinuz-$KVER-matcha-$MATCHA_RELEASE root=$ROOT_PART ro
}
EOF_GRUB
EOF
    chmod +x /root/kernel-install-auto.sh
}

# ---------------------------
# Phase 7: GNU Guix Installation (Optional)
# ---------------------------
install_guix() {
    log "Starting GNU Guix installation."
    cd "$MATCHA"/sources
    echo "Fetching latest GNU Guix source tarball..."
    wget -N https://ftp.gnu.org/gnu/guix/guix-latest.tar.gz -O guix-latest.tar.gz
    tar -xf guix-latest.tar.gz
    cd guix-*
    ./configure --prefix=/usr/local --sysconfdir=/etc --localstatedir=/var
    make -j"$(nproc)"
    make install
    log "Guix installation complete. Setting up build users and daemon."

    if ! getent group guixbuild >/dev/null; then
        groupadd --system guixbuild
        for i in $(seq -w 1 10); do
            useradd -g guixbuild -G guixbuild \
                -d /var/empty -s /bin/false -c "Guix build user $i" \
                guixbuilder$i
        done
    fi

    cat > /etc/init.d/guix-daemon << "EOF"
#!/bin/sh
### BEGIN INIT INFO
# Provides:          guix-daemon
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: GNU Guix Daemon
### END INIT INFO
case "$1" in
  start)   /usr/local/bin/guix-daemon --build-users-group=guixbuild & ;;
  stop)    killall guix-daemon ;;
  restart) killall guix-daemon; /usr/local/bin/guix-daemon --build-users-group=guixbuild & ;;
  *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
exit 0
EOF
    chmod +x /etc/init.d/guix-daemon
}

# --------------------------
# Main Execution
# --------------------------
main() {
    run_step "prepare-fs" "prepare_filesystems"
    run_step "setup-base" "setup_matcha_user"
    run_step "write-matcha-profile" "write_matcha_profile"
    run_step "mount-pseudos" "mount_pseudos"
    run_step "build-temp-toolchain" "build_temp_toolchain"
    run_step "create-chroot-scripts" "create_chroot_scripts"
    run_step "guix-setup" "install_guix"

    echo
    log "AUTOMATION SETUP COMPLETE."
    echo "Next steps to complete the build (recommended):"
    echo " 1) Ensure all MATCHA tarballs are present in $MATCHA/sources."
    echo " 2) Run: /root/enter-chroot.sh (to enter the chroot environment)"
    echo " 3) Inside the chroot, run: /root/matcha-chroot-auto.sh"
    echo " 4) After the packages build successfully, run /root/kernel-install-auto.sh inside the chroot to build and install the kernel and grub."
    echo
    echo "The script uses marker files under $MATCHA (e.g., '.build_done_prepare-fs') to resume progress."
    echo "Logs are located in $BUILD_LOG_DIR."
}

# Run the main function
main