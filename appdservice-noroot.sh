#!/bin/bash
#
# $Id: appdservice-noroot.sh 3.47 2019-03-22 16:05:00 saradhip $
#
# no root shell wrapper for appdynamics service changes
#
# this file is intended to be a limited replacement of the service
# escalation function, and as such needs to implement an adequate subset
# of the machinery in the init scripts
#
# Copyright 2016 AppDynamics, Inc
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#

export PATH=/bin:/usr/bin:/sbin:/usr/sbin

cd $(dirname $0)
APPD_ROOT=`readlink -e ..`
NAME=$(basename $(readlink -e $0))

#
# turn on debugging if indicated
#
if [ -f $APPD_ROOT/HA/INITDEBUG ] ; then
        rm -f /tmp/$NAME-$1.out
    exec 2> /tmp/$NAME-$1.out
    set -x
fi

# Usually this script is called by replicate.sh and so LOGFNAME is assigned.
# But as this script can be called standalone, we need to assign LOGFNAME if not already set.
[[ -n "$LOGFNAME" ]] || LOGFNAME=appdservice-noroot.log

. lib/log.sh
. lib/runuser.sh
. lib/password.sh
. lib/ha.sh
. lib/conf.sh
. lib/status.sh

function usage {
	echo usage: "$0 [appdcontroller appdcontroller-db appdynamics-machine-agent] [start stop status]"
	exit 1
}

if [ $# -ne 2 ] ; then
	usage
fi

service=$1
verb=$2

# look for the service config file in the usual places
# and load it.  sanity check it.
APPD_ROOT_TMP=$APPD_ROOT
conf=
for cf in /etc/sysconfig/$service /etc/default/$service ./$service.sysconfig ; do
	if [ -f $cf ] ; then
		conf=$cf
		break;
	fi
done
if [ "$conf" ] ; then
	. $conf
fi
if [ "$APPD_ROOT" != "$APPD_ROOT_TMP" ] ; then
	echo "APPD_ROOT setting inconsistent $APPD_ROOT $APPD_ROOT_TMP"
fi
if [ "$RUNUSER" != "$(id -un)" ] ; then
	echo "runuser inconsistent $RUNUSER $(id -un)"
fi

# use the java in the config file, else find the java
if [ -z "$JAVA" ] ; then
	JAVA=$(find_java)
fi
if [ "$JAVA" ] ; then
	export JAVA=$JAVA
else
	echo "java not found"
fi

if [ -f NO_MACHINE_AGENT -a "$service" == appdynamics-machine-agent ] ; then
	exit 0
fi

case "$service:$verb" in
appdcontroller:status|appdcontroller-db:status|appdynamics-machine-agent:status)
	./appdstatus.sh
	;;
	
appdcontroller:start)
	./appdservice-noroot.sh appdcontroller-db start
	if [ $(controller_mode) == 'active' ] ; then
	    rm -rf $APPD_ROOT/appserver/glassfish/domains/domain1/osgi-cache/
		rm -rf $APPD_ROOT/appserver/glassfish/domains/domain1/generated/
		nohup $APPD_ROOT/bin/controller.sh start-appserver >/dev/null 2>&1 &
		if [ -d "$APPD_ROOT/events_service" ] ; then
			nohup $APPD_ROOT/bin/controller.sh start-events-service >/dev/null 2>&1 &
		fi
		if [ -d "$APPD_ROOT/reporting_service" ] ; then
			nohup $APPD_ROOT/bin/controller.sh start-reporting-service >/dev/null 2>&1 &
		fi
		if replication_disabled ; then
			if assassin_running ; then
				echo assassin already running
			else
				echo -n assassin ' '
				nohup $APPD_ROOT/HA/assassin.sh >/dev/null
				pid=$!
				# wait for the process to die or sign on
				while [ -d /proc/$pid ] ; do
					if [ -f $ASSASSIN_PIDFILE ] ; then
						break
					fi
					sleep 1
					echo -n "."
				done
				echo started
			fi
		fi
	else
		if [ -f $WATCHDOG_ENABLE ] ; then
			if ! watchdog_running ; then
				nohup "$APPD_ROOT/HA/watchdog.sh" >/dev/null 2>&1 &
				pid=$!
				# wait for the process to die or sign on
				while [ -d /proc/$pid ] ; do
					if [ -f $WATCHDOG_PIDFILE ] ; then
						break
					fi
					sleep 1
				done
			fi
		fi	
	fi
	;;

appdcontroller:stop)
	export AD_SHUTDOWN_TIMEOUT_IN_MIN=10
	$APPD_ROOT/bin/controller.sh stop-appserver
	controllerrunning
	if [ $? -lt 3 ] ; then
		echo "forcibly killing appserver"
		pkill -9 -f "$APPD_ROOT/appserver/glassfish/domains/domain1"
		echo "truncate ejb__timer__tbl;" | run_mysql
	fi

	if [ -d "$APPD_ROOT/events_service" ] ; then
		$APPD_ROOT/bin/controller.sh stop-events-service
	fi
	if [ -d "$APPD_ROOT/reporting_service" ] ; then
		$APPD_ROOT/bin/controller.sh stop-reporting-service
	fi
	if watchdog_running ; then
		kill -9 $watchdog_pid && ( echo appd watchdog killed; \
		echo `date` appd watchdog killed >> $APPD_ROOT/logs/watchdog.log )
	fi
	rm -f $WATCHDOG_PIDFILE
	if assassin_running ; then
		kill -9 $assassin_pid && ( echo appd assassin killed; \
			echo `date` appd assassin killed >> $APPD_ROOT/logs/assassin.log )
	fi
	runuser rm -f $ASSASSIN_PIDFILE
	;;

appdcontroller-db:start)
	$APPD_ROOT/bin/controller.sh start-db
	false
	;;

appdcontroller-db:stop)
	./appdservice-noroot.sh appdcontroller stop
	$APPD_ROOT/bin/controller.sh stop-db
	;;

appdynamics-machine-agent:start)
	if [ "$MACHINE_AGENT_HOME" ] ; then
		ma_dir=$MACHINE_AGENT_HOME
	else
		ma_dir=`find_machine_agent`
	fi
	if [ ! -f "$ma_dir/machineagent.jar" ] ; then
		echo "cannot find machine agent"
		exit 0
	fi
	nohup $JAVA $JAVA_OPTS -jar $ma_dir/machineagent.jar >/dev/null 2>&1 &
	;;

appdynamics-machine-agent:stop)
	for pid in `pgrep -f machineagent.jar` ; do
		for sub in `pgrep -P $pid` ; do
			kill -9 $sub
		done
		kill -9 $pid
	done
	;;

*)
	usage
	;;
esac

exit 0
