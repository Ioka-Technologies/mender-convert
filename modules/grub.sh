#!/usr/bin/env bash
# Copyright 2024 Northern.tech AS
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

source modules/chroot.sh

# grub_create_grub_config
#
#
function grub_create_grub_config() {

    run_and_log_cmd "wget -Nq '${MENDER_GRUBENV_URL}' -P work/"
    run_and_log_cmd "tar xzvf work/${MENDER_GRUBENV_VERSION}.tar.gz -C work/"

    cat <<- EOF > work/grub-mender-grubenv-${MENDER_GRUBENV_VERSION}/mender_grubenv_defines
mender_rootfsa_part=${MENDER_ROOTFS_PART_A_NUMBER}
mender_rootfsb_part=${MENDER_ROOTFS_PART_B_NUMBER}
kernel_imagetype=kernel
initrd_imagetype=initrd
EOF

    # For partuuid support grub.cfg expects dedicated variables to be added
    if [ "${MENDER_ENABLE_PARTUUID}" == "y" ]; then
        boot_partuuid=$(disk_get_partuuid_from_device "${boot_part_device}")
        rootfsa_partuuid=$(disk_get_partuuid_from_device "${root_part_a_device}")
        rootfsb_partuuid=$(disk_get_partuuid_from_device "${root_part_b_device}")
        log_info "Using boot partition partuuid in grubenv: $boot_partuuid"
        log_info "Using root partition A partuuid in grubenv: $rootfsa_partuuid"
        log_info "Using root partition B partuuid in grubenv: $rootfsb_partuuid"
        cat <<- EOF >> work/grub-mender-grubenv-${MENDER_GRUBENV_VERSION}/mender_grubenv_defines
mender_boot_uuid=${boot_partuuid}
mender_rootfsa_uuid=${rootfsa_partuuid}
mender_rootfsb_uuid=${rootfsb_partuuid}
EOF
    else
        cat <<- EOF >> work/grub-mender-grubenv-${MENDER_GRUBENV_VERSION}/mender_grubenv_defines
mender_kernel_root_base=${MENDER_STORAGE_DEVICE_BASE}
EOF
    fi
}

# grub_install_standalone_grub_config
#
#
function grub_install_standalone_grub_config() {
    if [ -n "${MENDER_GRUB_KERNEL_BOOT_ARGS}" ]; then
        cat <<- EOF > work/grub-mender-grubenv-${MENDER_GRUBENV_VERSION}/11_bootargs_grub.cfg
set bootargs="${MENDER_GRUB_KERNEL_BOOT_ARGS}"
EOF
    fi

    (
        cd work/grub-mender-grubenv-${MENDER_GRUBENV_VERSION}
        run_and_log_cmd "make 2>&1"
        run_and_log_cmd "sudo make DESTDIR=$PWD/../ BOOT_DIR=boot install-standalone-boot-files"
        run_and_log_cmd "sudo make DESTDIR=$PWD/../rootfs install-tools"
    )

}

