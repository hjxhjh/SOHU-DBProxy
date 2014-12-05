#!/bin/bash

bash $SCRIPT_DIR/start_proxy.sh


t=$(
(
$MYSQL -h $MYSQL_PROXY_WORKER_IP -P $MYSQL_PROXY_RW_PORT -u nosuchuser -pguess -ABs -e "select 1"
) 2>&1
)
r="ERROR 3005 (28000): unknown user"
ret=0
if [ "$t" = "$r" ]; then
  ret=0
else
  echo "expected result: \"$r\""
  echo "actual result: \"$t\""
  ret=1
fi


bash $SCRIPT_DIR/stop_proxy.sh

exit $ret
#eof
