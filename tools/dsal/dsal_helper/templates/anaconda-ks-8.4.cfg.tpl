#version=RHEL8
# Reboot after installation
reboot
# Use text mode install
graphical
repo --name="beaker-AppStream" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/AppStream/x86_64/os --cost=100
repo --name="beaker-BaseOS" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/BaseOS/x86_64/os --cost=100
repo --name="beaker-CRB" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/CRB/x86_64/os --cost=100
repo --name="beaker-HighAvailability" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/HighAvailability/x86_64/os --cost=100
repo --name="beaker-NFV" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/NFV/x86_64/os --cost=100
repo --name="beaker-ResilientStorage" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/ResilientStorage/x86_64/os --cost=100
repo --name="beaker-RT" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/RT/x86_64/os --cost=100
repo --name="beaker-SAP" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/SAP/x86_64/os --cost=100
repo --name="beaker-SAPHANA" --baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/SAPHANA/x86_64/os --cost=100
%pre --logfile=/dev/console
set -x
# Some distros have curl in their minimal install set, others have wget.
# We define a wrapper function around the best available implementation
# so that the rest of the script can use that for making HTTP requests.
if command -v curl >/dev/null ; then
    # Older curl versions lack --retry
    if curl --help 2>&1 | grep -q .*--retry ; then
        function fetch() {
            curl -L --retry 20 --remote-time -o "$1" "$2"
        }
    else
        function fetch() {
            curl -L --remote-time -o "$1" "$2"
        }
    fi
elif command -v wget >/dev/null ; then
    # In Anaconda images wget is actually busybox
    if wget --help 2>&1 | grep -q BusyBox ; then
        function fetch() {
            wget -O "$1" "$2"
        }
    else
        function fetch() {
            wget --tries 20 -O "$1" "$2"
        }
    fi
else
    echo "No HTTP client command available!"
    function fetch() {
        false
    }
fi
# no snippet data for RedHatEnterpriseLinux8_pre
# no snippet data for RedHatEnterpriseLinux_pre
%end
%post --logfile=/dev/console
set -x
# Some distros have curl in their minimal install set, others have wget.
# We define a wrapper function around the best available implementation
# so that the rest of the script can use that for making HTTP requests.
if command -v curl >/dev/null ; then
    # Older curl versions lack --retry
    if curl --help 2>&1 | grep -q .*--retry ; then
        function fetch() {
            curl -L --retry 20 --remote-time -o "$1" "$2"
        }
    else
        function fetch() {
            curl -L --remote-time -o "$1" "$2"
        }
    fi
elif command -v wget >/dev/null ; then
    # In Anaconda images wget is actually busybox
    if wget --help 2>&1 | grep -q BusyBox ; then
        function fetch() {
            wget -O "$1" "$2"
        }
    else
        function fetch() {
            wget --tries 20 -O "$1" "$2"
        }
    fi
else
    echo "No HTTP client command available!"
    function fetch() {
        false
    }
fi
fetch - http://lab-02.rhts.eng.rdu.redhat.com:8000/nopxe/{{ hostname }}
# If netboot_method= is found in /proc/cmdline record it to /root
netboot_method=$(grep -oP "(?<=netboot_method=)[^\s]+(?=)" /proc/cmdline)
if [ -n "$netboot_method" ]; then
echo $netboot_method >/root/NETBOOT_METHOD.TXT
fi
# Enable post-install boot notification
if [ -f /etc/sysconfig/readahead ] ; then
    :
    cat >>/etc/sysconfig/readahead <<EOF
# readahead conflicts with auditd, see bug 561486 for detailed explanation.
#
# Should a task need to change these settings, it must revert to this state
# when test is done.
READAHEAD_COLLECT="no"
READAHEAD_COLLECT_ON_RPM="no"
EOF
fi
systemctl disable systemd-readahead-collect.service
if [ -e /etc/sysconfig/ntpdate ] ; then
    systemctl enable ntpdate.service
fi
if [ -e "/etc/sysconfig/ntpd" ]; then
    systemctl enable ntpd.service
    GOT_G=$(/bin/cat /etc/sysconfig/ntpd | grep -E '^OPTIONS' | grep '\-g')
    if [ -z "$GOT_G" ]; then
        /bin/sed -i -r 's/(^OPTIONS\s*=\s*)(['\''|"])(.+)$/\1\2\-x \3 /' /etc/sysconfig/ntpd
    fi