# grub_install_grub_d_config
#
#
function grub_install_grub_d_config() {
    if [ -n "${MENDER_GRUB_KERNEL_BOOT_ARGS}" ]; then
        log_warn "MENDER_GRUB_KERNEL_BOOT_ARGS is ignored when MENDER_GRUB_D_INTEGRATION is enabled. Set it in the GRUB configuration instead."
    fi

    # When using grub.d integration, /boot/efi must point to the boot partition,
    # and /boot/grub must point to grub-mender-grubenv on the boot partition.
    if [ ! -d work/rootfs/boot/efi ]; then
        run_and_log_cmd "sudo mkdir work/rootfs/boot/efi"
    fi
    run_and_log_cmd "sudo mkdir work/boot/grub-mender-grubenv"
    if [ -e work/rootfs/boot/grub ]; then
        # Move this to the EFI partition.
        run_and_log_cmd "sudo mv work/rootfs/boot/grub/* work/boot/grub-mender-grubenv/"
        run_and_log_cmd "sudo rmdir work/rootfs/boot/grub"
    fi
    run_and_log_cmd "sudo ln -s efi/grub-mender-grubenv work/rootfs/boot/grub"

    log_info "DEBUG: work/boot/ contents BEFORE make install-boot-env:"
    run_and_log_cmd "sudo find work/boot -maxdepth 2 -ls || true"

    (
        cd work/grub-mender-grubenv-${MENDER_GRUBENV_VERSION}
        run_and_log_cmd "make 2>&1"
        log_info "DEBUG: Running make install-boot-env..."
        run_and_log_cmd "sudo make DESTDIR=$PWD/../ BOOT_DIR=boot install-boot-env"
        log_info "DEBUG: Checking what make install-boot-env created in build dir:"
        run_and_log_cmd "sudo find $PWD/../boot -ls || true"
        run_and_log_cmd "sudo make DESTDIR=$PWD/../rootfs install-grub.d-boot-scripts"
        run_and_log_cmd "sudo make DESTDIR=$PWD/../rootfs install-tools"
        # We need this for running the scripts once.
        run_and_log_cmd "sudo make DESTDIR=$PWD/../rootfs install-offline-files"
    )

    log_info "DEBUG: work/boot/ contents AFTER make install-boot-env:"
    run_and_log_cmd "sudo find work/boot -maxdepth 3 -ls || true"
    log_info "DEBUG: Checking work/boot/grub-mender-grubenv specifically:"
    run_and_log_cmd "sudo find work/boot/grub-mender-grubenv -ls || true"
    log_info "DEBUG: Checking if files ended up in work/boot/grub/ instead:"
    run_and_log_cmd "sudo find work/boot/grub -ls 2>/dev/null || true"

    run_with_chroot_setup work/rootfs grub_install_in_chroot

    (
        cd work/grub-mender-grubenv-${MENDER_GRUBENV_VERSION}
        # Should be removed after running.
        run_and_log_cmd "sudo make DESTDIR=$PWD/../rootfs uninstall-offline-files"
    )
}

function grub_install_in_chroot() {
    # Use `--no-nvram`, since we cannot update firmware memory in an offline
    # build. Instead, use `--removable`, which creates entries that automate
    # booting if you put the image into a new device, which you almost certainly
    # will after using mender-convert.
    local -r target_name=$(probe_grub_install_target)
    run_in_chroot_and_log_cmd work/rootfs "grub-install --target=${target_name} --removable --no-nvram"
    run_in_chroot_and_log_cmd work/rootfs "grub-install --target=${target_name} --no-nvram"
    run_in_chroot_and_log_cmd work/rootfs "update-grub"
}

# grub_modify_boot_partition_grubcfg
#
# Modifies grub.cfg files in a boot partition directory to load grubenv from BOOT partition
# This is used for both initial setup and slot tarball generation (DRY principle)
#
# Arguments:
#   $1 - Path to boot partition directory (e.g., work/boot_a)
#   $2 - Distro name (e.g., "debian")
function grub_modify_boot_partition_grubcfg() {
    local boot_dir="${1}"
    local distro_name="${2}"

    log_info "Modifying grub.cfg in ${boot_dir} to load grubenv from BOOT partition"

    # Create the grubenv loader snippet
    cat > work/grubenv_loader.txt <<'EOF'
# Load grubenv from BOOT partition (partition 1)
search --no-floppy --set=grubenv_dev --label BOOT
EOF

    # Prepend to all grub.cfg files in this boot partition
    run_and_log_cmd "sudo sh -c 'cat work/grubenv_loader.txt ${boot_dir}/EFI/${distro_name}/grub.cfg > work/grub_tmp.cfg && mv work/grub_tmp.cfg ${boot_dir}/EFI/${distro_name}/grub.cfg'"
    run_and_log_cmd "sudo sh -c 'cat work/grubenv_loader.txt ${boot_dir}/EFI/BOOT/grub.cfg > work/grub_tmp.cfg && mv work/grub_tmp.cfg ${boot_dir}/EFI/BOOT/grub.cfg'"

    # Modify mender_setup_env_location function to use grubenv_dev instead of root
    # This ensures grubenv is always accessed from BOOT partition, not BOOT_A/BOOT_B
    run_and_log_cmd "sudo sed -i 's|\${root})/grub-mender-grubenv|\${grubenv_dev})/grub-mender-grubenv|g' ${boot_dir}/EFI/${distro_name}/grub.cfg"
    run_and_log_cmd "sudo sed -i 's|\${root})/grub-mender-grubenv|\${grubenv_dev})/grub-mender-grubenv|g' ${boot_dir}/EFI/BOOT/grub.cfg"

    run_and_log_cmd "rm work/grubenv_loader.txt"
}

