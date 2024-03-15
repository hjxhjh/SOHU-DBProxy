#!/bin/bash
: <<'EOF'
DBProxy�߿��õ�Keepalived�ű�

���룺
  ��usage

�����
  ��

����ֵ��
  0 �ɹ�

��־��
  /var/log/keepalived/dbproxy_notify-������.log

������
  rsync,mysql

��ʷ��
  1.0.8 2014-05-08 wenx ������ݿⶼdown�˲�����fault״̬
  1.0.7 2013-11-19 wenx ���û��״̬�л��ļ����ű������˳����޸����������
  1.0.6 2013-11-19 wenx ����--version|-V��ʾ�汾��
  1.0.5 2013-11-06 wenx ����״̬�л��ļ����������ű���
  1.0.4 2013-10-25 wenx
  1.0.3 2013-10-24 wenx
  1.0.2 2013-08-26 wenx ������־����ʼ�������ļ���
  1.0.1 2013-08-05 wenx ����
  1.0.0 2013-08-04 wenx ��ʼ

EOF


## Convenience Variables

PROGNAME="dbproxy_notify.sh"
VERSION=1.0.8
LOGDIR=/var/log/keepalived
CURRENT_DATE=$(date '+%Y%m%d')
LOG=$LOGDIR/dbproxy_notify-${CURRENT_DATE}.log
declare -i log_seq=0
declare -i log_level=2
declare -ir LOG_LEVEL_DEBUG=3
declare -ir LOG_LEVEL_MESSAGE=2
declare -ir LOG_LEVEL_ERROR=1

declare -ri MIN_DISK_FREE_SPACE_KB=$((20*1024))
declare -ri MAX_RETETION_DAYS_FOR_LOG=30

declare -r LOG_DBPROXY_STATUS=$LOGDIR/dbproxy_status

##
# "UserKnownHostsFile=/dev/null" is not needed
# @notice ConnectTimeout should far less than checking script's interval
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=3"
KEEPALIVED_CONF=/etc/keepalived/keepalived.conf



## Convenience Functions

##### ��־ #####
##
# ��ʼ����־
# �����������̿ռ䣬ɾ����ʷ��־
# @return 1 ʧ��
logger_init() {
  declare -i avaiKB=0
  declare f
  [ ! -d "$LOGDIR" ] && mkdir -p "$LOGDIR"
  avaiKB=$(df -kP "$LOGDIR" | tail -n 1 | awk '{print $4}')
  if (( avaiKB <= MIN_DISK_FREE_SPACE_KB )); then
    logger_error "available disk space is insufficient. $avaiKB"
    return 1
  fi
  find $LOGDIR -maxdepth 1 -type f -name "dbproxy_notify-????????.log" -mtime +$MAX_RETETION_DAYS_FOR_LOG -print | \
  while read f; do
    logger_message "delete $f"
  done
  [ ! -f $LOG_DBPROXY_STATUS ] && touch $LOG_DBPROXY_STATUS
  chmod 664 $LOG_DBPROXY_STATUS
  true
}

##
# echo with timestamp, functionality names...
# @param $@ text strings to echo
logger() {
  declare _level=$1
  shift
  ((log_seq++))
  echo "$(date '+%Y-%m-%d %H:%M:%S.%N') [${BASH_SOURCE[1]}:${BASH_LINENO[0]}] [$$] [$log_seq] $_level $opt_state: $@"
}

logger_debug() {
  if ((log_level>=LOG_LEVEL_DEBUG)); then
    logger "DEBUG" "$@"
  fi
}
logger_message() {
  if ((log_level>=LOG_LEVEL_MESSAGE)); then
    logger "MESSAGE" "$@"
  fi
}
logger_error() {
  if ((log_level>=LOG_LEVEL_ERROR)); then
    logger "ERROR" "$@"
  fi
}