fi
if [ -e /etc/chrony.conf ] ; then
    cp /etc/chrony.conf{,.orig}
    # use only DHCP-provided time servers, no default pool servers
    sed -i '/^server /d' /etc/chrony.conf
    cp /etc/sysconfig/network{,.orig}
    # setting iburst should speed up initial sync
    # https://bugzilla.redhat.com/show_bug.cgi?id=787042#c12
    echo NTPSERVERARGS=iburst >>/etc/sysconfig/network
    systemctl disable ntpd.service
    systemctl disable ntpdate.service
    systemctl enable chronyd.service
    systemctl enable chrony-wait.service
fi
if efibootmgr &>/dev/null ; then
    # The installer should have added a new boot entry for the OS
    # at the top of the boot order. We move it to the end of the order
    # and set it as BootNext instead.
    boot_order=$(efibootmgr | awk '/BootOrder/ { print $2 }')
    os_boot_entry=$(cut -d, -f1 <<<"$boot_order")
    new_boot_order=$(cut -d, -f2- <<<"$boot_order"),"$os_boot_entry"
    efibootmgr -o "$new_boot_order"
    efibootmgr -n "$os_boot_entry"
    # save the boot entry for later, so that rhts-reboot can set BootNext as well
    echo "$os_boot_entry" >/root/EFI_BOOT_ENTRY.TXT