# grub_setup_ab_esp_partitions
#
# Setup A/B boot architecture with chainloader on primary BOOT partition
# EFI binaries are stored directly in rootfs partitions (ROOT_A/ROOT_B)
# This implements the A/B boot architecture without requiring persistent efivars/efibootmgr
function grub_setup_ab_esp_partitions() {
    log_info "Setting up A/B boot architecture with chainloader"

    # Find the distro EFI directory (any directory that's not BOOT/boot)
    local distro_efi_dir=""
    for dir in work/boot/EFI/*/; do
        if [ -d "$dir" ]; then
            local dirname=$(basename "$dir")
            if [ "$dirname" != "BOOT" ] && [ "$dirname" != "boot" ]; then
                distro_efi_dir="$dir"
                log_info "Found distro EFI directory: $distro_efi_dir"
                break
            fi
        fi
    done

    if [ -z "$distro_efi_dir" ] || [ ! -d "$distro_efi_dir" ]; then
        log_fatal "Could not find distro EFI directory (expected non-BOOT directory in /EFI/)"
    fi

    # Determine distro name (e.g., "debian") and EFI binary name
    local distro_name=$(basename "$distro_efi_dir")
    log_info "Distro EFI directory name: $distro_name"

    local efi_target_name=$(probe_grub_efi_target_name)  # BOOTAA64.EFI or BOOTX64.EFI
    local efi_binary_name=$(echo "${efi_target_name}" | sed 's/BOOT/grub/I')  # grubaa64.efi or grubx64.efi

    # Copy EFI folder directly to rootfs (will be in both ROOT_A and ROOT_B)
    log_info "Copying EFI folder directly to rootfs for chainloading from root partitions"
    run_and_log_cmd "sudo mkdir -p work/rootfs/EFI/${distro_name}"
    run_and_log_cmd "sudo mkdir -p work/rootfs/EFI/BOOT"
    run_and_log_cmd "sudo cp -r ${distro_efi_dir}/* work/rootfs/EFI/${distro_name}/"

    # Create UEFI fallback boot path in rootfs
    log_info "Creating UEFI fallback boot path with ${efi_target_name} in rootfs"
    run_and_log_cmd "sudo cp work/rootfs/EFI/${distro_name}/${efi_binary_name} work/rootfs/EFI/BOOT/${efi_target_name}"

    # Create BOOT partition directory structure
    log_info "Creating BOOT partition directory with complete EFI setup"
    run_and_log_cmd "sudo mkdir -p work/boot_main"

    # Copy entire EFI folder to BOOT partition (includes all binaries, modules, etc.)
    log_info "Copying complete EFI folder to BOOT partition"
    run_and_log_cmd "sudo cp -r work/rootfs/EFI work/boot_main/"

    # Copy Mender grubenv to BOOT partition
    # Note: work/boot is still mounted from mender-convert-modify
    log_info "DEBUG: Checking for grubenv directory..."
    run_and_log_cmd "ls -la work/boot/ | grep grub || true"

    if [ -d work/boot/grub-mender-grubenv ]; then
        log_info "Copying grub-mender-grubenv to BOOT partition"
        log_info "DEBUG: Contents of work/boot/grub-mender-grubenv before copy:"
        run_and_log_cmd "sudo find work/boot/grub-mender-grubenv -ls || true"
        run_and_log_cmd "sudo cp -r work/boot/grub-mender-grubenv work/boot_main/"
        log_info "DEBUG: Contents of work/boot_main/grub-mender-grubenv after copy:"
        run_and_log_cmd "sudo find work/boot_main/grub-mender-grubenv -ls || true"
    else
        log_warn "grub-mender-grubenv not found in work/boot/"
        log_info "DEBUG: Listing work/boot contents:"
        run_and_log_cmd "sudo find work/boot -maxdepth 2 -ls || true"
    fi

    # Copy the main grub.cfg to rootfs/EFI and modify it
    log_info "Copying main grub.cfg to rootfs/EFI"
    grub_cfg_found=false
    if [ -f work/boot/grub.cfg ]; then
        log_info "Found grub.cfg in work/boot/ (standalone mode)"
        run_and_log_cmd "sudo cp work/boot/grub.cfg work/rootfs/EFI/${distro_name}/grub.cfg"
        run_and_log_cmd "sudo cp work/boot/grub.cfg work/rootfs/EFI/BOOT/grub.cfg"
        grub_cfg_found=true
    elif [ -f work/boot/grub/grub.cfg ]; then
        log_info "Found grub.cfg in work/boot/grub/ (grub.d mode)"
        run_and_log_cmd "sudo cp work/boot/grub/grub.cfg work/rootfs/EFI/${distro_name}/grub.cfg"
        run_and_log_cmd "sudo cp work/boot/grub/grub.cfg work/rootfs/EFI/BOOT/grub.cfg"
        grub_cfg_found=true
    elif [ -f work/boot/grub-mender-grubenv/grub.cfg ]; then
        log_info "Found grub.cfg in work/boot/grub-mender-grubenv/"
        run_and_log_cmd "sudo cp work/boot/grub-mender-grubenv/grub.cfg work/rootfs/EFI/${distro_name}/grub.cfg"
        run_and_log_cmd "sudo cp work/boot/grub-mender-grubenv/grub.cfg work/rootfs/EFI/BOOT/grub.cfg"
        grub_cfg_found=true
    fi

    if [ "$grub_cfg_found" = false ]; then
        log_fatal "grub.cfg not found in any expected location (work/boot/grub.cfg, work/boot/grub/grub.cfg, work/boot/grub-mender-grubenv/grub.cfg)"
    fi

    # Modify grub.cfg in rootfs to load grubenv from BOOT partition
    grub_modify_boot_partition_grubcfg "work/rootfs" "${distro_name}"

    # Create chainloader grub.cfg on BOOT partition
    log_info "Creating chainloader grub.cfg on BOOT partition"
    sudo tee work/boot_main/EFI/${distro_name}/grub.cfg > /dev/null <<EOF
# BOOT Partition Chainloader Configuration
# Loads grubenv and chainloads to ROOT_A or ROOT_B based on mender_boot_part
echo "BOOT: Loading grubenv and determining boot partition..."

# Load grubenv from this partition (BOOT)
search --no-floppy --set=bootenv_dev --label BOOT
load_env --skip-sig -f (\${bootenv_dev})/grub-mender-grubenv/mender_grubenv1/env mender_boot_part

# Chainload to the appropriate partition's GRUB binary
if [ "\${mender_boot_part}" = "2" ]; then
    echo "BOOT: Chainloading to ROOT_A (partition 2)"
    set root='(hd0,gpt2)'
    chainloader /EFI/${distro_name}/${efi_binary_name}
elif [ "\${mender_boot_part}" = "3" ]; then
    echo "BOOT: Chainloading to ROOT_B (partition 3)"
    set root='(hd0,gpt3)'
    chainloader /EFI/${distro_name}/${efi_binary_name}
else
    echo "BOOT: Defaulting to ROOT_A (partition 2)"
    set root='(hd0,gpt2)'
    chainloader /EFI/${distro_name}/${efi_binary_name}
fi
boot
EOF

    # Copy chainloader config to fallback boot directory on BOOT
    run_and_log_cmd "sudo cp work/boot_main/EFI/${distro_name}/grub.cfg work/boot_main/EFI/BOOT/grub.cfg"

    # Generate BOOT filesystem image (FAT32 with label "BOOT")
    local boot_size_mb=${MENDER_BOOT_PART_SIZE_MB:-512}
    log_info "Creating BOOT filesystem image (${boot_size_mb}MB, FAT32, label: BOOT)"
    log_info "DEBUG: Contents of work/boot_main before creating image:"
    run_and_log_cmd "sudo find work/boot_main -ls || true"
    run_and_log_cmd "dd if=/dev/zero of=work/boot_main.img bs=1M count=${boot_size_mb}"
    run_and_log_cmd "mkfs.vfat -F 32 -n BOOT work/boot_main.img"
    run_and_log_cmd "mkdir -p work/esp_mount"
    run_and_log_cmd "sudo mount work/boot_main.img work/esp_mount"
    log_info "DEBUG: Copying to mounted image with rsync"
    run_and_log_cmd "sudo rsync -av work/boot_main/ work/esp_mount/"
    log_info "DEBUG: Contents of mounted BOOT image after rsync:"
    run_and_log_cmd "sudo find work/esp_mount -ls || true"
    run_and_log_cmd "sudo umount work/esp_mount"
    run_and_log_cmd "rmdir work/esp_mount"

    log_info "A/B boot architecture created successfully"
    log_info "  - work/boot_main.img: BOOT partition (FAT32, label: BOOT) with chainloader"
    log_info "  - EFI binaries stored in rootfs /EFI folder"
}

# grub_install_grub_editenv_binary
#
# Install the editenv binary
function grub_install_grub_editenv_binary() {
    log_info "Installing the GRUB editenv binary"

    arch=$(probe_arch)

    run_and_log_cmd "wget -Nq ${MENDER_GRUB_BINARY_STORAGE_URL}/${arch}/grub-editenv -P work/"
    run_and_log_cmd "sudo install -m 751 work/grub-editenv work/rootfs/usr/bin/"

}

# grub_install_mender_grub
#
# Install mender-grub on the converted boot partition
function grub_install_mender_grub() {
    kernel_imagetype=${MENDER_GRUB_KERNEL_IMAGETYPE:-$(probe_kernel_in_boot_and_root)}
    initrd_imagetype=${MENDER_GRUB_INITRD_IMAGETYPE:-$(probe_initrd_in_boot_and_root)}

    run_and_log_cmd "sudo ln -s ${kernel_imagetype} work/rootfs/boot/kernel"
    if [ "${initrd_imagetype}" != "" ]; then
        run_and_log_cmd "sudo ln -s ${initrd_imagetype} work/rootfs/boot/initrd"
    fi

    # Remove conflicting boot files. These files do not necessarily effect the
    # functionality, but lets get rid of them to avoid confusion.
    #
    # There is no Mender integration for EFI boot or systemd-boot.
    sudo rm -rf work/boot/loader work/rootfs/boot/loader
    sudo rm -rf work/boot/EFI/Linux
    sudo rm -rf work/boot/EFI/systemd
    sudo rm -rf work/boot/NvVars
    for empty_dir in $(
                     cd work/boot && find . -maxdepth 1 -type d -empty -not -name .
    ); do
        sudo rmdir work/boot/$empty_dir
    done

    log_info "Installing GRUB..."

    log_info "Installing mender-grub-editenv"
    grub_install_grub_editenv_binary

    local -r arch=$(probe_arch)
    local -r efi_name=$(probe_grub_efi_name)
    local -r efi_target_name=$(probe_grub_efi_target_name)

    log_info "GRUB EFI: ${efi_target_name}"

    run_and_log_cmd "wget -Nq ${MENDER_GRUB_BINARY_STORAGE_URL}/${arch}/${efi_name} -P work/"
    run_and_log_cmd "sudo mkdir -p work/boot/EFI/BOOT"
    run_and_log_cmd "sudo cp work/${efi_name} -P work/boot/EFI/BOOT/${efi_target_name}"

    # Copy dtb directory to the boot partition for use by the bootloader.
    if [ -d work/rootfs/boot/dtbs ]; then
        # Look for the first directory that has dtb files. First check the base
        # folder, then any subfolders in versioned order.
        for candidate in work/rootfs/boot/dtbs $(find work/rootfs/boot/dtbs/ -maxdepth 1 -type d | sort -V -r); do
            if [ $(find $candidate -maxdepth 1 -name '*.dtb' | wc -l) -gt 0 ]; then
                run_and_log_cmd "sudo cp -r $candidate work/boot/dtb"
                break
            fi
        done
    elif [ -d work/rootfs/boot/dtb ]; then
        # For armbian, dietpi and similar
        # Keep the existing dtb directory structure as known by u-boot
        if [ $(find -L work/rootfs/boot/dtb -name '*.dtb' | wc -l) -gt 0 ]; then
            run_and_log_cmd "sudo cp -rL work/rootfs/boot/dtb work/boot/dtb"
        fi
    fi
}