log_status() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S.%N') $opt_state" >>$LOG_DBPROXY_STATUS
}
log_status_goto_master() { log_status "master"; }
log_status_goto_backup() { log_status "backup"; }
log_status_goto_fault() { log_status "fault"; }

usage()
{
  cat <<EOF
Usage: $PROGNAME --state=STATE OPTIONS ...
  --state={master|backup|fault|check|status|add|del}

master|backup|fault:
  --state=master
  --vi=VRRP_INSTANCE | --vip=VIRTUAL_IP_ADDRESS
  --mphome=MYSQL-PROXY_HOME Optional. /DATA/app/mysql-proxy-0.7.0-bin by default
  --if=INTERFACE_DEV Optional.

check:
  --state=check
  --vi=VRRP_INSTANCE | --vip=VIRTUAL_IP_ADDRESS
  --mphome=MYSQL-PROXY_HOME Optional. /DATA/app/mysql-proxy-0.7.0-bin by default
  --failed_action={to_fault|to_restart} optional. default is to_fault
  --if=INTERFACE_DEV Optional.
  --gw=GATEWAY_ADDRESS Optional.

status:
  --state=status
  --vi=VRRP_INSTANCE | --vip=VIRTUAL_IP_ADDRESS

add:
  --state=add
  --vip=VIRTUAL_IP_ADDRESS
  --if=INTERFACE_DEV Optional.

del:
  --state=del
  --vi=VRRP_INSTANCE | --vip=VIRTUAL_IP_ADDRESS

EOF
}



##### ȱʡֵ #####
##
# ����vip����viȱʡֵ
opt_set_default_get_vi_by_vip()
{
  declare -r _vip=$1
  declare _vi
  declare _vip_last
  _vip_last=$(echo "$_vip" | awk -F. '{print $4}')
  _vi="vi_dbproxy_${_vip_last}"
  echo "$_vi"
}

