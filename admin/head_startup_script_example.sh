nis_domain="sfarm"

#----------------------------------------------------------------------------------------------

setup_nis_server(){

echo "*** CONFIGURING NIS SERVER ***"

echo "Install some package..."
yum install -y yp-tools ypbind ypserv

echo "Write configurations..."
echo "domain $nis_domain server $HOSTNAME" >> /etc/yp.conf
echo "NISDOMAIN=\"$nis_domain\"" >> /etc/sysconfig/network

echo "Set NIS domain name..."
domainname $nis_domain
ypdomainname $nis_domain

# Change: private network range
echo "Define secure network..."
cat <<EOF > /var/yp/securenets
host 127.0.0.1
255.255.255.0   172.16.XXX.0       
EOF

echo "Make sure rpcbind is running..."
service rpcbind start
chkconfig rpcbind on

echo "Start ypserv service..."
service ypserv start

echo "Initialize NIS maps..."
echo "none"  | xargs -E none /usr/lib64/yp/ypinit -m

echo "Start ypbind, yppasswdd, ypxfrd..."
service ypbind start
service yppasswdd start
service ypxfrd start

chkconfig ypserv on
chkconfig ypbind on
chkconfig yppasswdd on
chkconfig ypxfrd on

}

#----------------------------------------------------------------------------------------------

setup_nfs(){

echo "*** CONFIGURING NFS SERVER ***"

echo "Creating export dir for /home..."
mkdir -p /export/home

echo "Creating export dir for /teodata..."
mkdir -p /export/teodata

# Change: make sure that the home and teodata volumes correspond to /dev/vdd and /dev/vde
# (the Sunstone GUI might help)
echo "Adding entry in /etc/fstab..."
cat <<EOF >> /etc/fstab
# Mount and export home
/dev/vdd /home ext3 defaults,noatime 0 0
/home /export/home none bind 0 0
/dev/vde /teodata ext4 defaults,noatime 0 0
/teodata /export/teodata none bind 0 0
EOF

echo "Adding entry in /etc/exports..."

# Change: private network range
cat <<EOF >> /etc/exports
/export 172.16.XXX.0/24(rw,fsid=0,insecure,no_subtree_check,async,no_root_squash)
/export/home 172.16.XXX.0/24(rw,fsid=1,nohide,insecure,no_subtree_check,async,no_root_squash)
/export/teodata 172.16.XXX.0/24(rw,fsid=2,nohide,insecure,no_subtree_check,async,no_root_squash)
EOF

echo "Starting NFS at boot..."
chkconfig nfs on

# Script to be run after mounting persistent disks 
# Change: make sure that the home and teodata volumes correspond to /dev/vdd and /dev/vde
# (the Sunstone GUI might help)
cat <<EOF >> /root/mount_stuff.sh
#!/bin/sh
# data for theory group
mkdir /teodata
chmod 0775 /teodata
mount /dev/vde /teodata
mount --bind /teodata /export/teodata
# home
mount /dev/vdd /home
mount --bind /home /export/home
service nfs start
exportfs -a
service nfs restart
echo "Now remove /etc/nologin !!!"
EOF

chmod +x /root/mount_home.sh

}

#----------------------------------------------------------------------------------------------

add_users(){

echo "*** ADDING USERS ***"

# New users should be created on the existing farm first, 
# so that the home directories are created on the persistent disk, 
# which is not yet mounted at boot time.
# Please remember to specify the user's uid and gid here, in order to 
# be consistent with the permissions on the persistent disk.

# Change: add all existing users with default password
groupadd -g 486 alice
groupadd -g 509 teo
useradd -m -u 503 -g alice -p <default_password_encrypted> testuser

pushd /var/yp
make
popd

}

nologin(){

echo "*** CONFIGURING NO SSH LOGIN ***"

echo "No login until home directory is properly mounted!" > /etc/nologin

}

#----------------------------------------------------------------------------------------------

create_alice_login(){

echo "*** CREATING ALICE LOGIN SCRIPT ***"

cat > /usr/bin/alice-login <<\_EoF_
#!/bin/sh
# Very simple example  script to set the ALICE env.
# Mailto: svallero@to.infn.it

function usage(){
  echo -e "\e[32mUsage:\e[0m"
  echo "        -l | --listversions     to list all available AliRoot versions"
  echo "        -h | --help             print this manual and exit"
  echo ""
  echo -e "\e[32mSet the desired AliRoot version in the file $HOME/.sfarm.conf\e[0m"
}

# Entry point
# parse command-line options
while [ "$1" != "" ]; do
    case $1 in
        -l | --listversions )   versions=1
                                ;;
        -h | --help )           usage
                                exit
                                ;;
        * )                     usage
                                exit 1
    esac
    shift
done

# set the ALICE environment  
source /cvmfs/alice.cern.ch/etc/login.sh

# list available AliRoot versions
if [ $versions ]; then
  echo -e "\e[32mAvailable AliRoot versions:\e[0m"
  alienv q | grep 'AliRoot\|AliPhysics'
  exit 0
fi

