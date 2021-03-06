#!/bin/bash

# NOTE about this bash file: this file will be used to setup the distributed
# computing cluster on OpenStack. This includes copying the actual application
# frameworks from an external cinder volume to each master/slave and writing
# the configuration files to each of them. The parameters within dollar signs
# (e.g. /home/ubuntu) will be filled by the service orchestrator (so.py) with
# either given values from the user, default settings either from file
# defaultSettings.cfg / assumptions within the serice orchestrator or with
# pre-defined configuration files within the /data directory of the SO bundle.

{
SECONDS=0

state=0

function setState() {
    echo $state > /home/ubuntu/status.log
    let "state += 1"
}

# state 1
setState

# serve deployment.log
sh -c "while true; do nc -l -p 8084 < /home/ubuntu/status.log; done" > /dev/null 2>&1 &

# disable IPv6 as Hadoop won't run on a system with it activated
echo "disabling IPv6" >> /home/ubuntu/deployment.log
echo -e "\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p

# setup master's SSH configuration
su ubuntu -c 'echo -e "$master.id_rsa$" > /home/ubuntu/.ssh/id_rsa'
su ubuntu -c 'echo -e "$master.id_rsa.pub$" > /home/ubuntu/.ssh/id_rsa.pub'
$insert_master_pub_key$
su ubuntu -c 'echo -e "Host *\n   StrictHostKeyChecking no\n   UserKnownHostsFile=/dev/null" > /home/ubuntu/.ssh/config'
chmod 0600 /home/ubuntu/.ssh/*

# copying Hadoop & Java on the master and install them (including setting the
# environment variables)
cd /root

mkdir /home/ubuntu/archives

echo "setting up files for deployment on slaves..." >> /home/ubuntu/deployment.log

cat - >> /root/bashrc.suffix <<'EOF'
export JAVA_HOME=/usr/lib/java/jdk
export PATH=$PATH:$JAVA_HOME/bin
export HADOOP_HOME=/usr/lib/hadoop/hadoop
export PATH=$PATH:$HADOOP_HOME/bin
EOF

# configure Hadoop
# first of all, let's create the config files for the slaves
mkdir /home/ubuntu/hadoopconf
mv /root/bashrc.suffix /home/ubuntu/hadoopconf

# creating /etc/hosts file's replacement - don't forget: slaves need to have
# the same name as configured with Heat Template!!!
echo -e "127.0.0.1\tlocalhost\n`/sbin/ifconfig eth0 | grep 'inet addr' | cut -d: -f2 | awk '{print $1}'`  $masternode$" > /root/hosts.replacement
cat - >> /root/hosts.replacement <<'EOF'
$hostsfilecontent$
EOF
mv -f /root/hosts.replacement /home/ubuntu/hadoopconf


# create yarn-site.xml:
cat - > /home/ubuntu/hadoopconf/yarn-site.xml << 'EOF'
$yarn-site.xml$
EOF
sed -i 's/\$masteraddress\$/'`/sbin/ifconfig eth0 | grep 'inet addr' | cut -d: -f2 | awk '{print $1}'`'/g' /home/ubuntu/hadoopconf/yarn-site.xml

# create core-site.xml:
cat - > /home/ubuntu/hadoopconf/core-site.xml << 'EOF'
$core-site.xml$
EOF

# create mapred-site.xml:
cat - >> /home/ubuntu/hadoopconf/mapred-site.xml << 'EOF'
$mapred-site.xml$
EOF

# create hdfs-site.xml: (here, replication factor has to be entered!!!)
cat - >> /home/ubuntu/hadoopconf/hdfs-site.xml << 'EOF'
$hdfs-site.xml$
EOF

# create hadoop-env.sh:
cat - >> /home/ubuntu/hadoopconf/hadoop-env.sh << 'EOF'
$hadoop-env.sh$
EOF

# copy pssh/pscp to /usr/bin/pssh on master
# originally from Git repo https://github.com/jcmcken/parallel-ssh
# cp -r /mnt/pssh/pssh /usr/bin/
apt-get update
apt-get install -y pssh # git
cat - > /home/ubuntu/hosts.lst << 'EOF'
127.0.0.1
$for_loop_slaves$
EOF

mkdir /home/ubuntu/downloaded
cd /home/ubuntu/downloaded

# state 2
setState

wget http://mirror.switch.ch/mirror/apache/dist/hadoop/common/hadoop-2.7.1/hadoop-2.7.1.tar.gz

# state 3
setState

wget --no-cookies --no-check-certificate --header "Cookie: oraclelicense=accept-securebackup-cookie" "http://download.oracle.com/otn-pub/java/jdk/8u74-b02/jdk-8u74-linux-x64.tar.gz" -O jdk-8-linux-x64.tar.gz

function transferFirstUnpackLater {
    # state 4
    setState

	# copying hadoop & jdk to slaves in a compact form and unpacking them on
	# the slaves
	echo "copying hadoop and jdk to slaves" >> /home/ubuntu/deployment.log
	su ubuntu -c "parallel-scp -h /home/ubuntu/hosts.lst /home/ubuntu/downloaded/{hadoop-2.7.1.tar.gz,jdk-8-linux-x64.tar.gz} /home/ubuntu"
	echo "unpacking hadoop" >> /home/ubuntu/deployment.log

    # state 5
	setState
	su ubuntu -c "parallel-ssh -t 2000 -h /home/ubuntu/hosts.lst \"tar -xzf /home/ubuntu/hadoop-2.7.1.tar.gz\""
	echo "unpacking jdk" >> /home/ubuntu/deployment.log

    # state 6
	setState
	su ubuntu -c "parallel-ssh -t 2000 -h /home/ubuntu/hosts.lst \"tar -xzf /home/ubuntu/jdk-8-linux-x64.tar.gz\""
	echo "setting up both" >> /home/ubuntu/deployment.log
	# done with copying/unpacking hadoop/jdk
}

# here, the script has to decide which function to call:
# transferFirstUnpackLater or transferUnpackedFiles
echo "transferring hadoop & jdk to the masters/slaves and unpacking them" >> /home/ubuntu/deployment.log
transferFirstUnpackLater

# state 7
setState

echo "setting up hadoop & jdk" >> /home/ubuntu/deployment.log
# copy the SSH files to all slaves
su ubuntu -c "parallel-scp -h ~/hosts.lst ~/.ssh/{config,id_rsa,id_rsa.pub} ~/.ssh"
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mkdir /usr/lib/hadoop\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mv /home/ubuntu/hadoop-2.7.1 /usr/lib/hadoop\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo ln -s /usr/lib/hadoop/hadoop-2.7.1 /usr/lib/hadoop/hadoop\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mv /usr/lib/hadoop/hadoop-2.7.1/etc/hadoop/ /etc/\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mkdir -p /usr/lib/java\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mv /home/ubuntu/jdk1.8.0_74/ /usr/lib/java/\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo ln -s /usr/lib/java/jdk1.8.0_74/ /usr/lib/java/jdk\""
su ubuntu -c "parallel-scp -h /home/ubuntu/hosts.lst /home/ubuntu/hadoopconf/bashrc.suffix /home/ubuntu"
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo sh -c \\\"cat /home/ubuntu/bashrc.suffix >> /etc/bash.bashrc\\\"\""

# now, let's copy the files to the slaves
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mkdir -p /app/hadoop/tmp\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo chown ubuntu:ubuntu /app/hadoop/tmp\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo chmod 750 /app/hadoop/tmp\""
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo chown -R ubuntu:ubuntu /etc/hadoop\""

# the file has to be copied into the user directory as ubuntu doesn't have
# permissions to write into /etc/hadoop
echo "copying config files from master to slave..." >> /home/ubuntu/deployment.log
su ubuntu -c "parallel-scp -h /home/ubuntu/hosts.lst /home/ubuntu/hadoopconf/core-site.xml /home/ubuntu"
# move file to its final location (/etc/hadoop)
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mv -f /home/ubuntu/core-site.xml /etc/hadoop\""

su ubuntu -c "parallel-scp -h /home/ubuntu/hosts.lst /home/ubuntu/hadoopconf/{{mapred,hdfs,yarn}-site.xml,hadoop-env.sh} /etc/hadoop"

su ubuntu -c "parallel-scp -h /home/ubuntu/hosts.lst /home/ubuntu/hadoopconf/hosts.replacement /home/ubuntu"
su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"sudo mv -f /home/ubuntu/hosts.replacement /etc/hosts\""

su ubuntu -c "parallel-ssh -h /home/ubuntu/hosts.lst \"ln -s /etc/hadoop /usr/lib/hadoop/hadoop-2.7.1/etc/hadoop\""


# set master and slave nodes
echo $masternode$ > /etc/hadoop/masters
cat - > /etc/hadoop/slaves << 'EOF'
$masternodeasslave$$slavesfile$
EOF
source /etc/hadoop/hadoop-env.sh
su ubuntu -c "/usr/lib/hadoop/hadoop/bin/hdfs namenode -format"
su ubuntu -c "/usr/lib/hadoop/hadoop/sbin/start-dfs.sh"
su ubuntu -c "/usr/lib/hadoop/hadoop/sbin/start-yarn.sh"

#cd /home/ubuntu
#git clone https://github.com/Pentadactylus/yarn_jars.git
#echo "CLASSPATH=/home/ubuntu/yarn_jars/hadoop-client-1.2.1.jar:/home/ubuntu/yarn_jars/commons-cli-1.2.jar:/home/ubuntu/yarn_jars/hadoop-core-1.2.1.jar" >> /etc/bash.bashrc

echo "hadoop cluster ready" >> /home/ubuntu/deployment.log

# now, zeppelin should be installed
echo "now, installing zeppelin" >> /home/ubuntu/deployment.log
su ubuntu -c "mkdir /home/ubuntu/zeppelin"
cd /home/ubuntu/zeppelin
su ubuntu -c "wget http://mirror.switch.ch/mirror/apache/dist/zeppelin/zeppelin-0.6.1/zeppelin-0.6.1-bin-all.tgz"
su ubuntu -c "tar -xvzf /home/ubuntu/zeppelin/zeppelin-0.6.1-bin-all.tgz"
su ubuntu -c "mkdir -p /home/ubuntu/zeppelin/zeppelin-0.6.1-bin-all/{logs,run}"
# port has to be changed to 8070 as 8080 is Spark's standard Web UI port
su ubuntu -c "cat /home/ubuntu/zeppelin/zeppelin-0.6.1-bin-all/conf/zeppelin-site.xml.template | sed \"s/8080/8070/\" > /home/ubuntu/zeppelin/zeppelin-0.6.1-bin-all/conf/zeppelin-site.xml"
su ubuntu -c "source /etc/bash.bashrc && /home/ubuntu/zeppelin/zeppelin-0.6.1-bin-all/bin/zeppelin-daemon.sh start"
echo "zeppelin ready" >> /home/ubuntu/deployment.log
# zeppelin is installed and running


#echo "downloading test file for zeppelin" >> /home/ubuntu/deployment.log
#cd /home/ubuntu
#apt-get install -y unzip
#su ubuntu -c "wget http://archive.ics.uci.edu/ml/machine-learning-databases/00222/bank.zip"
#su ubuntu -c "unzip /home/ubuntu/bank.zip"
#su ubuntu -c "/usr/lib/hadoop/hadoop/bin/hdfs dfs -copyFromLocal /home/ubuntu/bank-full.csv /"

# now, let's get to jupyter
echo "installing jupyter" >> /home/ubuntu/deployment.log
apt-get install -y build-essential python3-dev python3-pip
pip3 install jupyter

# create mapred-site.xml:
su ubuntu -c "mkdir /home/ubuntu/.jupyter"
cat - >> /home/ubuntu/.jupyter/jupyter_notebook_config.py << 'EOF'
$jupyter_notebook_config.py$
EOF
chown ubuntu:ubuntu /home/ubuntu/.jupyter/jupyter_notebook_config.py
su ubuntu -c "jupyter-notebook &"
echo "jupyter ready" >> /home/ubuntu/deployment.log
# jupyter is installed and running


# install Apache Spark on master node
echo "downloading Apache Spark to master node" >> /home/ubuntu/deployment.log
su ubuntu -c "sudo mkdir /home/ubuntu/spark"
cd /home/ubuntu/spark
chown ubuntu:ubuntu /home/ubuntu/spark
su ubuntu -c "wget http://d3kbcqa49mib13.cloudfront.net/spark-2.0.0-bin-hadoop2.7.tgz"
#su ubuntu -c "tar -xzf /home/ubuntu/spark/spark-2.0.0-bin-hadoop2.7.tgz"
su ubuntu -c "parallel-ssh -t 2000 -h /home/ubuntu/hosts.lst \"sudo sh -c \\\"echo \\\\\\\"SPARK_HOME=\\\\\\\\\\\\\\\"/usr/lib/spark/spark\\\\\\\\\\\\\\\"\\\\nJAVA_HOME=\\\\\\\\\\\\\\\"/usr/lib/java/jdk\\\\\\\\\\\\\\\"\\\\\\\" >> \\\/etc\\\/environment\\\"\""
su ubuntu -c "parallel-ssh -t 2000 -h ~/hosts.lst \"sudo mkdir /usr/lib/spark\""
su ubuntu -c "parallel-ssh -t 2000 -h ~/hosts.lst \"sudo chown ubuntu:ubuntu /usr/lib/spark/\""
su ubuntu -c "parallel-scp -h ~/hosts.lst ~/spark/spark-2.0.0-bin-hadoop2.7.tgz /usr/lib/spark"
su ubuntu -c "parallel-ssh -t 2000 -h /home/ubuntu/hosts.lst \"tar -xzf /usr/lib/spark/spark-2.0.0-bin-hadoop2.7.tgz\""
#su ubuntu -c "parallel-ssh -t 2000 -h ~/hosts.lst \"mv spark-2.0.0-bin-hadoop2.7 /usr/lib/spark/\""
su ubuntu -c "parallel-ssh -t 2000 -h ~/hosts.lst \"mv spark-2.0.0-bin-hadoop2.7 /usr/lib/spark\""
su ubuntu -c "parallel-ssh -t 2000 -h ~/hosts.lst \"ln -s /usr/lib/spark/spark-2.0.0-bin-hadoop2.7/ /usr/lib/spark/spark\""
cat - > /usr/lib/spark/spark/conf/slaves << 'EOF'
$masternodeasslave$$slavesfile$
EOF
su ubuntu -c "/usr/lib/spark/spark/sbin/start-master.sh"
su ubuntu -c "/usr/lib/spark/spark/sbin/start-slaves.sh"
echo "Spark installed and started" >> /home/ubuntu/deployment.log
# at this point, Spark cluster is installed and running


duration=$SECONDS
# save it into deployment.log...
echo "deployment took me $duration seconds" >> /home/ubuntu/deployment.log
# ...and into debug.log
echo "deployment took me $duration seconds"

echo `date` >> /home/ubuntu/deployment.log

# state 8
setState

# in the following line, the whole regular output will be redirected to the
# file debug.log in the user's home directory and the error output to the file
# error.log within the same directory
} 2> /home/ubuntu/error.log | tee /home/ubuntu/debug.log
