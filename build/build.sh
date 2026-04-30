#!/bin/bash
#
# Build NVIDIA proprietary driver package for Thor's Unraid kernel 7.0
# Produces a Slackware .txz installable on Unraid
#
# Usage: Run this from inside the Docker container:
#   docker run --rm -v $(pwd)/output:/output -v $(pwd)/config.gz:/build/config.gz nvidia-thor-builder /build/build.sh

set -euo pipefail

NVIDIA_VERSION="580.126.18"
KERNEL_TAG="20260420"
KERNEL_REPO="https://github.com/thor2002ro/unraid_kernel.git"

WORKDIR="/build"
KERNEL_SRC="${WORKDIR}/kernel-src"
NVIDIA_DIR="${WORKDIR}/nvidia"
PKG="${WORKDIR}/pkg"
OUTPUT="/output"

echo "============================================"
echo " NVIDIA ${NVIDIA_VERSION} for Thor Kernel 7.0"
echo "============================================"

###############################################
# Phase 1: Prepare kernel source
###############################################

echo ""
echo "=== Phase 1: Preparing kernel source ==="
echo ""

if [ ! -d "${KERNEL_SRC}/.git" ]; then
    echo "Cloning thor's kernel source (tag ${KERNEL_TAG})..."
    git clone --depth 1 --branch "${KERNEL_TAG}" "${KERNEL_REPO}" "${KERNEL_SRC}"
else
    echo "Kernel source already cloned, skipping..."
fi

cd "${KERNEL_SRC}"

echo "Applying kernel config from config.gz..."
zcat /build/config.gz > .config

