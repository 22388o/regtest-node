# !/bin/sh
## Sparko configuration.

set -E

###############################################################################
# Environment
###############################################################################

DATA_PATH="/data/lightning"
PEER_PATH="/share/$HOSTNAME"

KEYS_FILE="$DATA_PATH/sparko.keys"
LOGIN_FILE="$DATA_PATH/sparko.login"

DEFAULT_SPARK_USER="user"

SECRET_KEY_PERMS="getinfo,listchannels,listnodes"
INVOICE_KEY_PERMS="pay"
STREAM_KEY_PERMS="stream"

###############################################################################
# Methods
###############################################################################

generate_password() {
  ## Generates a 32 character random password in base64 format.
  ## Includes LC_ALL=C flag for compatibility with other platforms.
  cat /dev/urandom \
    | env LC_ALL=C tr -dc 'a-zA-Z0-9' \
    | fold -w 32 \
    | head -n 1 \
    | base64
}

build_key_str() {
  keystr=""
  for key in `cat $KEYS_FILE`; do
    val=`printf "$key" | awk -F '=' '{ print $2 }'`
    keystr="$keystr$val;"
  done
  printf $keystr
}

###############################################################################
# Script
###############################################################################

if [ -z "$SPARK_USER" ]; then SPARK_USER=$DEFAULT_SPARK_USER; fi
if [ -z "$SPARK_PASS" ]; then SPARK_PASS="$(generate_password)"; fi

## Check if access key exists.
if [ ! -e "$KEYS_FILE" ] || [ -z "$(cat $KEYS_FILE)" ]; then
  printf %b\\n "MASTER_KEY=$(generate_password)" > $KEYS_FILE
  printf %b\\n "SECRET_KEY=$(generate_password):$SECRET_KEY_PERMS" >> $KEYS_FILE
  printf %b\\n "INVOICE_KEY=$(generate_password):$INVOICE_KEY_PERMS" >> $KEYS_FILE
  printf %b\\n "STREAM_KEY=$(generate_password):$STREAM_KEY_PERMS" >> $KEYS_FILE
fi

## Check if login credentials file exists.
if [ ! -e "$LOGIN_FILE" ] || [ -z "$(cat $LOGIN_FILE)" ]; then
  printf %b\\n "USERNAME=$SPARK_USER\nPASSWORD=$SPARK_PASS" > $LOGIN_FILE
fi

## Update configuration in share path.
if [ -d "$PEER_PATH" ]; then
  cp "$KEYS_FILE" "$PEER_PATH"
  cp "$LOGIN_FILE" "$PEER_PATH"
fi

## Return configuration string
printf %s "--sparko-keys=$(build_key_str) --sparko-login=$SPARK_USER:$SPARK_PASS"