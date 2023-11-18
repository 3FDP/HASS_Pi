#!/bin/bash

# Script: debian-pi.sh
# Usage: debian-pi.sh -img <debian_image_file> -device <device_path> [-hostname <hostname>] -user <username> -pass <password>

# Function to display usage
usage() {
    echo "Usage: $0 -img <debian_image_file> -device <device_path> [-hostname <hostname>] -user <username> -pass <password>"
    exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -img) img="$2"; shift ;;
        -device) device="$2"; shift ;;
        -hostname) hostname="$2"; shift ;;
        -user) new_user="$2"; shift ;;
        -pass) new_pass="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Check if mandatory arguments are set
if [ -z "$img" ] || [ -z "$device" ] || [ -z "$new_user" ] || [ -z "$new_pass" ]; then
    usage
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

# Step 1: Install the image to the device
echo "Installing $img to $device..."
dd if="$img" of="$device" bs=4M conv=fsync status=progress
echo "Installation complete."

# Function to find the bootable system partition
find_system_partition() {
    local device="$1"
    for partition in \${device}*; do
        mkdir -p /mnt/temp_partition
        mount \$partition /mnt/temp_partition 2>/dev/null

        # Check for system directories
        if [ -d /mnt/temp_partition/etc ] && [ -d /mnt/temp_partition/boot ] && \
           [ -d /mnt/temp_partition/home ] && [ -d /mnt/temp_partition/mnt ] && \
           [ -d /mnt/temp_partition/media ]; then
            umount /mnt/temp_partition
            rmdir /mnt/temp_partition
            echo \$partition
            return
        fi

        umount /mnt/temp_partition 2>/dev/null
        rmdir /mnt/temp_partition
    done

    echo "No system partition found" >&2
    exit 1
}

# Find the bootable system partition
partition=$(find_system_partition $device)
if [ -z "$partition" ]; then
    echo "Unable to find a valid system partition on $device"
    exit 1
fi

echo "Using system partition: $partition"

# Mount the partition to edit files
mount_point="/mnt/debian_pi"
mkdir -p $mount_point
mount $partition $mount_point

# Step 2: Edit /etc/ssh/sshd_config
echo "Configuring SSH to allow root login..."
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' $mount_point/etc/ssh/sshd_config

# Step 3: Generate encrypted password for root
echo "Generating encrypted password for root..."
new_root_passwd=$(openssl passwd -6 root)
echo "Encrypted password: $new_root_passwd"

# Step 4: Update /etc/shadow with the new root password
echo "Updating root password in /etc/shadow..."
sed -i "s/^root:.*/root:$new_root_passwd:17647:0:99999:7:::/" $mount_point/etc/shadow

# Step 5: Set hostname (if provided)
if [ ! -z "$hostname" ]; then
    echo "Setting hostname to $hostname..."
    echo "$hostname" > $mount_point/etc/hostname
    echo "127.0.0.1    $hostname" >> $mount_point/etc/hosts
fi

# Step 6: Create setup.sh script in the device's root directory
echo "Creating setup.sh script..."
cat <<EOF > $mount_point/setup.sh
#!/bin/bash
# Script: setup.sh
# This script is auto-generated by debian-pi.sh

# Update packages
apt update

# Install necessary software
apt install -y sudo python3 systemd-resolver

# Check Python version and remove the EXTERNALLY-MANAGED file for that version
python_version=\$(python3 --version | grep -oP '(?<=Python )\d+\.\d+')
python_rm="/usr/lib/python\$python_version/EXTERNALLY-MANAGED"
if [ -f "\$python_rm" ]; then
    sudo rm "\$python_rm"
fi

# Create a new user
useradd -m -s /bin/bash $new_user
echo "$new_user:$new_pass" | chpasswd

# Add the user to the sudo group
usermod -aG sudo $new_user

# Configure DNS
rm /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Reboot the system
reboot
EOF

chmod +x $mount_point/setup.sh
echo "Script completed successfully."