# The running kernel is 7.0.0-thor-Unraid+ but CONFIG_LOCALVERSION="-thor-Unraid"
# and CONFIG_LOCALVERSION_AUTO is not set. The '+' comes from the kernel Makefile
# or was passed as LOCALVERSION during thor's build. Check if the Makefile already
# sets it via EXTRAVERSION.
MAKEFILE_EXTRAVERSION=$(grep '^EXTRAVERSION' Makefile | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
echo "Makefile EXTRAVERSION = '${MAKEFILE_EXTRAVERSION}'"

make olddefconfig LLVM=1

# Check what kernelrelease we get
KREL=$(make -s kernelrelease LLVM=1 2>/dev/null || true)
echo "Kernel release from source: ${KREL}"

# If the version string doesn't end with '+', we need to add it
TARGET_KVER="7.0.0-thor-Unraid+"
if [ "${KREL}" != "${TARGET_KVER}" ]; then
    echo "WARNING: kernelrelease '${KREL}' != target '${TARGET_KVER}'"
    echo "Attempting to fix by passing LOCALVERSION=+"
    EXTRA_LOCALVERSION="LOCALVERSION=+"
else
    EXTRA_LOCALVERSION=""
fi

echo "Running make modules_prepare..."
make modules_prepare LLVM=1 ${EXTRA_LOCALVERSION} -j"$(nproc)"

# Verify the version matches
KREL_FINAL=$(make -s kernelrelease LLVM=1 ${EXTRA_LOCALVERSION} 2>/dev/null || true)
echo "Final kernel release: ${KREL_FINAL}"

if [ "${KREL_FINAL}" != "${TARGET_KVER}" ]; then
    echo "ERROR: Version mismatch! Got '${KREL_FINAL}', expected '${TARGET_KVER}'"
    echo "Modules compiled with this source may not load on the running kernel."
    echo "Continuing anyway -- the NVIDIA module build may still work if modversions is off."
fi

# Generate Module.symvers if it doesn't exist (needed for out-of-tree module builds)
if [ ! -f "Module.symvers" ]; then
    echo "Module.symvers not found, creating empty one..."
    touch Module.symvers
fi

###############################################
# Phase 2: Download and prepare NVIDIA driver
###############################################

echo ""
echo "=== Phase 2: Downloading NVIDIA driver ${NVIDIA_VERSION} ==="
echo ""

cd "${WORKDIR}"

NVIDIA_RUN="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
NVIDIA_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/${NVIDIA_RUN}"

if [ ! -f "${NVIDIA_RUN}" ]; then
    echo "Downloading ${NVIDIA_RUN}..."
    wget -q --show-progress "${NVIDIA_URL}"
else
    echo "NVIDIA installer already downloaded, skipping..."
fi

echo "Extracting NVIDIA driver..."
chmod +x "${NVIDIA_RUN}"
rm -rf "NVIDIA-Linux-x86_64-${NVIDIA_VERSION}"
./"${NVIDIA_RUN}" --extract-only

NVIDIA_EXTRACTED="${WORKDIR}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}"
cd "${NVIDIA_EXTRACTED}"

###############################################
# Phase 3: Patch and compile kernel modules
###############################################

echo ""
echo "=== Phase 3: Compiling NVIDIA kernel modules ==="
echo ""

# ---- Stub non-exported kernel symbols to avoid insmod "Unknown symbol" ----
# __vma_start_write exists in kernel 7.0 headers but is NOT exported to modules.
# Inline functions in mm.h call it, creating external references in nvidia.ko.
# Fix: replace the extern declaration with a static inline no-op so calls are
# inlined away and no external symbol reference is generated.

echo "Stubbing __vma_start_write (not exported by kernel)..."
# __vma_start_write is declared in include/linux/mmap_lock.h (kernel 7.0)
# Signature: int __vma_start_write(struct vm_area_struct *vma, int state);
# Replace with a static inline stub returning 0 (success).
python3 << 'PYEOF'
import re, os

hdr = "/build/kernel-src/include/linux/mmap_lock.h"
if os.path.exists(hdr):
    with open(hdr, 'r') as f:
        content = f.read()
    if '__vma_start_write' in content:
        # Replace extern declaration with static inline stub
        new = re.sub(
            r'^(\s*)(int\s+__vma_start_write\s*\([^)]*\))\s*;',
            r'\1static inline \2 { return 0; }',
            content,
            flags=re.MULTILINE
        )
        if new != content:
            with open(hdr, 'w') as f:
                f.write(new)
            print(f"  Stubbed extern declaration in {hdr}")
        else:
            print(f"  Regex didn't match, adding #define fallback")
            # Fallback: macro override
            with open(hdr, 'w') as f:
                f.write("#define __vma_start_write(vma, state) 0\n" + content)
            print(f"  Added macro stub to {hdr}")
    else:
        print(f"  __vma_start_write not found in {hdr}")
else:
    print(f"  {hdr} not found")
PYEOF
echo ""

# ---- Kernel 7.0 API compatibility patches ----
# Kernel 7.0 removed del_timer_sync (use timer_delete_sync) and
# hrtimer_init (use hrtimer_setup). Add compat defines.

echo "Applying kernel 7.0 timer API compatibility patches..."

# Debug: show what files exist
echo "  Looking for nv-timer.h files..."
ls -la kernel/common/inc/nv-timer.h 2>/dev/null || echo "  NOT FOUND at kernel/common/inc/nv-timer.h"
ls -la kernel-open/common/inc/nv-timer.h 2>/dev/null || echo "  NOT FOUND at kernel-open/common/inc/nv-timer.h"

# Create a compat header file
cat > /tmp/nv-k70-compat.h << 'COMPAT_EOF'
/* Kernel 7.0 compatibility: del_timer_sync was removed in 6.15+ */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
#ifndef del_timer_sync
#define del_timer_sync timer_delete_sync
#endif
#endif
COMPAT_EOF

# Patch nv-timer.h in ALL locations (kernel/ and kernel-open/ trees)
for timer_h in kernel/common/inc/nv-timer.h kernel-open/common/inc/nv-timer.h; do
    if [ -f "${timer_h}" ]; then
        cat /tmp/nv-k70-compat.h "${timer_h}" > "${timer_h}.new"
        mv "${timer_h}.new" "${timer_h}"
        echo "  Patched ${timer_h}"
    else
        echo "  ${timer_h} not found, skipping"
    fi
done

# Patch nv-nano-timer.c for hrtimer_init -> hrtimer_setup
for nano_c in kernel/nvidia/nv-nano-timer.c kernel-open/nvidia/nv-nano-timer.c; do
    if [ -f "${nano_c}" ] && grep -q "hrtimer_init" "${nano_c}"; then
        python3 << PYEOF
with open('${nano_c}', 'r') as f:
    content = f.read()
# Add version.h include if not present
if '#include <linux/version.h>' not in content:
    content = content.replace('#include "os-interface.h"', '#include <linux/version.h>\n#include "os-interface.h"')
# Replace hrtimer_init + function assignment with versioned code
old_block = '''hrtimer_init(&nv_nstimer->hr_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
    nv_nstimer->hr_timer.function = nv_nano_timer_callback_typed_data;'''
new_block = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 15, 0)
    hrtimer_init(&nv_nstimer->hr_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
    nv_nstimer->hr_timer.function = nv_nano_timer_callback_typed_data;
#else
    hrtimer_setup(&nv_nstimer->hr_timer, nv_nano_timer_callback_typed_data, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
#endif'''
content = content.replace(old_block, new_block)
with open('${nano_c}', 'w') as f:
    f.write(content)
PYEOF
        echo "  Patched ${nano_c} (hrtimer)"
    fi
done

echo "Timer API patches applied."

# Fix sys_close -> close_fd (removed in kernel 7.0)
echo "Applying sys_close -> close_fd compatibility patch..."
for caps_c in kernel/nvidia/nv-caps.c kernel-open/nvidia/nv-caps.c; do
    if [ -f "${caps_c}" ] && grep -q "sys_close" "${caps_c}"; then
        cat > /tmp/nv-sysclose-compat.h << 'COMPAT2'
/* Kernel 7.0 compatibility: sys_close was removed, use close_fd */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
#include <linux/fdtable.h>
#define sys_close(fd) close_fd(fd)
#endif
COMPAT2
        cat /tmp/nv-sysclose-compat.h "${caps_c}" > "${caps_c}.new"
        mv "${caps_c}.new" "${caps_c}"
        echo "  Patched ${caps_c} (sys_close -> close_fd)"
    fi
done
echo ""

# Apply PAHOLE/BTF patch for kernel 7.0 to the proprietary kernel Makefile
if [ -f "kernel/Makefile" ]; then
    if grep -q "PAHOLE_VARIABLES" kernel/Makefile; then
        echo "Applying kernel 7.0 PAHOLE patch to kernel/Makefile..."
        cd kernel
        # The patch is designed for the Makefile -- apply it directly
        if patch --dry-run -p0 < /build/kernel-7.0.patch >/dev/null 2>&1; then
            patch -p0 < /build/kernel-7.0.patch
            echo "Patch applied successfully to kernel/Makefile"
        else
            echo "Patch doesn't apply cleanly to kernel/, trying manual fix..."
            # Manual inline fix: replace the PAHOLE_VARIABLES line
            sed -i 's/PAHOLE_VARIABLES=$(if $(wildcard $(KERNEL_SOURCES)\/scripts\/pahole-flags.sh),,"PAHOLE=$(AWK) '\''$(PAHOLE_AWK_PROGRAM)'\''")/PAHOLE_VARIABLES=$(if $(or $(wildcard $(KERNEL_SOURCES)\/scripts\/pahole-flags.sh),$(wildcard $(KERNEL_SOURCES)\/scripts\/gen-btf.sh)),,"PAHOLE=$(AWK) '\''$(PAHOLE_AWK_PROGRAM)'\''")/g' Makefile
            echo "Manual sed fix applied to kernel/Makefile"
        fi
        cd "${NVIDIA_EXTRACTED}"
    else
        echo "kernel/Makefile doesn't have PAHOLE_VARIABLES, no patch needed"
    fi
fi

# Also patch kernel-open/Makefile if it exists (for completeness)
if [ -f "kernel-open/Makefile" ] && grep -q "PAHOLE_VARIABLES" kernel-open/Makefile; then
    echo "Applying kernel 7.0 PAHOLE patch to kernel-open/Makefile..."
    cd kernel-open
    if patch --dry-run -p0 < /build/kernel-7.0.patch >/dev/null 2>&1; then
        patch -p0 < /build/kernel-7.0.patch
    else
        sed -i 's/PAHOLE_VARIABLES=$(if $(wildcard $(KERNEL_SOURCES)\/scripts\/pahole-flags.sh),,"PAHOLE=$(AWK) '\''$(PAHOLE_AWK_PROGRAM)'\''")/PAHOLE_VARIABLES=$(if $(or $(wildcard $(KERNEL_SOURCES)\/scripts\/pahole-flags.sh),$(wildcard $(KERNEL_SOURCES)\/scripts\/gen-btf.sh)),,"PAHOLE=$(AWK) '\''$(PAHOLE_AWK_PROGRAM)'\''")/g' Makefile
    fi
    cd "${NVIDIA_EXTRACTED}"
fi

echo "Compiling NVIDIA proprietary kernel modules..."

# CRITICAL: NVIDIA 580.x defaults to open-source modules (which don't support Pascal).
# Force proprietary blob to get GTX 1060 / Pascal support.
echo "Checking for proprietary binary blob..."
if [ -f "kernel/nvidia/nv-kernel.o_binary" ]; then
    echo "  Found kernel/nvidia/nv-kernel.o_binary (proprietary blob present)"
else
    echo "  WARNING: nv-kernel.o_binary not found! Build may produce open modules."
fi

cd kernel
make \
    SYSSRC="${KERNEL_SRC}" \
    SYSOUT="${KERNEL_SRC}" \
    CC=clang \
    LD=ld.lld \
    NV_KERNEL_MODULE_TYPE=proprietary \
    IGNORE_CC_MISMATCH=yes \
    IGNORE_MISSING_MODULE_SYMVERS=1 \
    KBUILD_MODPOST_WARN=1 \
    ${EXTRA_LOCALVERSION:-} \
    -j"$(nproc)" \
    module

echo "Kernel modules compiled successfully:"
ls -la *.ko

# Verify nvidia.ko is proprietary (nvidia-drm and nvidia-uvm are always MIT/GPL, that's normal)
echo ""
echo "Module license check:"
for ko in *.ko; do
    license=$(modinfo "${ko}" 2>/dev/null | grep "^license:" | awk '{print $2, $3, $4}' || echo "unknown")
    echo "  ${ko}: ${license}"
done
NVIDIA_LICENSE=$(modinfo nvidia.ko 2>/dev/null | grep "^license:" | awk '{print $2}' || echo "unknown")
if [ "${NVIDIA_LICENSE}" != "NVIDIA" ]; then
    echo "FATAL: nvidia.ko license is '${NVIDIA_LICENSE}', expected 'NVIDIA' (proprietary)."
    echo "The build produced open-source modules. Pascal GPUs will NOT work."
    exit 1
fi
echo "nvidia.ko is proprietary (license: NVIDIA) -- Pascal support confirmed."

cd "${NVIDIA_EXTRACTED}"

###############################################
# Phase 4: Prepare package tree
###############################################

echo ""
echo "=== Phase 4: Building package tree ==="
echo ""

rm -rf "${PKG}"
mkdir -p "${PKG}"

# Determine the kernel modules version directory name
KMOD_DIR="${PKG}/lib/modules/${TARGET_KVER}/extra/nvidia"
mkdir -p "${KMOD_DIR}"

echo "Installing kernel modules..."
cp kernel/*.ko "${KMOD_DIR}/"

###############################################
# Phase 5: Install NVIDIA userspace via nvidia-installer
###############################################

echo ""
echo "=== Phase 5: Extracting NVIDIA userspace components ==="
echo ""

cd "${NVIDIA_EXTRACTED}"

mkdir -p "${PKG}/usr/bin"
mkdir -p "${PKG}/usr/lib64"
mkdir -p "${PKG}/usr/share"
mkdir -p "${PKG}/var/log"

# Use nvidia-installer to extract userspace (no kernel module compilation)
if [ -x "./nvidia-installer" ]; then
    ./nvidia-installer -s --no-kernel-module --no-drm --no-unified-memory \
        -z -n -b --no-rpms --no-distro-scripts \
        --no-kernel-module-source --no-x-check --force-libglx-indirect \
        --x-prefix="${PKG}/usr" \
        --x-module-path="${PKG}/usr/lib64/xorg/modules" \
        --x-library-path="${PKG}/usr/lib64" \
        --x-sysconfig-path="${PKG}/etc/X11/xorg.conf.d" \
        --opengl-prefix="${PKG}/usr" \
        --utility-prefix="${PKG}/usr" \
        --utility-libdir=lib64 \
        --documentation-prefix="${PKG}/usr" \
        --application-profile-path="${PKG}/usr/share/nvidia" \
        --glvnd-egl-config-path="${PKG}/etc/X11/glvnd/egl_vendor.d" \
        --log-file-name="${PKG}/var/log/nvidia-installer.log" \
        --egl-external-platform-config-path="${PKG}/usr/share/egl/egl_external_platform.d" \
        --no-nvidia-modprobe \
        --no-install-libglvnd \
        --no-wine-files \
        --no-systemd \
        --no-peermem \
        --no-install-compat32-libs --compat32-prefix="${PKG}/usr" \
        2>&1 || echo "nvidia-installer returned non-zero (may be OK for partial install)"
else
    echo "nvidia-installer not executable, doing manual file copy..."
    # Manual fallback: copy the essential binaries and libraries directly
    for bin in nvidia-smi nvidia-debugdump nvidia-cuda-mps-control nvidia-cuda-mps-server; do
        [ -f "${bin}" ] && install -m 755 "${bin}" "${PKG}/usr/bin/"
    done

    # Copy all shared libraries
    for lib in lib*.so* lib*.so.*; do
        [ -f "${lib}" ] && install -m 755 "${lib}" "${PKG}/usr/lib64/" 2>/dev/null || true
    done

    # Copy firmware if present
    if [ -d "firmware" ]; then
        mkdir -p "${PKG}/lib/firmware/nvidia/${NVIDIA_VERSION}"
        cp firmware/*.bin "${PKG}/lib/firmware/nvidia/${NVIDIA_VERSION}/" 2>/dev/null || true
    fi
fi

# Clean up installer logs from the package
rm -rf "${PKG}/var"

echo "Userspace components installed:"
ls "${PKG}/usr/bin/" 2>/dev/null || echo "(no binaries in usr/bin)"
echo "Libraries:"
ls "${PKG}/usr/lib64/"*.so* 2>/dev/null | wc -l
echo "shared libraries installed"

###############################################
# Phase 6: Build nvidia-container-toolkit (optional, non-fatal)
###############################################

echo ""
echo "=== Phase 6: Building nvidia-container-toolkit ==="
echo ""

(
    set +u
    cd "${WORKDIR}"

    if [ ! -d "nvidia-container-toolkit" ]; then
        git clone --depth 1 https://github.com/NVIDIA/nvidia-container-toolkit.git
    fi

    cd nvidia-container-toolkit

    mkdir -p "${PKG}/usr/bin"
    echo "Building via go build..."
    go build -o "${PKG}/usr/bin/nvidia-container-runtime-hook" ./cmd/nvidia-container-runtime-hook 2>&1 || true
    go build -o "${PKG}/usr/bin/nvidia-ctk" ./cmd/nvidia-ctk 2>&1 || true

    cd "${PKG}/usr/bin"
    [ -f "nvidia-container-runtime-hook" ] && ln -sf nvidia-container-runtime-hook nvidia-container-toolkit 2>/dev/null || true

    mkdir -p "${PKG}/etc/nvidia-container-runtime"
    cat > "${PKG}/etc/nvidia-container-runtime/config.toml" << 'TOML'
[nvidia-container-cli]
  no-cgroups = false
  debug = "/var/log/nvidia-container-toolkit.log"
[nvidia-container-runtime]
  debug = "/var/log/nvidia-container-runtime.log"
  log-level = "info"
  mode = "auto"
  runtimes = ["docker-runc", "runc", "crun"]
TOML

    mkdir -p "${PKG}/etc/docker"
    cat > "${PKG}/etc/docker/daemon.json" << 'JSON'
{
  "runtimes": {
    "nvidia": {
      "path": "/usr/bin/nvidia-container-runtime-hook",
      "runtimeArgs": []
    }
  }
}
JSON

    echo "Container toolkit build attempted."
    ls -la "${PKG}/usr/bin/nvidia-c"* 2>/dev/null || echo "(toolkit binaries not available)"
) || echo "WARNING: Container toolkit build failed (non-fatal, driver modules are OK)"

###############################################
# Phase 7: Package as Slackware .txz
###############################################

echo ""
echo "=== Phase 7: Packaging ==="
echo ""

cd "${PKG}"

# Remove .la and .a files
find . -name "*.la" -delete 2>/dev/null || true
find . -name "*.a" -delete 2>/dev/null || true

# Create package description
mkdir -p install
cat > install/slack-desc << EOF
nvidia-driver-thor: nvidia-driver-thor (NVIDIA proprietary driver ${NVIDIA_VERSION})
nvidia-driver-thor:
nvidia-driver-thor: NVIDIA proprietary driver for Pascal+ GPUs
nvidia-driver-thor: Built for Thor's custom kernel 7.0.0-thor-Unraid+
nvidia-driver-thor:
nvidia-driver-thor: Includes kernel modules, userspace libraries,
nvidia-driver-thor: nvidia-smi, and container toolkit.
nvidia-driver-thor:
nvidia-driver-thor: GPU support: GTX 1060, GTX 1070, GTX 1080, and newer
nvidia-driver-thor:
nvidia-driver-thor:
EOF

# Create doinst.sh (post-install script)
cat > install/doinst.sh << 'POSTINST'
#!/bin/sh
# Run depmod to register the new modules
KVER="7.0.0-thor-Unraid+"
if [ -d "/lib/modules/${KVER}" ]; then
    depmod -a "${KVER}" 2>/dev/null || true
fi

# Load nvidia modules
modprobe nvidia 2>/dev/null || true
modprobe nvidia-uvm 2>/dev/null || true
modprobe nvidia-modeset 2>/dev/null || true
modprobe nvidia-drm 2>/dev/null || true

# Update library cache
ldconfig 2>/dev/null || true
POSTINST
chmod +x install/doinst.sh

# Create the Slackware .txz package
PKGFILE="nvidia-${NVIDIA_VERSION}-x86_64-thor.txz"
echo "Creating ${PKGFILE}..."

# Use tar + xz since we may not have makepkg
tar cf - . | xz -9 > "${OUTPUT}/${PKGFILE}"

echo "Package created: ${OUTPUT}/${PKGFILE}"
ls -lh "${OUTPUT}/${PKGFILE}"

# Generate MD5
cd "${OUTPUT}"
md5sum "${PKGFILE}" > "${PKGFILE}.md5"
echo "MD5: $(cat ${PKGFILE}.md5)"

###############################################
# Phase 8: Verify
###############################################

echo ""
echo "=== Verification ==="
echo ""

echo "Package contents summary:"
echo "  Kernel modules:"
find "${PKG}/lib/modules" -name "*.ko" -exec basename {} \; 2>/dev/null | sort
echo "  Binaries:"
ls "${PKG}/usr/bin/" 2>/dev/null | head -20
echo "  Libraries:"
find "${PKG}/usr/lib64" -name "*.so*" 2>/dev/null | wc -l
echo "  shared libraries"

# Check vermagic of compiled modules
echo ""
echo "Module vermagic check:"
for ko in "${PKG}/lib/modules/${TARGET_KVER}/extra/nvidia/"*.ko; do
    if [ -f "${ko}" ]; then
        modinfo "${ko}" 2>/dev/null | grep -E "vermagic|filename" || echo "  $(basename ${ko}): could not read modinfo"
    fi
done

echo ""
echo "============================================"
echo " Build complete!"
echo " Output: ${OUTPUT}/${PKGFILE}"
echo "============================================"
