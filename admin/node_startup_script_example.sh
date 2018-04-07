nis_domain="sfarm"

# Take head-node hostname from HTCondor configuration
nis_server=`cat /etc/condor/condor_config.local | grep CONDOR_HOST  | cut -d= -f2 | awk '{ print $1}'`

#----------------------------------------------------------------------------------------------------

mount_stuff(){

echo "Mount persistent volumes..."

mkdir /teodata
mount -t nfs -o proto=tcp,port=2049 $nis_server:/home /home
mount -t nfs -o proto=tcp,port=2049 $nis_server:/teodata /teodata
mkdir /alidata
mount -t nfs -o proto=tcp,port=2049 172.16.215.100:/disk/alice-data /alidata

}

#----------------------------------------------------------------------------------------------------

setup_nis_client(){

echo "Install some package..."
yum install -y yp-tools ypbind portmap

echo "Write configurations..."
echo "domain $nis_domain server $nis_server" >> /etc/yp.conf
echo "NISDOMAIN=\"$nis_domain\"" >> /etc/sysconfig/network

echo "Set NIS domain name..."
domainname $nis_domain
ypdomainname $nis_domain

echo "Editing /etc/nsswitch.conf..."
sed -i.back -n '/passwd/{s|$|   nis|};p' /etc/nsswitch.conf
sed -i.back -n '/shadow/{s|$|   nis|};p' /etc/nsswitch.conf
sed -i.back -n '/group/{s|$|   nis|};p' /etc/nsswitch.conf

echo "Make sure rpcbind is running..."
service rpcbind start
chkconfig rpcbind on

echo "Starting ypbind service..."
service ypbind start
chkconfig ypbind on

}

#----------------------------------------------------------------------------------------------------

# Entry point
(
service condor stop
groupmod -g 486 alice
setup_nis_client
mount_stuff
service condor start
) | tee -a /var/log/context.log