# check for config file and write one if not there
conf_file=".sfarm.conf"
if [ ! -f $conf_file ]; then
    echo -e "\e[32mConfig file not found, writing one now...\e[0m"
    echo "export SFarmAliPhysicsVersion=\"vAN-20161005-1\"" > $conf_file
    echo "#export SFarmAliRootVersion=\"vAN-20141216\"" >> $conf_file
    ls -rtlh $conf_file
fi

. $HOME/$conf_file
if [ $SFarmAliRootVersion ]; then
   echo -e "\e[32mSetting AliRoot version to $SFarmAliRootVersion...\e[0m"
   echo -e "\e[32m(use \"exit\" to quit the environment)\e[0m"
   # actually set the environment
   alienv enter VO_ALICE@AliRoot::$SFarmAliRootVersion
elif [ $SFarmAliPhysicsVersion ]; then
   echo -e "\e[32mSetting AliPhysics version to $SFarmAliPhysicsVersion...\e[0m"
   echo -e "\e[32m(use \"exit\" to quit the environment)\e[0m"
   # actually set the environment
   alienv enter VO_ALICE@AliPhysics::$SFarmAliPhysicsVersion
else
   echo "No version of AliRoot or AliPhysics set!"
fi
_EoF_

chmod +x /usr/bin/alice-login

}

#----------------------------------------------------------------------------------------------

configure_condor(){

echo "*** SETTING HTCONDOR USER LIMITS ***"

cat > /etc/condor/config.d/60sfarmquotas <<\_EoF_
#
# "Quotas" per user
#

# Our requirements contain an expression that changes at every accepted job. We
# cannot therefore optimize matchmaking by caching the results for a specific
# "requirements" string, but we will need to evaluate it per job.
NEGOTIATOR_MATCHLIST_CACHING = False

# We define for convenience a variable with the default maximum jobs per user.
# This variable will be evaluated against the SubmitterUserResourcesInUse
# expression in the negotiator, which is a float as it is weighted by taking
# SlotWeight into account.
#
# NOTE: Ideally it is sufficient to change the following three variables
# without touching the Requirements expression.
MAX_RUNNING_JOBS_PER_NORMAL_USER = 1
MAX_RUNNING_JOBS_PER_REAL_USER = 24
MAX_RUNNING_JOBS_PER_POWER_USER = 200
REAL_USERS = ebruna, mpuccio, mconcas, testuser, coppedis, msitta, aberaudo, mnardi, mmonteno, fprino, a
depace
POWER_USERS = svallero

# Per user quota implementation is done by enforcing the following Requirements
# string. Note: the expression takes into account that some variables are
# available to the negotiator only.
APPEND_REQUIREMENTS = ( \
    isUndefined(SubmitterUserResourcesInUse) || \
    ( stringListMember( Owner, "$(POWER_USERS)" ) && (SubmitterUserResourcesInUse <= ($(MAX_RUNNING_JOBS_PER_POWER_USER)-1.0)) ) || \
    ( stringListMember( Owner, "$(REAL_USERS)" ) && (SubmitterUserResourcesInUse <= ($(MAX_RUNNING_JOBS_PER_REAL_USER)-1.0)) ) || \
    (SubmitterUserResourcesInUse <= ($(MAX_RUNNING_JOBS_PER_NORMAL_USER)-1.0)) )
_EoF_

}

#----------------------------------------------------------------------------------------------

fix_boto_version(){

echo "*** SETTING BOTO VERSION TO BE COMPATIBLE WITH ONE_MASTER ***"
pip install boto==2.34

}

#----------------------------------------------------------------------------------------------

infn_ca_certificate(){

echo "*** NEW INFN CA CERTIFICATE ***"
wget https://security.fi.infn.it/CA/mgt/INFN-CA-2015.pem -O /tmp/cert.txt
cat /tmp/cert.txt >> /etc/boto_cacerts.txt

}

#----------------------------------------------------------------------------------------------

set_memory_limits(){

echo "*** SET MEMORY LIMITS FOR GROUP TEO ***"

echo "@teo hard as 10000000" > /etc/security/limits.d/80-virtmem.conf

}

#----------------------------------------------------------------------------------------------

configure_monit(){

echo "*** CONFIGURING MONIT ***"
# Configure Monit (assuming it is already installed)

# Change: make sure that the home and teodata volumes correspond to /dev/vdd and /dev/vde
# (the Sunstone GUI might help)
cat > /etc/monit.d/filesystem <<\_EoF_
check filesystem  home with path /dev/vdd
      if space usage > 95% then alert

check filesystem teodata with path /dev/vde
      if space usage > 95% then alert
_EoF_

# Change: configure the e-mail address to receive notifications
echo "set mailserver smtp.to.infn.it" >> /etc/monit.conf
echo "set mail-format { from: sfarm@to.infn.it }" >> /etc/monit.conf
echo "set alert svallero@to.infn.it" >> /etc/monit.conf

}

#----------------------------------------------------------------------------------------------

# Entry point
(
setup_nis_server
setup_nfs
add_users # questo va dopo aver montato la home
nologin
create_alice_login
configure_condor
fix_boto_version
infn_ca_certificate
service condor restart
# ATTENTION: this last part was not tested yet!
set_memory_limits
configure_monit
) | tee -a /var/log/context.log


