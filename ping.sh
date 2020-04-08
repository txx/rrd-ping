#!/bin/bash 

HOSTFILE="$(pwd)/hosts.csv"
HOSTS=$(tail -n+2 $HOSTFILE)

PCOUNT=10
PTIMEOUT=3
ASYNCPAUSE=0.5
RRDDBSTEP=10 # 10 seconds

BINPING="/bin/ping"
BINRRDTOOL="/usr/bin/rrdtool"
BINFILE="/usr/bin/file"

DATADIR="$(pwd)/data"
IMAGEDIR="$(pwd)/images"

DEBUG=true

main() {
	precheck_rrddb
	pingloop
}

pingloop() {
	for I in $HOSTS; do
		host=$(echo $I | cut -d ',' -f1)
		type=$(echo $I | cut -d ',' -f2)
		name=$(echo $I | cut -d ',' -f3)
		[ $DEBUG ] && echo -e "$name:\tPinging $host"
		pingparse $type $host | write2rrd $name && graph_ping $name &
#		sleep $ASYNCPAUSE	
	done
}

initialize() {
	for I in $HOSTS; do
		name=$(echo $I | cut -d ',' -f3)
		file="ping_$name.rrd"
		if [ ! -f $DATADIR/$file ] || ! $($BINFILE $DATADIR/$file | cut -d ':' -f2 | grep --silent "RRDTool DB version 0003"); then
			echo "$name: $file failed"
			echo "creating $file for $name"
			init_rrddb $file
		fi
	done
}

init_rrddb() {
	# step == graph resolution
	rrdcreate $DATADIR/$1 --step $RRDDBSTEP \
		DS:pl:GAUGE:600:0:100 \
		DS:rtt:GAUGE:600:0:10000000 \
		RRA:AVERAGE:0.5:1:800 \
		RRA:AVERAGE:0.5:6:800 \
		RRA:AVERAGE:0.5:24:800 \
		RRA:AVERAGE:0.5:288:800 \
		RRA:MAX:0.5:1:800 \
		RRA:MAX:0.5:6:800 \
		RRA:MAX:0.5:24:800 \
		RRA:MAX:0.5:288:800
}

pingparse() {
	local output=$($BINPING -q -n -c $PCOUNT -w $PTIMEOUT -$1 $2 2>&1)
	local temp=$(echo "$output"| awk '
		BEGIN           {pl=100; rtt=0.1}
		/packets transmitted/   {
			match($0, /([0-9]+)% packet loss/, matchstr)
			pl=matchstr[1]
		}
		/^rtt/          {
			# looking for something like 0.562/0.566/0.571/0.024
			match($4, /(.*)\/(.*)\/(.*)\/(.*)/, a)
			rtt=a[2]
		}
		/unknown host/  {
			# no output at all means network is probably down
			pl=100
			rtt=0.1
		}
		END         {print pl ":" rtt}
	')

	echo $temp
}

write2rrd() {
	INPUT=`cat`
	NAME=$1
	$BINRRDTOOL update \
		$DATADIR/ping_$NAME.rrd \
		--template \
		pl:rtt \
		N:$INPUT
	return $?
}

precheck_rrddb() {
	error=0
	for I in $HOSTS; do
		name=$(echo $I | cut -d ',' -f3)
		file="ping_$name.rrd"
		if ! [ -f $DATADIR/$file ]; then 
			echo "$name: $file is missing"
			let "error++"
		elif ! $($BINFILE $DATADIR/$file | cut -d ':' -f2 | grep --silent "RRDTool DB version 0003"); then
			echo "$name: $file failed rrd-file check"
			let "error++"
		fi
	done
	if [ $error -ne 0 ]; then
		exit 2
	fi
}

graph_ping() {
	name="$1"
	file="ping_$name.rrd"
	rrdtool graph $IMAGEDIR/$name.png \
		--imgformat PNG \
		--end now \
		--start end-1h \
		--width 1600 \
		--height 600 \
		-v "Round-Trip Time (ms)" \
		--rigid \
		--lower-limit 0 \
		DEF:roundtrip=$DATADIR/$file:rtt:AVERAGE \
		DEF:packetloss=$DATADIR/$file:pl:AVERAGE \
		CDEF:PLNone=packetloss,0,10,LIMIT,UN,UNKN,INF,IF \
		CDEF:PL25=packetloss,10,25,LIMIT,UN,UNKN,INF,IF \
		CDEF:PL50=packetloss,25,50,LIMIT,UN,UNKN,INF,IF \
		CDEF:PL75=packetloss,50,75,LIMIT,UN,UNKN,INF,IF \
		CDEF:PL100=packetloss,75,100,LIMIT,UN,UNKN,INF,IF \
		AREA:roundtrip#4444ff:"Round Trip Time (millis)" \
		GPRINT:roundtrip:LAST:"Cur\: %5.2lf" \
		GPRINT:roundtrip:AVERAGE:"Avg\: %5.2lf" \
		GPRINT:roundtrip:MAX:"Max\: %5.2lf" \
		GPRINT:roundtrip:MIN:"Min\: %5.2lf\n" \
		AREA:PLNone#6c9bcd:"0-10%":STACK \
		AREA:PL25#ffff00:"10-25%":STACK \
		AREA:PL50#ffcc66:"25-50%":STACK \
		AREA:PL75#ff9900:"50-75%":STACK \
		AREA:PL100#ff0000:"75-100%":STACK \
		COMMENT:"(Packet Loss Percentage)" \
		> /dev/null
	[ $DEBUG ] && echo -e "$name:\tGraph generated"
	return $?
}

[ ! -z "$1" ] && [ $1 == "init=yes" ] && initialize && exit
main
wait

