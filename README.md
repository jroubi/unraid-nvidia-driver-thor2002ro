# NVIDIA Proprietary Driver for Thor's Unraid Kernel 7.0

Custom build of **NVIDIA 580.126.18** (proprietary) for the `7.0.0-thor-Unraid+` kernel, enabling **Pascal GPU** support (GTX 1060, 1070, 1080, etc.) on Unraid servers running [thor2002ro's custom kernel](https://github.com/thor2002ro/unraid_kernel).

## Why this exists

Thor's kernel ships with `nvidia-open` (open-source kernel modules), which **does not support Pascal-era GPUs** (GTX 10xx series). The open driver only supports Turing (RTX 20xx) and newer architectures.

NVIDIA 580.126.18 is the **last proprietary driver version** that supports Pascal GPUs. This project cross-compiles it from a Mac (Apple Silicon) using Docker, applying the necessary patches for kernel 7.0 compatibility.

## Prerequisites

- **Unraid server** running thor2002ro's kernel `7.0.0-thor-Unraid+`
- **Docker** on your build machine (OrbStack, Docker Desktop, or native Docker)
- An NVIDIA **Pascal or newer** GPU (GTX 1060, 1070, 1080, RTX 20xx, 30xx, 40xx, 50xx)
- `config.gz` extracted from your running Unraid server (`/proc/config.gz`)

## Repository structure

```
.
├── README.md
├── config.gz                    # Kernel config from running Unraid server
├── build/
│   ├── Dockerfile               # Ubuntu 24.04 build environment (clang, Go, kernel deps)
│   ├── build.sh                 # Main build script (runs inside Docker)
│   ├── run-build.sh             # Mac wrapper: builds Docker image and runs build.sh
│   └── kernel-7.0.patch         # CachyOS PAHOLE/BTF fix for kernel 7.0
└── output/
    ├── nvidia-580.126.18-x86_64-thor.txz      # Built Slackware package
    └── nvidia-580.126.18-x86_64-thor.txz.md5  # MD5 checksum
```

## Build process

### 1. Extract kernel config from your Unraid server

```bash
# On Unraid:
cat /proc/config.gz > /home/config.gz
```

Copy `config.gz` to the project root on your Mac.

### 2. Build the driver package

```bash
# On your Mac:
cd /path/to/Unraid
./build/run-build.sh
```

This takes ~15-25 minutes (x86_64 emulation on Apple Silicon). The script:

1. **Builds a Docker image** (`--platform linux/amd64`) with clang, LLVM, Go, and kernel build dependencies
2. **Clones thor's kernel source** (tag `20260420`) and prepares headers with your `config.gz`
3. **Downloads NVIDIA 580.126.18** `.run` installer
4. **Applies kernel 7.0 compatibility patches** (see below)
5. **Compiles proprietary kernel modules** with `NV_KERNEL_MODULE_TYPE=proprietary`
6. **Extracts userspace** (nvidia-smi, libraries) via `nvidia-installer --no-kernel-module`
7. **Builds nvidia-container-toolkit** from source (optional, for Docker GPU passthrough)
8. **Packages everything** as a Slackware `.txz`

Output: `output/nvidia-580.126.18-x86_64-thor.txz`

### 3. Create a GitHub release

```bash
gh release create 7.0.0-thor-Unraid \
  output/nvidia-580.126.18-x86_64-thor.txz \
  output/nvidia-580.126.18-x86_64-thor.txz.md5 \
  --repo YOUR_USER/YOUR_REPO \
  --title "NVIDIA 580.126.18 for Thor Kernel 7.0.0" \
  --notes "Proprietary driver with Pascal support"
```

## Installation on Unraid

### Quick install (manual)

```bash
# Download the package
cd /tmp
wget https://github.com/jroubi/unraid-nvidia-driver-thor2002ro/releases/download/7.0.0-thor-Unraid/nvidia-580.126.18-x86_64-thor.txz

# Extract to filesystem
tar xf nvidia-580.126.18-x86_64-thor.txz -C /
depmod -a

# Load the proprietary driver (bypass nvidia-open)
insmod /lib/modules/$(uname -r)/extra/nvidia/nvidia.ko
insmod /lib/modules/$(uname -r)/extra/nvidia/nvidia-uvm.ko
insmod /lib/modules/$(uname -r)/extra/nvidia/nvidia-modeset.ko

# Verify
nvidia-smi
```

### Persistent install (survives reboot)

Unraid's `/lib/modules/` is in RAM and gets wiped on reboot. To make the driver persistent:

**1. Save the driver package to the USB flash drive:**

```bash
mkdir -p /boot/config/plugins/nvidia-custom
cp /tmp/nvidia-580.126.18-x86_64-thor.txz /boot/config/plugins/nvidia-custom/
```

**2. Install the NVIDIA Container Toolkit (for Docker `--gpus` support):**

The driver `.txz` includes `nvidia-smi` and kernel modules, but Docker GPU passthrough (`--gpus all`, `--runtime=nvidia`, Compose `deploy.resources.reservations`) requires the [NVIDIA Container Toolkit](https://github.com/NVIDIA/nvidia-container-toolkit). Download the matching 1.17.4 RPMs and extract them:

```bash
cd /tmp
wget https://github.com/NVIDIA/nvidia-container-toolkit/releases/download/v1.17.4/nvidia-container-toolkit_1.17.4_rpm_x86_64.tar.gz
mkdir -p toolkit-rpms && tar xf nvidia-container-toolkit_1.17.4_rpm_x86_64.tar.gz -C toolkit-rpms
RPMDIR="/tmp/toolkit-rpms/release-v1.17.4-stable/packages/centos7/x86_64"

docker run --rm -v /tmp:/tmp rockylinux:9 bash -c "
  yum install -y cpio &&
  mkdir -p /tmp/toolkit-install &&
  cd /tmp/toolkit-install &&
  rpm2cpio $RPMDIR/libnvidia-container1-1.17.4-1.x86_64.rpm | cpio -idmv &&
  rpm2cpio $RPMDIR/libnvidia-container-tools-1.17.4-1.x86_64.rpm | cpio -idmv &&
  rpm2cpio $RPMDIR/nvidia-container-toolkit-base-1.17.4-1.x86_64.rpm | cpio -idmv &&
  rpm2cpio $RPMDIR/nvidia-container-toolkit-1.17.4-1.x86_64.rpm | cpio -idmv
"

# Install to system
cp -af /tmp/toolkit-install/usr/bin/* /usr/bin/
cp -af /tmp/toolkit-install/usr/lib64/* /usr/lib64/
ldconfig

# Save to USB for boot persistence
mkdir -p /tmp/nvidia-toolkit-pkg/usr/lib64 /tmp/nvidia-toolkit-pkg/usr/bin
cp /usr/bin/nvidia-container-cli /usr/bin/nvidia-container-runtime-hook /usr/bin/nvidia-ctk /usr/bin/nvidia-container-runtime /tmp/nvidia-toolkit-pkg/usr/bin/ 2>/dev/null
cp /usr/lib64/libnvidia-container* /tmp/nvidia-toolkit-pkg/usr/lib64/
tar cf /boot/config/plugins/nvidia-custom/nvidia-container-toolkit-1.17.4.tar -C /tmp/nvidia-toolkit-pkg .

# Verify
nvidia-container-cli info

# Clean up
rm -rf /tmp/toolkit-rpms /tmp/toolkit-install /tmp/nvidia-toolkit-pkg
rm -f /tmp/nvidia-container-toolkit_1.17.4_rpm_x86_64.tar.gz
docker rmi rockylinux:9 2>/dev/null
```

**3. Configure Docker runtime:**

```bash
cat > /etc/docker/daemon.json << 'EOF'
{
  "runtimes": {
    "nvidia": {
      "args": [],
      "path": "nvidia-container-runtime"
    }
  }
}
EOF

# Save to USB
cp /etc/docker/daemon.json /boot/config/plugins/nvidia-custom/daemon.json

# Restart Docker
/etc/rc.d/rc.docker restart
```

**4. Create a modprobe blacklist:**

```bash
mkdir -p /boot/config/modprobe.d
cat > /boot/config/modprobe.d/nvidia-proprietary.conf << 'EOF'
blacklist nvidia-open
install nvidia insmod /lib/modules/7.0.0-thor-Unraid+/extra/nvidia/nvidia.ko
install nvidia-uvm insmod /lib/modules/7.0.0-thor-Unraid+/extra/nvidia/nvidia-uvm.ko
install nvidia-modeset insmod /lib/modules/7.0.0-thor-Unraid+/extra/nvidia/nvidia-modeset.ko
install nvidia-drm insmod /lib/modules/7.0.0-thor-Unraid+/extra/nvidia/nvidia-drm.ko
EOF
```

**5. Set up `/boot/config/go` (runs at every boot):**

**Important:** All NVIDIA setup must run **before** `emhttp`, because `emhttp` starts Docker. If the driver, toolkit, and `daemon.json` aren't in place before Docker starts, GPU passthrough won't work until Docker is manually restarted.

```bash
cat > /boot/config/go << 'GOEOF'
#!/bin/bash

# --- NVIDIA Proprietary Driver (GTX 1060 / Pascal) ---
# Install modprobe blacklist for nvidia-open
cp /boot/config/modprobe.d/nvidia-proprietary.conf /etc/modprobe.d/ 2>/dev/null

# Extract driver package (kernel modules + userspace)
installpkg /boot/config/plugins/nvidia-custom/nvidia-580.126.18-x86_64-thor.txz 2>/dev/null || \
  tar xf /boot/config/plugins/nvidia-custom/nvidia-580.126.18-x86_64-thor.txz -C /

# Install NVIDIA Container Toolkit (for Docker --gpus support)
tar xf /boot/config/plugins/nvidia-custom/nvidia-container-toolkit-1.17.4.tar -C /
ldconfig 2>/dev/null

# Restore Docker daemon config for nvidia runtime
cp /boot/config/plugins/nvidia-custom/daemon.json /etc/docker/daemon.json 2>/dev/null

# Rebuild module database and load driver
depmod -a 2>/dev/null
insmod /lib/modules/7.0.0-thor-Unraid+/extra/nvidia/nvidia.ko 2>/dev/null
insmod /lib/modules/7.0.0-thor-Unraid+/extra/nvidia/nvidia-uvm.ko 2>/dev/null
insmod /lib/modules/7.0.0-thor-Unraid+/extra/nvidia/nvidia-modeset.ko 2>/dev/null

# Start the Management Utility
/usr/local/sbin/emhttp
GOEOF
```

**6. Reboot and verify:**

```bash
reboot
# After reboot:
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi
```

## Docker GPU passthrough

Once the driver and container toolkit are installed, containers can use the GPU in multiple ways:

| Method | Docker CLI | Docker Compose |
|--------|-----------|----------------|
| `--gpus all` | `docker run --gpus all ...` | `deploy: resources: reservations: devices: [{driver: nvidia, count: 1, capabilities: [gpu]}]` |
| `--runtime=nvidia` | `docker run --runtime=nvidia ...` | `runtime: nvidia` |
| Direct device pass | `docker run --device /dev/nvidia0 ...` | `devices: ["/dev/nvidia0:/dev/nvidia0", ...]` |

**Verify GPU inside a container:**

```bash
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi
```

### Version compatibility

All NVIDIA container toolkit components must be from the **same release**. Mixing versions (e.g. `nvidia-ctk` from latest with `nvidia-container-cli` from 1.17.4) causes errors like `unrecognized option '--cuda-compat-mode=ldconfig'`.

| Component | Version | Source |
|-----------|---------|--------|
| `nvidia-container-cli` | 1.17.4 | RPM: `libnvidia-container-tools` |
| `libnvidia-container.so.1` | 1.17.4 | RPM: `libnvidia-container1` |
| `libnvidia-container-go.so.1` | 1.17.4 | RPM: `libnvidia-container1` |
| `nvidia-ctk` | 1.17.4 | RPM: `nvidia-container-toolkit-base` |
| `nvidia-container-runtime-hook` | 1.17.4 | RPM: `nvidia-container-toolkit` |

## Kernel 7.0 compatibility patches

The NVIDIA 580.126.18 driver was not designed for kernel 7.0. The build script applies these patches automatically:

| Patch | Problem | Fix |
|-------|---------|-----|
| `del_timer_sync` | Removed in kernel 6.15+, replaced by `timer_delete_sync` | `#define del_timer_sync timer_delete_sync` in `nv-timer.h` |
| `hrtimer_init` | Replaced by `hrtimer_setup` in kernel 6.15+ | Version-conditional code in `nv-nano-timer.c` |
| `sys_close` | Removed in kernel 7.0, replaced by `close_fd` | `#define sys_close(fd) close_fd(fd)` in `nv-caps.c` |
| PAHOLE/BTF | `scripts/pahole-flags.sh` replaced by `scripts/gen-btf.sh` in kernel 7.0 | Patch from [CachyOS](https://github.com/CachyOS/CachyOS-PKGBUILDS) applied to `kernel/Makefile` |
| `__vma_start_write` | Declared in `mmap_lock.h` but **not exported** to modules | Replaced extern declaration with `static inline` stub (no-op) |

### About the `__vma_start_write` stub

`__vma_start_write` is a per-VMA write locking function (introduced in kernel 6.4). In Thor's kernel 7.0, it exists in headers but is **not exported** (`EXPORT_SYMBOL`) to loadable modules. The NVIDIA conftest detects it in headers and generates code that calls it, causing `insmod: Unknown symbol __vma_start_write` at runtime.

The fix replaces the extern declaration in `include/linux/mmap_lock.h` with a `static inline` no-op. This is safe because:
- Pre-6.4 kernels don't have this function at all, and NVIDIA drivers work fine
- The function is a fine-grained locking optimization, not a correctness requirement for GPU drivers
- The stub only affects the out-of-tree NVIDIA module, not the kernel itself

### About `NV_KERNEL_MODULE_TYPE=proprietary`

NVIDIA 580.x defaults to building **open-source** kernel modules, which only support Turing (RTX 20xx) and newer. Passing `NV_KERNEL_MODULE_TYPE=proprietary` forces the build to use the proprietary binary blob (`nv-kernel.o_binary`), which includes the full PCI ID table with Pascal support.

You can verify the module type:
```bash
modinfo nvidia | grep license
# Proprietary: "license: NVIDIA"
# Open-source: "license: Dual MIT/GPL"  <-- won't work for Pascal
```

## Build flags reference

Key flags passed to the NVIDIA kernel module `make`:

| Flag | Purpose |
|------|---------|
| `SYSSRC` / `SYSOUT` | Path to prepared kernel source tree |
| `CC=clang` / `LD=ld.lld` | Match Thor's kernel compiler (clang 22.1.1) |
| `NV_KERNEL_MODULE_TYPE=proprietary` | Force proprietary blob for Pascal support |
| `IGNORE_CC_MISMATCH=yes` | Allow minor compiler version differences |
| `IGNORE_MISSING_MODULE_SYMVERS=1` | Build without Module.symvers (not available from `modules_prepare`) |
| `KBUILD_MODPOST_WARN=1` | Treat modpost errors as warnings (safe when `CONFIG_MODVERSIONS` is off) |

## Package contents

The `.txz` package contains:

- **Kernel modules** (`/lib/modules/7.0.0-thor-Unraid+/extra/nvidia/`):
  - `nvidia.ko` (main driver, proprietary)
  - `nvidia-uvm.ko` (unified virtual memory)
  - `nvidia-modeset.ko` (mode setting)
  - `nvidia-drm.ko` (DRM interface)
  - `nvidia-peermem.ko` (peer memory / GPUDirect RDMA)
- **Binaries** (`/usr/bin/`): `nvidia-smi`, `nvidia-persistenced`, `nvidia-settings`, `nvidia-xconfig`
- **Libraries** (`/usr/lib64/`): ~80 shared libraries (CUDA, OpenGL, Vulkan, NVML, etc.)
- **Container runtime config** (`/etc/nvidia-container-runtime/`, `/etc/docker/`)

### USB flash drive layout (`/boot/config/`)

After persistent install, your USB flash drive contains:

```
/boot/config/
├── go                                                    # Boot script (loads driver + toolkit)
├── modprobe.d/
│   └── nvidia-proprietary.conf                           # Blacklists nvidia-open
└── plugins/nvidia-custom/
    ├── nvidia-580.126.18-x86_64-thor.txz                 # Driver package (237MB)
    ├── nvidia-container-toolkit-1.17.4.tar               # Container toolkit binaries + libs
    └── daemon.json                                       # Docker runtime config
```

## Troubleshooting

### `modprobe: ERROR: could not insert 'nvidia': No such device`

The system is loading `nvidia-open` instead of your proprietary module. Check:
```bash
modinfo nvidia | grep filename
# Should be: /lib/modules/.../extra/nvidia/nvidia.ko
# NOT: /lib/modules/.../extra/nvidia-open/nvidia.ko.xz
```

Use `insmod` with the explicit path to bypass `nvidia-open`:
```bash
insmod /lib/modules/$(uname -r)/extra/nvidia/nvidia.ko
```

### `insmod: Unknown symbol __vma_start_write`

The build did not apply the `mmap_lock.h` stub correctly. Rebuild with the latest `build.sh`.

### `license: Dual MIT/GPL` (instead of `NVIDIA`)

The build produced open-source modules. Ensure `NV_KERNEL_MODULE_TYPE=proprietary` is set in `build.sh`.

### Docker: `nvidia-container-cli: executable file not found in $PATH`

The NVIDIA Container Toolkit is not installed. See the "Install the NVIDIA Container Toolkit" section above. Docker's `--gpus all`, `--runtime=nvidia`, and Compose `deploy.resources.reservations.devices` all require `nvidia-container-cli`.

### Docker: `unrecognized option '--cuda-compat-mode=ldconfig'`

Version mismatch between `nvidia-container-runtime-hook` and `nvidia-container-cli`. All components must be from the same release. Install the complete 1.17.4 toolkit as described in the persistent install section.

### Docker: `could not select device driver "" with capabilities: [[gpu]]`

The NVIDIA driver, toolkit, and `daemon.json` were not in place when Docker started. In `/boot/config/go`, all NVIDIA setup must come **before** the `/usr/local/sbin/emhttp` line (which starts Docker). If you already booted with the wrong order, restart Docker: `/etc/rc.d/rc.docker restart`.

### Docker: alternative without the container toolkit

If you can't get the container toolkit working, you can pass GPU devices directly without it:

```bash
docker run --rm \
  --device /dev/nvidia0 \
  --device /dev/nvidiactl \
  --device /dev/nvidia-uvm \
  --device /dev/nvidia-uvm-tools \
  your-image
```

For Docker Compose, replace the `deploy.resources.reservations` block with:

```yaml
devices:
  - /dev/nvidia0:/dev/nvidia0
  - /dev/nvidiactl:/dev/nvidiactl
  - /dev/nvidia-uvm:/dev/nvidia-uvm
  - /dev/nvidia-uvm-tools:/dev/nvidia-uvm-tools
```

This bypasses the container toolkit entirely but won't auto-mount NVIDIA libraries into the container. Most GPU-aware images (Jellyfin, Plex, Immich) bundle their own CUDA/NVML libraries so this usually works fine.

### Module loads but GPU not detected

Check if the GPU is bound to `vfio-pci` (passthrough):
```bash
lspci -k | grep -A3 -i nvidia
```

If it shows `Kernel driver in use: vfio-pci`, unbind it first or remove the GPU from your VM configuration.

## Complete uninstall / revert to stock Unraid

To remove everything and go back to a clean Unraid setup:

### 1. Unload the NVIDIA driver (live session)

```bash
# Remove modules in reverse dependency order
rmmod nvidia-drm 2>/dev/null
rmmod nvidia-modeset 2>/dev/null
rmmod nvidia-uvm 2>/dev/null
rmmod nvidia 2>/dev/null
```

### 2. Remove files from the USB flash drive

```bash
# Remove driver package, container toolkit, and Docker config
rm -rf /boot/config/plugins/nvidia-custom

# Remove modprobe blacklist
rm -f /boot/config/modprobe.d/nvidia-proprietary.conf
rmdir /boot/config/modprobe.d 2>/dev/null
```

### 3. Restore `/boot/config/go` to stock

Edit `/boot/config/go` and remove everything except the `emhttp` line, so it looks like:

```bash
#!/bin/bash
# Start the Management Utility
/usr/local/sbin/emhttp
```

Or run this one-liner:

```bash
cat > /boot/config/go << 'EOF'
#!/bin/bash
# Start the Management Utility
/usr/local/sbin/emhttp
EOF
```

### 4. Remove installed files from RAM filesystem (current session)

These will also be gone after a reboot since they live in RAM, but to clean up immediately:

```bash
# Kernel modules
rm -rf /lib/modules/$(uname -r)/extra/nvidia

# Userspace binaries
rm -f /usr/bin/nvidia-smi /usr/bin/nvidia-persistenced /usr/bin/nvidia-settings /usr/bin/nvidia-xconfig

# Container toolkit binaries
rm -f /usr/bin/nvidia-container-cli /usr/bin/nvidia-container-runtime-hook /usr/bin/nvidia-ctk /usr/bin/nvidia-container-runtime

# Container toolkit libraries
rm -f /usr/lib64/libnvidia-container*

# NVIDIA libraries (installed by the driver package)
rm -f /usr/lib64/libnvidia-* /usr/lib64/libcuda* /usr/lib64/libnvcuvid* /usr/lib64/libnvoptix*

# Config files
rm -f /etc/docker/daemon.json
rm -rf /etc/nvidia-container-runtime

# Modprobe blacklist
rm -f /etc/modprobe.d/nvidia-proprietary.conf

# Rebuild module database and library cache
depmod -a
ldconfig
```

### 5. Restart Docker

```bash
/etc/rc.d/rc.docker restart
```

### 6. Reboot

```bash
reboot
```

After reboot, Unraid will be back to its stock configuration. The `nvidia-open` driver that ships with Thor's kernel will load normally again (though it still won't support Pascal GPUs).

**What's safe to delete:** Everything listed above lives either on the USB flash drive (`/boot/config/`) or in Unraid's RAM filesystem. Nothing touches the array, cache drives, or Docker container data. Your containers, VMs, shares, and array data are completely unaffected.

## Credits

- [thor2002ro](https://github.com/thor2002ro) for the custom Unraid kernel
- [CachyOS](https://github.com/CachyOS/CachyOS-PKGBUILDS) for the kernel 7.0 PAHOLE patch
- [NVIDIA](https://www.nvidia.com) for the proprietary driver
- [ich777 / unraid](https://github.com/unraid/unraid-nvidia-driver) for the original Unraid NVIDIA driver plugin

## License

The build scripts in this repository are provided as-is. The NVIDIA driver itself is subject to the [NVIDIA Software License Agreement](https://www.nvidia.com/en-us/drivers/nvidia-license/).
