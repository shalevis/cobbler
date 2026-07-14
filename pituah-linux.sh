#!/bin/bash
first_configuration() {
    # Change hostname
    echo "Changing hostname..."
    serial=$(cat /sys/class/dmi/id/product_serial)
    echo "serial $serial"
    lower_serial=${serial,,}
    hostname "ubuntu-$lower_serial.<DOMAIN>"
    hostname
    echo "ubuntu-$lower_serial.<DOMAIN>" > /etc/hostname
    # Change apt source list
    #echo "Changing apt source list..." 
    #echo "deb http://192.168.108.51/ubuntu noble main restricted universe multiverse " > /etc/apt/sources.list
    #echo "deb http://192.168.108.51/ubuntu noble-updates main restricted universe multiverse " >> /etc/apt/sources.list
    #echo "Updating packages..."
    apt update
    # Add secondary DNS
    echo "Adding secondary DNS..."
    echo 'nameserver 192.168.108.1' >> /etc/resolv.conf
    
}
update_ca_crt(){
    echo "copping certificates to allow trusted communication with ca ..."
    cp /home/user/root_2024_ca.crt /usr/share/ca-certificates/
    cp /home/user/intermediate_2024_ca.crt /usr/share/ca-certificates/
    update-ca-certificates
}
sync_ntp(){
    echo "sync date with ntp server"
    timedatectl set-timezone Asia/Jerusalem
    echo "NTP=192.168.108.1" >> /etc/systemd/timesyncd.conf
    date
}
# Function to check and install required packages
install_required_packages() {
    echo "Checking and installing required packages..."
    echo "krb5-user krb-config/defaultrealm string <DOMAIN>" | sudo debconf-set-selections
    required_packages=(freeipa-client krb5-user openssh-server nfs-common cifs-utils chrony)
    missing_packages=()
    for pkg in "${required_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing_packages+=("$pkg")
        fi
    done
    if [ ${#missing_packages[@]} -eq 0 ]; then
        echo "All required packages are already installed."
    else
        echo "Installing missing packages: ${missing_packages[@]}"
        apt install freeipa-client krb5-user openssh-server nfs-common cifs-utils -y
    fi
}
# Function to join Pituah.IAF Domain
join_domain() {
    echo "Joining <DOMAIN> linux sub Domain of pituah.iaf..."
    ipa-client-install --domain=<DOMAIN> --server=ipa.<DOMAIN> --realm=<DOMAIN> --principal=admin --password='<PASSWORD>' --mkhomedir --ntp-server=192.168.108.1 --unattended --force-join
}
# Continue the original script
# Function to mount shared driveip
mount_shared_drive() {
    echo "Mounting shared drive..."
    mkdir /mnt/network-drives
    mkdir /mnt/network-drives/Support
    sudo echo "//192.168.108.70/Support$ /mnt/network-drives/Support cifs vers=2.1,username=svc_cifs,password=Aa123456789,uid=1000,gid=1000 0 0 " >> /etc/fstab
    sudo mount -a
}
# Function to trigger TrellixSmartInstall script
trigger_trellix_smart_install() {
    echo "Triggering TrellixSmartInstall script..."
    # Assuming TrellixSmartInstall script is located at /home/support/Framepkg/SmartInstallLinux/TrellixSmartInstall.sh
    chmod 777 /mnt/network-drives/Support/FramePkg/SmaretInstallLinux/TrellixSmartInstall.sh 
    cp  /mnt/network-drives/Support/FramePkg/SmaretInstallLinux/TrellixSmartInstall.sh /mnt
    dos2unix /mnt/TrellixSmartInstall.sh
    sudo /mnt/TrellixSmartInstall.sh
    if [ $? -eq 0 ]; then
        echo "TrellixSmartInstall script completed successfully."
    else
        echo "TrellixSmartInstall script failed. Exiting..."
        exit 1
    fi
    rm /mnt/TrellixSmartInstall.sh
}
install_usb_guard(){
    echo "installing usb guard"
    sudo apt install usbguard -y
    sudo systemctl enable usbguard
    sudo systemctl start usbguard
    echo "allow with-interface one-of { 03:*:* }" > /etc/usbguard/rules.conf
    sudo systemctl restart usbguard
    echo "usbguard has been installed and configured"
}
delete_script(){
    echo "deleting the script and the certificates from /home/user/ ..."
    rm -f /home/user/root_2024_ca.crt /home/user/pituah-linux.sh /home/user/intermediate_2024_ca.crt
}
## Main script
first_configuration
update_ca_crt
sync_ntp
install_required_packages
join_domain
mount_shared_drive
trigger_trellix_smart_install
install_usb_guard
delete_script
echo "Setup complete."