fi
# Add distro and custom Repos
cat <<"EOF" >/etc/yum.repos.d/beaker-AppStream-debuginfo.repo
[beaker-AppStream-debuginfo]
name=beaker-AppStream-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/AppStream/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-BaseOS-debuginfo.repo
[beaker-BaseOS-debuginfo]
name=beaker-BaseOS-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/BaseOS/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-CRB-debuginfo.repo
[beaker-CRB-debuginfo]
name=beaker-CRB-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/CRB/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-HighAvailability-debuginfo.repo
[beaker-HighAvailability-debuginfo]
name=beaker-HighAvailability-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/HighAvailability/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-NFV-debuginfo.repo
[beaker-NFV-debuginfo]
name=beaker-NFV-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/NFV/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-ResilientStorage-debuginfo.repo
[beaker-ResilientStorage-debuginfo]
name=beaker-ResilientStorage-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/ResilientStorage/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-RT-debuginfo.repo
[beaker-RT-debuginfo]
name=beaker-RT-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/RT/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-SAP-debuginfo.repo
[beaker-SAP-debuginfo]
name=beaker-SAP-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/SAP/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-SAPHANA-debuginfo.repo
[beaker-SAPHANA-debuginfo]
name=beaker-SAPHANA-debuginfo
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/SAPHANA/x86_64/debug/tree
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-AppStream.repo
[beaker-AppStream]
name=beaker-AppStream
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/AppStream/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-BaseOS.repo
[beaker-BaseOS]
name=beaker-BaseOS
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/BaseOS/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-CRB.repo
[beaker-CRB]
name=beaker-CRB
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/CRB/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-HighAvailability.repo
[beaker-HighAvailability]
name=beaker-HighAvailability
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/HighAvailability/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-NFV.repo
[beaker-NFV]
name=beaker-NFV
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/NFV/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-ResilientStorage.repo
[beaker-ResilientStorage]
name=beaker-ResilientStorage
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/ResilientStorage/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-RT.repo
[beaker-RT]
name=beaker-RT
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/RT/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-SAP.repo
[beaker-SAP]
name=beaker-SAP
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/SAP/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
cat <<"EOF" >/etc/yum.repos.d/beaker-SAPHANA.repo
[beaker-SAPHANA]
name=beaker-SAPHANA
baseurl=http://download.eng.rdu.redhat.com/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/SAPHANA/x86_64/os
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
#Add test user account
useradd --password '$6$oIW3o2Mr$XbWZKaM7nA.cQqudfDJScupXOia5h1u517t6Htx/Q/MgXm82Pc/OcytatTeI4ULNWOMJzvpCigWiL4xKP9PX4.' test
cat <<"EOF" >/etc/profile.d/beaker.sh
export BEAKER="https://beaker.engineering.redhat.com/"
export BEAKER_RESERVATION_POLICY_URL="https://home.corp.redhat.com/wiki/extended-reservations-beaker-general-pool-systems"
export BEAKER_JOB_WHITEBOARD=''
export BEAKER_RECIPE_WHITEBOARD=''
EOF
cat <<"EOF" >/etc/profile.d/beaker.csh
setenv BEAKER "https://beaker.engineering.redhat.com/"
setenv BEAKER_RESERVATION_POLICY_URL "https://home.corp.redhat.com/wiki/extended-reservations-beaker-general-pool-systems"
setenv BEAKER_JOB_WHITEBOARD ''
setenv BEAKER_RECIPE_WHITEBOARD ''
EOF
cat << EOF > /etc/profile.d/rh-env.sh
export LAB_CONTROLLER=lab-02.rhts.eng.rdu.redhat.com
export DUMPSERVER=netdump-01.eng.rdu.redhat.com
# PNT0844470 - Added fs-netapp-kernel1.fs.lab.eng.bos.redhat.com:/export/home
export NFSSERVERS="rhel5-nfs.eng.rdu2.redhat.com:/export/home rhel6-nfs.eng.rdu2.redhat.com:/export/home rhel7-nfs.eng.rdu2.redhat.com:/export/home rhel8-nfs.eng.rdu2.redhat.com:/export/home fs-netapp-kernel1.fs.lab.eng.bos.redhat.com:/export/home"
export LOOKASIDE=http://download.eng.rdu.redhat.com/qa/rhts/lookaside/
export BUILDURL=http://download.eng.rdu.redhat.com
EOF
cat << EOF > /etc/profile.d/rh-env.csh
setenv LAB_CONTROLLER lab-02.rhts.eng.rdu.redhat.com
setenv DUMPSERVER netdump-01.eng.rdu.redhat.com
# PNT0844470 - Added fs-netapp-kernel1.fs.lab.eng.bos.redhat.com:/export/home
setenv NFSSERVERS "rhel5-nfs.eng.rdu2.redhat.com:/export/home rhel6-nfs.eng.rdu2.redhat.com:/export/home rhel7-nfs.eng.rdu2.redhat.com:/export/home rhel8-nfs.eng.rdu2.redhat.com:/export/home fs-netapp-kernel1.fs.lab.eng.bos.redhat.com:/export/home"
setenv LOOKASIDE http://download.eng.rdu.redhat.com/qa/rhts/lookaside/
setenv BUILDURL http://download.eng.rdu.redhat.com
EOF
mkdir -p /root/.ssh
cat >>/root/.ssh/authorized_keys <<"__EOF__"
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDYt5FqMTz91Mbctj7wWg2tAkzwMDwDFtvw0l/6SGPqV+w84SxM1sRmCm1iGdjCk7Rhy3493yRMrA6RT02yTQnXyXG5xC9stspWku9GPNNXyg83SvC/iz53E5SWwYQISmgBK+dYNwzjiN8C8ohxmT8elV1ElckgGvzTOk80KygUzpf+KOfezQcSXZWxBbYsK/8FamPBoWGLCByv+zVX+dSjNgraqdGZDlXns+NiZAeEHeBwKTufFpN//1xm4lG+ah4g5oqaXNf1M7LApPSSm4r5VdFp0+S5SbcPocu+ztwttstnLI0fgJ5XUyqUJM0fZbaj1qkhFeG7bCi/75XIjnkp emilien@redhat.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+ZdUvwKeRABWAfo7h4NzTOcpPWrW9LlmXuw1bfReREO2z69g5M9wYzKHqz9fhG3+4t5J8eqW4RAPHunGX2mpWfI3o+fCzJvo2R6izJrfs//BNez5JCp7u1ObXfPFub1y6Y1OmDeji3jwABl89roba6DQJ6FiD2rCA6cWM1K7fg9TWzWH/8/6ZJTSiEl3LICG3az1tfANs02hMn8f5iLqH30sgYn/SnkC0AqkqCx0B+RXOWRj5F3PcOrVOsgtlCIUHIpqhuwTNTIu9bOVrk9+O9VKOGSNLgptyg+HGTcopXYrmMrxpwVxscXKJX+q28Lj/zBp/MovChmlgWc1hgDEuepDhIPpABNDUmGEgy0dhn/j1grBeAf2p4YleXyVHeCnyegk96zuF9QucmJ5JMvdpU6UK2o4ZREzJblgWm63J93zHwaeAWjB+RSnNdPqYCPUZejOOj1dntFVexeXkl75N2JAXf0E1u3wATlYi3uGN3fEsMtnBiyjpp7CLjVBQJzs= maysamacedo@mmacedo
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDU4rf08cgZK67gQPAaeNxvzIiAs/KCggvlHg8CxRItWOIIyUsavzmHwnl3bayyuu08yRwAMGjaeT+iBQH2vcOT2bC7SSCTBeL1M7Y0Q2gKfnGcjpLTc7Vc+H+CTa/SPcYzd4shkXRmr1SAlY0qzXM+LZ7cZALMk2OlLru3ulq6/Jdnyl4mlIBNzgh2CculOrDmsMyCR/K3R4hILInF2LI1N68zo5E7T3TJRiiq92M4BCYuwHGLxonTdVggdd9/Qut+MSqQazL1MxmFbxFjHbL7401uxTVXi18X1O0LXdoXX8opMW5534W9o4kcyoYwGZqoB4W5FTnSdzsXNJsUiX65
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDp++/dLSVmUE3zlTYvpsYgUw1AV4tS9V87B8Tu3dX6xrjlE/42zOWaa+QE81IccPDOXTnPGkmsNAlVyYos7aT8crtyV5crn3ovZE/99ZTYp3VhJYJ+vkasU6b0PpnItaW/Om1iO4VKJcROHPflDY2xQId1J4WSsDJm4f12oM8GSA8Ix9S03lOQLjKzPhsWdy4J4et5hX6uEznuiRtJYppNpBsFd4hjXcLOcrJYSISYPJTMUz147pFDGNkZ7PV2TddsOZawWX/QwNmc+f/z07jxAYTj8ChZEUZ1EjF6A0kCC7lyNaeoqTLxFbQNO85qcyH+FVh0QdBWa1aRVNvT/dCH
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC3iSR15QxAzsSwTyOB5PLpAwtSddG/s4TqAGyUo4gbNxWR7VDGoR9yuJA+Pz3rifFoK9PZXaYMFRvbZa7bmE9zFgkMKVdL02CouQnZJe5h4gpX4NPfu7pGo3hvFYNmM25IjE+Wj3wsOzHWJdScxkpX0UZSujj/ET5ZRugaShh1HScvSTw0LkoA67v0ajE4HsfBoVyV+p3GIU7xc1RUj4EZjQpAgyWULA6VuQtjkXSxXQpzq2z7jE5/IlfnsIyF7O6Y+wijsYO/fyHRwrtXXCiGXI+cNH9K8UXmFPh19saZxdb1GwptbPkpNNAJ/lTFxFfWal6brRA2bzmRSjRQMFztHu9kCN0i0KIZz+dn5/ku65PMxiHoE9t58Fc2XGSziR+dl/LOWbXjkPQjCBJduC5vXrltY2Bo6uQOxmpkRRQvf7gAPKaMU5QA96mDZVR9Ifd++wrNbLv3qsf9fpSFeBaN6mOxTlMmGL7dFbPx3pihZLtIOxqlIN7CaOTyewuLfrM=
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDc5hwTXjAxIAG/Po2p9yDWtrQXkH1dg0LNOVrWJw/I6BkVrM3W5/PFX0NbTs0pNQ9pT1VQohX7mNDZhSmiE9ILaDcnidhNQDInmo2ifIGuBhKUxssNfyc9lXQ6Ek55aHRQNxBnOFz9237tBZtdmx/9UhsmPg13a4Iir2laHw0L8UMIMfN/l9rDZarWqzIp/pfZUcFpX+4WgcFsAj9H4LvmJNWdMxZtiDGtGC86CdlZAkxrbPwMtrqNE3TppEj0d2dzvezjcsg8WRWGgeTfSTW+MSEOV+0aoZRqw++rnIwUdmlhQ9TR2fazdDKTUkpTauayOqEyJbdKanizVQI0zbl9
__EOF__
restorecon -R /root/.ssh
chmod go-w /root /root/.ssh /root/.ssh/authorized_keys
# Disable rhts-compat for Fedora15/RHEL7 and newer.
cat >> /etc/profile.d/task-overrides-rhts.sh <<END
export RHTS_OPTION_COMPATIBLE=
export RHTS_OPTION_COMPAT_SERVICE=
END
# no snippet data for RedHatEnterpriseLinux8_post
# no snippet data for RedHatEnterpriseLinux_post
mkdir -p /root/.ssh
cat >>/root/.ssh/authorized_keys <<"__EOF__"
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDYt5FqMTz91Mbctj7wWg2tAkzwMDwDFtvw0l/6SGPqV+w84SxM1sRmCm1iGdjCk7Rhy3493yRMrA6RT02yTQnXyXG5xC9stspWku9GPNNXyg83SvC/iz53E5SWwYQISmgBK+dYNwzjiN8C8ohxmT8elV1ElckgGvzTOk80KygUzpf+KOfezQcSXZWxBbYsK/8FamPBoWGLCByv+zVX+dSjNgraqdGZDlXns+NiZAeEHeBwKTufFpN//1xm4lG+ah4g5oqaXNf1M7LApPSSm4r5VdFp0+S5SbcPocu+ztwttstnLI0fgJ5XUyqUJM0fZbaj1qkhFeG7bCi/75XIjnkp emilien@redhat.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+ZdUvwKeRABWAfo7h4NzTOcpPWrW9LlmXuw1bfReREO2z69g5M9wYzKHqz9fhG3+4t5J8eqW4RAPHunGX2mpWfI3o+fCzJvo2R6izJrfs//BNez5JCp7u1ObXfPFub1y6Y1OmDeji3jwABl89roba6DQJ6FiD2rCA6cWM1K7fg9TWzWH/8/6ZJTSiEl3LICG3az1tfANs02hMn8f5iLqH30sgYn/SnkC0AqkqCx0B+RXOWRj5F3PcOrVOsgtlCIUHIpqhuwTNTIu9bOVrk9+O9VKOGSNLgptyg+HGTcopXYrmMrxpwVxscXKJX+q28Lj/zBp/MovChmlgWc1hgDEuepDhIPpABNDUmGEgy0dhn/j1grBeAf2p4YleXyVHeCnyegk96zuF9QucmJ5JMvdpU6UK2o4ZREzJblgWm63J93zHwaeAWjB+RSnNdPqYCPUZejOOj1dntFVexeXkl75N2JAXf0E1u3wATlYi3uGN3fEsMtnBiyjpp7CLjVBQJzs= maysamacedo@mmacedo
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDU4rf08cgZK67gQPAaeNxvzIiAs/KCggvlHg8CxRItWOIIyUsavzmHwnl3bayyuu08yRwAMGjaeT+iBQH2vcOT2bC7SSCTBeL1M7Y0Q2gKfnGcjpLTc7Vc+H+CTa/SPcYzd4shkXRmr1SAlY0qzXM+LZ7cZALMk2OlLru3ulq6/Jdnyl4mlIBNzgh2CculOrDmsMyCR/K3R4hILInF2LI1N68zo5E7T3TJRiiq92M4BCYuwHGLxonTdVggdd9/Qut+MSqQazL1MxmFbxFjHbL7401uxTVXi18X1O0LXdoXX8opMW5534W9o4kcyoYwGZqoB4W5FTnSdzsXNJsUiX65
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDp++/dLSVmUE3zlTYvpsYgUw1AV4tS9V87B8Tu3dX6xrjlE/42zOWaa+QE81IccPDOXTnPGkmsNAlVyYos7aT8crtyV5crn3ovZE/99ZTYp3VhJYJ+vkasU6b0PpnItaW/Om1iO4VKJcROHPflDY2xQId1J4WSsDJm4f12oM8GSA8Ix9S03lOQLjKzPhsWdy4J4et5hX6uEznuiRtJYppNpBsFd4hjXcLOcrJYSISYPJTMUz147pFDGNkZ7PV2TddsOZawWX/QwNmc+f/z07jxAYTj8ChZEUZ1EjF6A0kCC7lyNaeoqTLxFbQNO85qcyH+FVh0QdBWa1aRVNvT/dCH
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC3iSR15QxAzsSwTyOB5PLpAwtSddG/s4TqAGyUo4gbNxWR7VDGoR9yuJA+Pz3rifFoK9PZXaYMFRvbZa7bmE9zFgkMKVdL02CouQnZJe5h4gpX4NPfu7pGo3hvFYNmM25IjE+Wj3wsOzHWJdScxkpX0UZSujj/ET5ZRugaShh1HScvSTw0LkoA67v0ajE4HsfBoVyV+p3GIU7xc1RUj4EZjQpAgyWULA6VuQtjkXSxXQpzq2z7jE5/IlfnsIyF7O6Y+wijsYO/fyHRwrtXXCiGXI+cNH9K8UXmFPh19saZxdb1GwptbPkpNNAJ/lTFxFfWal6brRA2bzmRSjRQMFztHu9kCN0i0KIZz+dn5/ku65PMxiHoE9t58Fc2XGSziR+dl/LOWbXjkPQjCBJduC5vXrltY2Bo6uQOxmpkRRQvf7gAPKaMU5QA96mDZVR9Ifd++wrNbLv3qsf9fpSFeBaN6mOxTlMmGL7dFbPx3pihZLtIOxqlIN7CaOTyewuLfrM=
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDc5hwTXjAxIAG/Po2p9yDWtrQXkH1dg0LNOVrWJw/I6BkVrM3W5/PFX0NbTs0pNQ9pT1VQohX7mNDZhSmiE9ILaDcnidhNQDInmo2ifIGuBhKUxssNfyc9lXQ6Ek55aHRQNxBnOFz9237tBZtdmx/9UhsmPg13a4Iir2laHw0L8UMIMfN/l9rDZarWqzIp/pfZUcFpX+4WgcFsAj9H4LvmJNWdMxZtiDGtGC86CdlZAkxrbPwMtrqNE3TppEj0d2dzvezjcsg8WRWGgeTfSTW+MSEOV+0aoZRqw++rnIwUdmlhQ9TR2fazdDKTUkpTauayOqEyJbdKanizVQI0zbl9
__EOF__
restorecon -R /root/.ssh
chmod go-w /root /root/.ssh /root/.ssh/authorized_keys
# Disable rhts-compat for Fedora15/RHEL7 and newer.
cat >> /etc/profile.d/task-overrides-rhts.sh <<END
export RHTS_OPTION_COMPATIBLE=
export RHTS_OPTION_COMPAT_SERVICE=
END
mkdir -m0700 /home/stack/.ssh/
cat <<EOF >/home/stack/.ssh/authorized_keys
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDYt5FqMTz91Mbctj7wWg2tAkzwMDwDFtvw0l/6SGPqV+w84SxM1sRmCm1iGdjCk7Rhy3493yRMrA6RT02yTQnXyXG5xC9stspWku9GPNNXyg83SvC/iz53E5SWwYQISmgBK+dYNwzjiN8C8ohxmT8elV1ElckgGvzTOk80KygUzpf+KOfezQcSXZWxBbYsK/8FamPBoWGLCByv+zVX+dSjNgraqdGZDlXns+NiZAeEHeBwKTufFpN//1xm4lG+ah4g5oqaXNf1M7LApPSSm4r5VdFp0+S5SbcPocu+ztwttstnLI0fgJ5XUyqUJM0fZbaj1qkhFeG7bCi/75XIjnkp emilien@redhat.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+ZdUvwKeRABWAfo7h4NzTOcpPWrW9LlmXuw1bfReREO2z69g5M9wYzKHqz9fhG3+4t5J8eqW4RAPHunGX2mpWfI3o+fCzJvo2R6izJrfs//BNez5JCp7u1ObXfPFub1y6Y1OmDeji3jwABl89roba6DQJ6FiD2rCA6cWM1K7fg9TWzWH/8/6ZJTSiEl3LICG3az1tfANs02hMn8f5iLqH30sgYn/SnkC0AqkqCx0B+RXOWRj5F3PcOrVOsgtlCIUHIpqhuwTNTIu9bOVrk9+O9VKOGSNLgptyg+HGTcopXYrmMrxpwVxscXKJX+q28Lj/zBp/MovChmlgWc1hgDEuepDhIPpABNDUmGEgy0dhn/j1grBeAf2p4YleXyVHeCnyegk96zuF9QucmJ5JMvdpU6UK2o4ZREzJblgWm63J93zHwaeAWjB+RSnNdPqYCPUZejOOj1dntFVexeXkl75N2JAXf0E1u3wATlYi3uGN3fEsMtnBiyjpp7CLjVBQJzs= maysamacedo@mmacedo
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDU4rf08cgZK67gQPAaeNxvzIiAs/KCggvlHg8CxRItWOIIyUsavzmHwnl3bayyuu08yRwAMGjaeT+iBQH2vcOT2bC7SSCTBeL1M7Y0Q2gKfnGcjpLTc7Vc+H+CTa/SPcYzd4shkXRmr1SAlY0qzXM+LZ7cZALMk2OlLru3ulq6/Jdnyl4mlIBNzgh2CculOrDmsMyCR/K3R4hILInF2LI1N68zo5E7T3TJRiiq92M4BCYuwHGLxonTdVggdd9/Qut+MSqQazL1MxmFbxFjHbL7401uxTVXi18X1O0LXdoXX8opMW5534W9o4kcyoYwGZqoB4W5FTnSdzsXNJsUiX65
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDp++/dLSVmUE3zlTYvpsYgUw1AV4tS9V87B8Tu3dX6xrjlE/42zOWaa+QE81IccPDOXTnPGkmsNAlVyYos7aT8crtyV5crn3ovZE/99ZTYp3VhJYJ+vkasU6b0PpnItaW/Om1iO4VKJcROHPflDY2xQId1J4WSsDJm4f12oM8GSA8Ix9S03lOQLjKzPhsWdy4J4et5hX6uEznuiRtJYppNpBsFd4hjXcLOcrJYSISYPJTMUz147pFDGNkZ7PV2TddsOZawWX/QwNmc+f/z07jxAYTj8ChZEUZ1EjF6A0kCC7lyNaeoqTLxFbQNO85qcyH+FVh0QdBWa1aRVNvT/dCH
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC3iSR15QxAzsSwTyOB5PLpAwtSddG/s4TqAGyUo4gbNxWR7VDGoR9yuJA+Pz3rifFoK9PZXaYMFRvbZa7bmE9zFgkMKVdL02CouQnZJe5h4gpX4NPfu7pGo3hvFYNmM25IjE+Wj3wsOzHWJdScxkpX0UZSujj/ET5ZRugaShh1HScvSTw0LkoA67v0ajE4HsfBoVyV+p3GIU7xc1RUj4EZjQpAgyWULA6VuQtjkXSxXQpzq2z7jE5/IlfnsIyF7O6Y+wijsYO/fyHRwrtXXCiGXI+cNH9K8UXmFPh19saZxdb1GwptbPkpNNAJ/lTFxFfWal6brRA2bzmRSjRQMFztHu9kCN0i0KIZz+dn5/ku65PMxiHoE9t58Fc2XGSziR+dl/LOWbXjkPQjCBJduC5vXrltY2Bo6uQOxmpkRRQvf7gAPKaMU5QA96mDZVR9Ifd++wrNbLv3qsf9fpSFeBaN6mOxTlMmGL7dFbPx3pihZLtIOxqlIN7CaOTyewuLfrM=
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDc5hwTXjAxIAG/Po2p9yDWtrQXkH1dg0LNOVrWJw/I6BkVrM3W5/PFX0NbTs0pNQ9pT1VQohX7mNDZhSmiE9ILaDcnidhNQDInmo2ifIGuBhKUxssNfyc9lXQ6Ek55aHRQNxBnOFz9237tBZtdmx/9UhsmPg13a4Iir2laHw0L8UMIMfN/l9rDZarWqzIp/pfZUcFpX+4WgcFsAj9H4LvmJNWdMxZtiDGtGC86CdlZAkxrbPwMtrqNE3TppEj0d2dzvezjcsg8WRWGgeTfSTW+MSEOV+0aoZRqw++rnIwUdmlhQ9TR2fazdDKTUkpTauayOqEyJbdKanizVQI0zbl9
EOF
### set permissions
chmod 0600 /home/stack/.ssh/authorized_keys
chown -R stack:stack /home/stack/.ssh
### fix up selinux context
restorecon -R /home/stack/.ssh/
### sudoers
echo "stack ALL=(ALL)       NOPASSWD: ALL">>/etc/sudoers
sudo nmcli connection modify "eno1" ipv6.method "disabled"
# Red Hat certificate
cat <<EOF >/etc/pki/tls/certs/2015-RH-IT-Root-CA.pem
-----BEGIN CERTIFICATE-----
MIIENDCCAxygAwIBAgIJANunI0D662cnMA0GCSqGSIb3DQEBCwUAMIGlMQswCQYD
VQQGEwJVUzEXMBUGA1UECAwOTm9ydGggQ2Fyb2xpbmExEDAOBgNVBAcMB1JhbGVp
Z2gxFjAUBgNVBAoMDVJlZCBIYXQsIEluYy4xEzARBgNVBAsMClJlZCBIYXQgSVQx
GzAZBgNVBAMMElJlZCBIYXQgSVQgUm9vdCBDQTEhMB8GCSqGSIb3DQEJARYSaW5m
b3NlY0ByZWRoYXQuY29tMCAXDTE1MDcwNjE3MzgxMVoYDzIwNTUwNjI2MTczODEx
WjCBpTELMAkGA1UEBhMCVVMxFzAVBgNVBAgMDk5vcnRoIENhcm9saW5hMRAwDgYD
VQQHDAdSYWxlaWdoMRYwFAYDVQQKDA1SZWQgSGF0LCBJbmMuMRMwEQYDVQQLDApS
ZWQgSGF0IElUMRswGQYDVQQDDBJSZWQgSGF0IElUIFJvb3QgQ0ExITAfBgkqhkiG
9w0BCQEWEmluZm9zZWNAcmVkaGF0LmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEP
ADCCAQoCggEBALQt9OJQh6GC5LT1g80qNh0u50BQ4sZ/yZ8aETxt+5lnPVX6MHKz
bfwI6nO1aMG6j9bSw+6UUyPBHP796+FT/pTS+K0wsDV7c9XvHoxJBJJU38cdLkI2
c/i7lDqTfTcfLL2nyUBd2fQDk1B0fxrskhGIIZ3ifP1Ps4ltTkv8hRSob3VtNqSo
GxkKfvD2PKjTPxDPWYyruy9irLZioMffi3i/gCut0ZWtAyO3MVH5qWF/enKwgPES
X9po+TdCvRB/RUObBaM761EcrLSM1GqHNueSfqnho3AjLQ6dBnPWlo638Zm1VebK
BELyhkLWMSFkKwDmne0jQ02Y4g075vCKvCsCAwEAAaNjMGEwHQYDVR0OBBYEFH7R
4yC+UehIIPeuL8Zqw3PzbgcZMB8GA1UdIwQYMBaAFH7R4yC+UehIIPeuL8Zqw3Pz
bgcZMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEB
CwUAA4IBAQBDNvD2Vm9sA5A9AlOJR8+en5Xz9hXcxJB5phxcZQ8jFoG04Vshvd0e
LEnUrMcfFgIZ4njMKTQCM4ZFUPAieyLx4f52HuDopp3e5JyIMfW+KFcNIpKwCsak
oSoKtIUOsUJK7qBVZxcrIyeQV2qcYOeZhtS5wBqIwOAhFwlCET7Ze58QHmS48slj
S9K0JAcps2xdnGu0fkzhSQxY8GPQNFTlr6rYld5+ID/hHeS76gq0YG3q6RLWRkHf
4eTkRjivAlExrFzKcljC4axKQlnOvVAzz+Gm32U0xPBF4ByePVxCJUHw1TsyTmel
RxNEp7yHoXcwn+fXna+t5JWh1gxUZty3
-----END CERTIFICATE-----
EOF
chmod 640 /etc/pki/tls/certs/2015-RH-IT-Root-CA.pem
%end
%packages --default --ignoremissing
vim
wget
%end
# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us'
# System language
lang en_US.UTF-8
# Firewall configuration
firewall --disabled
# Network information
network  --bootproto=dhcp --device=bootif --hostname={{ hostname }} --noipv6 --activate
# Use NFS installation media
nfs --server=ntap-rdu2-c01-eng01-nfs01b.storage.rdu2.redhat.com --dir=/bos_eng01_engineering_sm/devarchive/redhat/rhel-8/rel-eng/RHEL-8/RHEL-8.4.0-20210409.0/compose/BaseOS/x86_64/os/
# SELinux configuration
selinux --enforcing
firstboot --disable
# Do not configure the X Window System
skipx
ignoredisk --only-use={{ disks }}
zerombr
clearpart --all --initlabel
bootloader --append="crashkernel=auto" --location=mbr --boot-drive={{ boot_disk }}
part pv.{{ boot_disk }} --fstype="lvmpv" --ondisk={{ boot_disk }} --size=530000
part /boot --fstype="xfs" --ondisk={{ boot_disk }} --size=1024
volgroup system --pesize=4096 pv.{{ boot_disk }}
logvol swap --fstype="swap" --size=4096 --name=swap --vgname=system
logvol / --fstype="xfs" --size=400000 --name=root --vgname=system
logvol /home --fstype="xfs" --size=120000 --name=home --vgname=system
# System timezone
timezone America/New_York
user --groups=wheel --name=stack --password=$6$IIe8jz.CpBnhLDar$MS/Qi1M7yNgarAg5mkYf7zzxZVxs76etLJQP58U9Zl4YJRDE5zakSz70pa3eGnxYuI1YzgVfe5xqi8qpOBY33/ --iscrypted --gecos="stack"
# Root password
rootpw --iscrypted $1$bKEwJzGL$9YZKyj2/LtKTqyFmd9eg.1
%addon com_redhat_kdump --enable --reserve-mb='auto'
%end
