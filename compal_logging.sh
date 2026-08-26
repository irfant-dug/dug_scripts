#!/bin/bash
module load pdsh
while true
do
	pdsh -g "office=kl&&H200" 'ps -eo ppid,pid,cmd | grep "[t]ail -F /var/log/messages" | awk "{print \$1}" | sort | uniq | while read line; do sudo kill -9 $line; sleep 1s; done' 
	sleep 1s
	sudo ls -1 /run/sol-capture/ | grep in | while read line; do echo $line; sudo printf 'root\n' | sudo tee /run/sol-capture/$line > /dev/null ; sleep 2s; sudo printf 'lend-virus-crushed\n' | sudo tee /run/sol-capture/$line > /dev/null; sleep 2s; sudo printf 'tail -F /var/log/messages &\n' | sudo tee /run/sol-capture/$line > /dev/null; done
done