##
# ����viȡ��vipȱʡֵ
opt_set_default_get_vip_by_vi()
{
  declare -r _vi=$1
  declare _vip
  _vip=$(
  sed '/^[[:space:]]*#/d' $KEEPALIVED_CONF | \
  awk '
{
  if ($0 ~ /^[[:space:]]*vrrp_instance[[:space:]]+'"$_vi"'[[:space:]]*{[[:space:]]*$/) {
    I=1;
    while (I>0) {
      getline
      if ($0 ~ /}/) I--
      if ($0 ~ /{/) I++
      if ($0 ~ /^[[:space:]]*virtual_ipaddress[[:space:]]*{[[:space:]]*$/) {
        J=1;
        while (J>0) {
          getline
          if ($0 ~ /}/) {I--;J--}
          if ($0 ~ /{/) {I++;J++}
          if (J==1) {
            print $1
          }
        }
      }
    }
  }
}
' | head -n1)
  echo "$_vip"
}

##
# ����mphomeȱʡֵ
opt_set_default_get_mphome()
{
  echo "/DATA/app/mysql-proxy-0.7.0-bin"
}

##
# ����failed_actionȱʡֵ
opt_set_default_get_failed_action()
{
  echo "to_fault"
}

##
# ����ifȱʡֵ
opt_set_default_get_if()
{
  declare _if
  _if=$(ip -4 -o link show | awk '$9=="UP"{print $2}' | head -n1)
  _if=${_if%:}
  echo "$_if"
}
opt_set_default_get_if_by_vi()
{
  declare -r _vi=$1
  declare _if
  _if=$(
  sed '/^[[:space:]]*#/d' $KEEPALIVED_CONF | \
  awk '
{
  if ($0 ~ /^[[:space:]]*vrrp_instance[[:space:]]+'"$_vi"'[[:space:]]*{[[:space:]]*$/) {
    I=1;
    while (I>0) {
      getline
      if ($0 ~ /}/) I--
      if ($0 ~ /{/) I++
      if ($0 ~ /^[[:space:]]*interface[[:space:]]+/) {
        print $2
      }
    }
  }
}
')
  echo "$_if"
}

##
# ����gwȱʡֵ
opt_set_default_get_gw_by_if()
{
  declare -r _if="$1"
  declare _gw
  if [ -n "$_if" ]; then
    _gw=$(ip -4 route list dev "$_if" | awk '/^default / {print $3}')
  else
    _gw=$(ip -4 route list default | awk '/^default / {print $3}')
  fi
  echo "$_gw"
}

opt_set_default_get_vrrpid_by_vip()
{
  declare _vip=$1
  echo "$_vip" | awk -F. '{if ($3=="96") print "255"; else print $4}'
}
opt_set_default_get_vrrpid_by_vi()
{
  declare _vi=$1
  echo "$_vi" | awk -F'_' '{print $3}'
}


##
# ����ѡ���ȱʡֵ
opt_set_default()
{
  if [ -z "$opt_vi" -a -n "$opt_vip" ]; then
    opt_vi=$(opt_set_default_get_vi_by_vip "$opt_vip")
  fi

  if [ -n "$opt_vi" -a -z "$opt_vip" ]; then
    opt_vip=$(opt_set_default_get_vip_by_vi "$opt_vi")
  fi

  if [ -z "$opt_mphome" ]; then
    opt_mphome=$(opt_set_default_get_mphome)
  fi

  if [ -z "$opt_failed_action" ]; then
    opt_failed_action=$(opt_set_default_get_failed_action)
  fi

  if [ -z "$opt_if" ]; then
    opt_if=$(opt_set_default_get_if_by_vi "$opt_vi")
  fi

  if [ -z "$opt_gw" ]; then
    opt_gw=$(opt_set_default_get_gw_by_if "$opt_if")
  fi

  if [ -n "$opt_vi" ]; then
    opt_vrrpid=$(opt_set_default_get_vrrpid_by_vi "$opt_vi")
  elif [ -n "$opt_vip" ]; then
    opt_vrrpid=$(opt_set_default_get_vrrpid_by_vip "$opt_vip")
  fi
}

##
# ����addѡ���ȱʡֵ
opt_set_default_for_add()
{
  if [ -z "$opt_vi" -a -n "$opt_vip" ]; then
    opt_vi=$(opt_set_default_get_vi_by_vip "$opt_vip")
  fi

  if [ -z "$opt_if" ]; then
    opt_if=$(opt_set_default_get_if)
  fi

  if [ -n "$opt_vi" ]; then
    opt_vrrpid=$(opt_set_default_get_vrrpid_by_vi "$opt_vi")
  elif [ -n "$opt_vip" ]; then
    opt_vrrpid=$(opt_set_default_get_vrrpid_by_vip "$opt_vip")
  fi
}

##
# ����delѡ���ȱʡֵ
opt_set_default_for_del()
{
  if [ -z "$opt_vi" -a -n "$opt_vip" ]; then
    opt_vi=$(opt_set_default_get_vi_by_vip "$opt_vip")
  fi

  if [ -n "$opt_vi" ]; then
    opt_vrrpid=$(opt_set_default_get_vrrpid_by_vi "$opt_vi")
  elif [ -n "$opt_vip" ]; then
    opt_vrrpid=$(opt_set_default_get_vrrpid_by_vip "$opt_vip")
  fi
}



##### ��� #####
opt_sanity_check_validation_vi()
{
  declare _vi=$1
  if [[ ! ( $_vi =~ ^vi_dbproxy_[[:digit:]]+$ ) ]]; then
    return 1
  fi
}

opt_sanity_check_validation_state()
{
  declare _state=$1
  if [   "$_state" != "master" \
      -a "$_state" != "backup" \
      -a "$_state" != "fault" \
      -a "$_state" != "check" \
      -a "$_state" != "status" \
      -a "$_state" != "add" \
      -a "$_state" != "del" \
     ]; then
    return 1
  fi
}

opt_sanity_check_validation_failed_action()
{
  declare _fa=$1
  if [ "$_fa" != "to_fault" -a "$_fa" != "to_restart" ]; then
    return 1
  fi
}

##
# ���vip��vi�Ƿ�ƥ��
# ���������vip��vi���һλ�ֶ��Ƿ�һ��
# @return 0 ƥ��
# @return !0 ��ƥ��
opt_sanity_check_vip_vi_matchable()
{
  declare -r _vip=$1
  declare -r _vi=$2
  declare _vip_last
  declare _vi_last
  _vip_last=$(echo "$_vip" | awk -F. '{print $4}')
  _vi_last=$(echo "$_vi" | awk -F_ '{print $3}')
  if [ "$_vip_last" != "$_vi_last" ]; then
    return 1
  fi
}

opt_sanity_check_existence_vi()
{
  declare _vi=$1
  if ! grep -q '^[[:space:]]*vrrp_instance[[:space:]]\+'"${_vi}"'[[:space:]]*{[[:space:]]*$' $KEEPALIVED_CONF; then
    return 1
  fi
}

opt_sanity_check_existence_vip_by_vi()
{
  declare _vip=$1
  declare _vi=$2
  if ! opt_set_default_get_vip_by_vi "$_vi" | grep -q "$_vip"; then
    return 1
  fi
}

opt_sanity_check_existence_mphome()
{
  declare _mphome=$1
  if [ ! -d "$_mphome" ]; then
    return 1
  fi
}

opt_sanity_check_existence_if()
{
  declare _if=$1
  if ! ip -4 -o link show | awk '{print $2}' | grep -q "${_if}:"; then
    return 1
  fi
}

opt_sanity_check_existence_gw()
{
  declare _gw=$1
  return 0
}

##
# ��������������ѡ���Ƿ���ȷ
opt_sanity_check()
{
  declare -i invalid_opt=0
  declare -i error_opt=0

  #�������Ƿ�Ϸ�
  if [ -z "$opt_vi" -a -z "$opt_vip" ]; then
    logger_error "--vi or --vip not specified"
    invalid_opt=1
  fi
  if [ -z "$opt_state" ]; then
    logger_error "--state not specified"
    invalid_opt=1
  fi

  if ! opt_sanity_check_validation_vi "$opt_vi"; then
    logger_error "--vi is invalid: $opt_vi"
    invalid_opt=1
  fi

  if ! opt_sanity_check_validation_state "$opt_state"; then
    logger_error "--state is invalid: $opt_state"
    invalid_opt=1
  fi
  if [ -z "$opt_if" ]; then
    logger_error "--if is invalid: $opt_if"
    invalid_opt=1
  fi

  if ! opt_sanity_check_validation_failed_action "$opt_failed_action"; then
    logger_error "--failed_action is invalid: $opt_failed_action"
    invalid_opt=1
  fi

  if [ $invalid_opt -ne 0 ]; then
    return $invalid_opt
  fi

  #������ֵ�Ƿ����
  if ! opt_sanity_check_vip_vi_matchable "$opt_vip" "$opt_vi"; then
    logger_error "vip and vi is not matchable: $opt_vip $opt_vi"
    error_opt=1
  fi

  if ! opt_sanity_check_existence_vi "$opt_vi"; then
    logger_error "vi not exist: $opt_vi"
    error_opt=1
  fi
  if ! opt_sanity_check_existence_vip_by_vi "$opt_vip" "$opt_vi"; then
    logger_error "vip not exist: $opt_vip"
    error_opt=1
  fi

  if ! opt_sanity_check_existence_mphome "$opt_mphome"; then
    logger_error "mphome not exist: $opt_mphome"
    error_opt=1
  fi

  if ! opt_sanity_check_existence_gw "$opt_gw"; then
    logger_error "gw not exist: $opt_gw"
    error_opt=1
  fi

  if [ $error_opt -ne 0 ]; then
    return $error_opt
  fi

  return 0
}

opt_sanity_check_for_add()
{
  declare -i invalid_opt=0
  declare -i error_opt=0

  #�������Ƿ�Ϸ�
  if [ -z "$opt_vip" ]; then
    logger_error "--vip not specified"
    invalid_opt=1
  fi
  if [ -z "$opt_state" ]; then
    logger_error "--state not specified"
    invalid_opt=1
  fi

  if ! opt_sanity_check_validation_state "$opt_state"; then
    logger_error "--state is invalid: $opt_state"
    invalid_opt=1
  fi
  if [ -z "$opt_if" ]; then
    logger_error "--if is invalid: $opt_if"
    invalid_opt=1
  fi

  if [ $invalid_opt -ne 0 ]; then
    return $invalid_opt
  fi

  #������ֵ�Ƿ����
  if opt_sanity_check_existence_vi "$opt_vi"; then
    logger_error "vi already exist: $opt_vi"
    error_opt=1
  fi
  if opt_sanity_check_existence_vip_by_vi "$opt_vip" "$opt_vi"; then
    logger_error "vip already exist: $opt_vip"
    error_opt=1
  fi

  if [ $error_opt -ne 0 ]; then
    return $error_opt
  fi

  return 0
}

opt_sanity_check_for_del()
{
  declare -i invalid_opt=0
  declare -i error_opt=0

  #�������Ƿ�Ϸ�
  if [ -z "$opt_vi" -a -z "$opt_vip" ]; then
    logger_error "--vi or --vip not specified"
    invalid_opt=1
  fi
  if [ -z "$opt_state" ]; then
    logger_error "--state not specified"
    invalid_opt=1
  fi

  if ! opt_sanity_check_validation_state "$opt_state"; then
    logger_error "--state is invalid: $opt_state"
    invalid_opt=1
  fi

  if [ $invalid_opt -ne 0 ]; then
    return $invalid_opt
  fi

  #������ֵ�Ƿ����
  if ! opt_sanity_check_existence_vi "$opt_vi"; then
    logger_error "vi not exist: $opt_vi"
    error_opt=1
  fi

  if [ $error_opt -ne 0 ]; then
    return $error_opt
  fi

  return 0
}



##### �͸߿�����صĲ��� #####
##
# �����̺��Ƿ����
# @param $1 ���̺�
# @return 0 ����
# @return !0 ������
isRunning() {
  #ps -ef | awk '$2=="'"$1"'"'
  kill -s 0 "$1" 2>/dev/null
}

##
# ���IP��ַ�Ƿ����
# @param $1 IP��ַ
# @return 0 ���� 
# @return !0 ������
hasIPAddress() {
  ip -o a s | grep -w "$1" >/dev/null 2>&1
}

##
# �����IP�Ƿ���Ч
# ������ͨ����IP��ַping����
# @param $1 ���ص�ַ
# @param $2 ��IP��ַ
# @return 0 �ɹ�
# @return !0 ʧ��
ping_gw_by_vip()
{
  declare -r _gw=$1
  declare -r _vip=$2
  declare -i _rc
  declare _ping_out
  _ping_out=$( ping -I $_vip -n -q -W 2 -c 2 $_gw 2>&1 )
  _rc=$?
  if ((_rc!=0)); then
    logger_message "ping: $_rc \"$_ping_out\""
  fi
  return $_rc
}

##
# ɾ����IP
delete_vip()
{
  declare -r _vip=$1
  declare -r _dev=$2
  ip addr del $_vip dev $_dev
}

##
# ͬ�������ļ�
# ������ͨ��������IP��ַ������MASTER�ڵ��ϣ����������ļ�
sync_conf()
{
  #declare -r -a _proxy_conf_files=( "$opt_mphome/etc/mysql-proxy.cnf" "$opt_mphome/etc/zabbix_agentd.cnf" )
  #declare _f=""
  declare _tmp
  logger_debug "check ssh $opt_vip"
  _tmp=$($SSH $opt_vip ":" 2>&1)
  if [ $? -eq 0 ]; then
    logger_debug "rsync -e \"$SSH\" $opt_vip:\"$opt_mphome/etc/*\" \"$opt_mphome/etc/\""
    rsync -e "$SSH" $opt_vip:"$opt_mphome/etc/*" "$opt_mphome/etc/"
  else
    logger_error "ssh connectivity issue: $_tmp"
    return $?
  fi
}

##
# ���proxy״̬
# ��������¼proxy����˿ڣ�ֻҪ��һ�����״̬��UP������Ϊproxy״̬����
proxy_check_status() {
  declare -r _show_up=$1
  declare -r _cnf_file=$opt_mphome/etc/mysql-proxy.cnf
  declare _admin_address
  declare _admin_ip
  declare _admin_port
  declare _admin_user
  declare _admin_pwd
  declare _showbackens
  declare -i _up_count
  if [ ! -r "$_cnf_file" ]; then
    logger_error "cnf not found: $_cnf_file"
    false
  fi
  _admin_address=$(sed -n '/^admin-address=/s/^admin-address=//p' $_cnf_file)
  _admin_ip=${_admin_address%:*}
  _admin_port=${_admin_address#*:}
  _admin_user=$(sed -n '/^admin-username=/s/^admin-username=//p' $_cnf_file)
  _admin_pwd=$(sed -n '/^admin-password=/s/^admin-password=//p' $_cnf_file)
  if [ -n "$_admin_ip" -a -n "$_admin_port" -a -n "$_admin_user" -a -n "$_admin_pwd" ]; then
    _showbackens=$(mysql -h "$_admin_ip" -P "$_admin_port" -u "$_admin_user" -p"$_admin_pwd" -ABs -e showbackends)
    if [ $? -eq 0 ]; then
      _up_count=$( echo "$_showbackens" | awk 'tolower($3)=="up"' | wc -l )
      if [ $_up_count -gt 0 ]; then
        if [ "$_show_up" = "SHOW_UP" ]; then
          logger_message "showbackends up: $_showbackens"
        fi
        true
      else
        logger_error "showbackends down: $_showbackens"
        #false
        true
      fi
    else
      logger_error "showbackends error: $_showbackens"
      false
    fi
  else
    logger_error "read cnf error: $_cnf_file"
    false
  fi
}

##
# ����proxy����
# ����������proxyά���ű�����proxy����
proxy_start() {
  $opt_mphome/bin/mysql-proxyd start
}

##
# ֹͣproxy����
# ����������proxyά���ű�ֹͣproxy����
proxy_stop() {
  $opt_mphome/bin/mysql-proxyd stop
}

##
# ǿ��ֹͣproxy����
# ����������proxyά���ű�ǿ��ֹͣproxy����
proxy_force_stop() {
  $opt_mphome/bin/mysql-proxyd forcestop >/dev/null
}

##
# �鿴proxy����״̬
# ���������pid�ļ��б���Ľ��̺��Ƿ����
proxy_pid_status() {
  declare _pid=""
  declare -i _rc
  declare -r _pidfile=$opt_mphome/var/log/mysql-proxy.pid
  declare -r _mpbin=$opt_mphome/bin/mysql-proxy
  if [ -f "$_pidfile" ]; then
    _pid=$(head -n 1 $_pidfile)
    if [ ! -z "$_pid" ]; then
      isRunning "$_pid"
      _rc=$?
      if ((_rc==0)); then
        logger_debug "proxy status ok: $_pid"
      else
        logger_debug "pid not found: $_pid"
      fi
      return $_rc
    else
      logger_debug "pid not found: $_pidfile"
    fi
  fi
  logger_debug "pidfile not found: $_pidfile"
  false
}

## 
# ֹͣproxy
# ������
#   ���proxy����������ֹ֮ͣ
#   ���proxyδ������Ϊ���������Ҳ�����proxy_force_stop�ű���ǿ��ɱ֮
kill_proxy()
{
  if proxy_pid_status; then
    proxy_stop
  else
    logger_debug "although proxy seems to be stopped, we must make it for sure"
  fi
  proxy_force_stop
}

##
# �����˳�
raise_error()
{
  #to_status
  exit 1
}


##
# ����ΪMASTER
# ���������proxyδ������������proxy����
# @return proxy_start �ķ���ֵ
to_master() {
  logger_debug "${FUNCNAME[0]}()"
  log_status_goto_master
  logger_message "starting proxy"
  if proxy_pid_status; then
    logger_debug "proxy already started"
    true
  else
    logger_debug "proxy will be started"
    proxy_start
    if ! proxy_pid_status; then
      logger_debug "try starting proxy again"
      proxy_force_stop
      proxy_start
    fi
  fi
}

##
# ����ΪBACKUP
# ������
#   ��
to_backup() {
  logger_debug "${FUNCNAME[0]}()"
  log_status_goto_backup
  logger_message "do nothing"
}

##
# ����ʧЧģʽ
# ������
#   ֹͣproxy����
#   ɾ����IP��ַ
to_fault() {
  logger_debug "${FUNCNAME[0]}()"
  log_status_goto_fault
  logger_message "kill proxy process"
  kill_proxy
  if hasIPAddress $opt_vip; then
    logger_message "deleting vip: $opt_vip"
    delete_vip $opt_vip $opt_if
  fi
}

##
# ���״̬
# ������
#   * ������IP��ַ
#   ** ��IP��ַ��Ч
#   *** proxy���̲�����
#   **** ���ش���ֵ(����FAULTʧЧģʽ)
#   **** �� (ǿ��ͣproxyȻ��)����proxy
#   *** proxy���̴���
#   **** ��
#   ** ��IP��ַ��Ч
#   *** ͣproxy(�����)
#   *** ���ش���ֵ(����FAULTʧЧģʽ)
#   * û����IP��ַ
#   ** ͣproxy(�����)
#   ** ͬ�������ļ�
# @return 0
to_check() {
  logger_debug "${FUNCNAME[0]}()"
  if hasIPAddress $opt_vip; then
    if ping_gw_by_vip $opt_gw $opt_vip; then
      logger_message "ping vip ok, it is a real master"
      if proxy_check_status; then
        logger_debug "check proxy status ok"
      else
        logger_message "check proxy status failed"
        raise_error
      fi
    else
      logger_message "ping vip failed, it is a false master"
      logger_message "kill proxy and goto fault"
      kill_proxy
      raise_error
    fi
  else
    logger_message "has no vip $opt_vip, it is a backup"
    logger_debug "kill proxy and sync conf"
    kill_proxy
    sync_conf
    true
  fi
}

##
# �����IP�Ƿ����
# for debug purpose only
to_status() {
  logger_debug "${FUNCNAME[0]}()"
  if hasIPAddress $opt_vip; then
    logger_message "has vip $opt_vip"
  else
    logger_message "has no vip $opt_vip"
  fi
  proxy_pid_status
  proxy_check_status "SHOW_UP"
}

##
# ��������
to_add() {
  logger_debug "${FUNCNAME[0]}()"
  cat >>$KEEPALIVED_CONF <<EOF
vrrp_script vs_dbproxy_${opt_vrrpid} {
    script "/etc/keepalived/dbproxy_notify.sh --state=check --vip=${opt_vip}"
    interval 5
    rise 2
    fall 3
}
vrrp_instance ${opt_vi} {
    state BACKUP
    nopreempt
    interface ${opt_if}
    virtual_router_id ${opt_vrrpid}
    priority 100
    advert_int 3
    authentication {
        auth_type PASS
        auth_pass 1234${opt_vrrpid}
    }
    track_script {
       vs_dbproxy_${opt_vrrpid}
    }
    notify_master "/etc/keepalived/dbproxy_notify.sh --state=master --vip=${opt_vip}"
    notify_backup "/etc/keepalived/dbproxy_notify.sh --state=backup --vip=${opt_vip}"
    notify_fault "/etc/keepalived/dbproxy_notify.sh --state=fault --vip=${opt_vip}"
    virtual_ipaddress {
        ${opt_vip}
    }
}
EOF
}

##
# ɾ������
to_del() {
  logger_debug "${FUNCNAME[0]}()"
  declare -r _vi=$opt_vi
  declare -r _vrrpid=$opt_vrrpid
  declare _tmp
  declare -i _vs_begin
  declare -i _vs_end
  declare -i _vi_begin
  declare -i _vi_end

  logger_debug "${FUNCNAME[0]}()"

  _tmp=$(
  awk '
{
  if ($0 ~ /^[[:space:]]*vrrp_script[[:space:]]+vs_dbproxy_'"$_vrrpid"'[[:space:]]*{[[:space:]]*$/) {
    print NR
    I=1;
    while (I>0) {
      getline
      if ($0 ~ /}/) I--
      if ($0 ~ /{/) I++
    }
    print NR
  }
}
' $KEEPALIVED_CONF
)
  _vs_begin=$(echo "$_tmp" | sed -n 1p)
  _vs_end=$(echo "$_tmp" | sed -n 2p)
  _tmp=$(
  awk '
{
  if ($0 ~ /^[[:space:]]*vrrp_instance[[:space:]]+'"$_vi"'[[:space:]]*{[[:space:]]*$/) {
    print NR
    I=1;
    while (I>0) {
      getline
      if ($0 ~ /}/) I--
      if ($0 ~ /{/) I++
    }
    print NR
  }
}
' $KEEPALIVED_CONF
)
  _vi_begin=$(echo "$_tmp" | sed -n 1p)
  _vi_end=$(echo "$_tmp" | sed -n 2p)

  logger_debug "${_vs_begin},${_vs_end}d; ${_vi_begin},${_vi_end}d"
  sed -i "${_vs_begin},${_vs_end}d; ${_vi_begin},${_vi_end}d" $KEEPALIVED_CONF
}



## Main entrance
saved_opts="$@"
SHORT_OPTS="hV"
LONG_OPTS="help version vi: state: mphome: vip: gw: if: failed_action:"
[ $# -gt 0 ] && ARGS=$(getopt -n$PROGNAME -o "$SHORT_OPTS" -l "$LONG_OPTS" -- "$@") || { usage; exit 1; }
eval set -- "$ARGS"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    -V|--version) echo "$PROGNAME $VERSION"; exit 0 ;;
    --state) opt_state=$2; shift ;;
    --vip) opt_vip=$2; shift ;;
    --vi) opt_vi=$2; shift ;;
    --mphome) opt_mphome=$2; shift ;;
    --failed_action) opt_failed_action=$2; shift ;;
    --gw) opt_gw=$2; shift ;;
    --if) opt_if=$2; shift ;;
    --) shift
      break ;;
    #bad options
    -*) usage; exit 1 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

logger_init || { exit 1; }
exec 3>&1 4>&2 >>$LOG 2>&1
logger_debug "begin"
logger_debug "$0 $saved_opts"

if [ x"$opt_state" = x"master" \
     -o x"$opt_state" = x"backup" \
     -o x"$opt_state" = x"fault" \
     -o x"$opt_state" = x"check" \
     -o x"$opt_state" = x"status" \
   ]; then
  opt_set_default
  opt_sanity_check || exit 1
  to_${opt_state}

elif [ x"$opt_state" = x"add" ]; then
  opt_set_default_for_add
  opt_sanity_check_for_add || exit 1
  to_add

elif [ x"$opt_state" = x"del" ]; then
  opt_set_default_for_del
  opt_sanity_check_for_del || exit 1
  to_del

else
  logger_error "unknown state: \"$opt_state\""
  exit 1
fi

logger_debug "end"

exec 1>&3 3>&- 2>&4 4>&-


#eof
