#!/usr/bin/env bash
## Startup script for funding the node.

set -E

###############################################################################
# Environment
###############################################################################

BTC_DATA_PATH="/data/bitcoin"
CLN_DATA_PATH="/data/lightning"

BTC_FUND_FILE="$BTC_DATA_PATH/wallet.conf"
CLN_FUND_FILE="$CLN_DATA_PATH/fund.address"

DEFAULT_RPC_SOCK=18446
DEFAULT_MIN_FUNDS=1
FUND_SPLIT=4

FAUCET_CONF=""
FAUCET_WALLET=""
FAUCET_DELAY=0

###############################################################################
# Methods
###############################################################################

greater_than() {
  [ -n "$1" ] && [ -n "$2" ] && \
  [ -n "$(echo "$1 $2" | awk '{ print ($1>=$2) }' | grep 1)" ]
}

wallet_cli() {
  [ -n "$1" ] && bitcoin-cli -rpcwallet=$1 $@
}

faucet_cli() {
  [ -n "$FAUCET_CONF" ] && [ -n "$FAUCET_WALLET" ] && \
  bitcoin-cli $FAUCET_CONF -rpcwallet=$FAUCET_WALLET $@
}

get_btc_balance() {
  bitcoin-cli getbalance
}

get_cln_balance() {
  total=0
  for value in `lightning-cli listfunds | jgrep value`; do total="$((total + value))"; done
  printf "$((total / 100000000))"
  sleep 1
}

is_node_connected() {
  [ -n "$1" ] && [ -n "$(lightning-cli listpeers | jgrep id | grep $1)" ]
}

is_channel_confirmed() {
  [ -n "$1" ] && [ "$(lcli peerchannelcount "$1")" != "0" ]
}

is_channel_funded() {
  [ -n "$1" ] && [ "$(lcli peerchannelbalance "$1")" != "0" ]
}

finish() {
  if [ "$?" -ne 0 ]; then printf "Failed with exit code $?"; templ fail && exit 1; fi
}

###############################################################################
# Script
###############################################################################

trap finish EXIT

templ banner "Funding Configuration"

## Abort early if all daemons are not running.
if [ -z "$(pgrep bitcoind)" ] && [ -z "$(pgrep lightningd)" ]; then 
  printf "Some daemons refused to load. Aborting!"
  templ fail && exit 1
fi

## Set default values.
if [ -z "$RPC_SOCK" ]; then RPC_SOCK=$DEFAULT_RPC_SOCK; fi
if [ -z "$MIN_FUNDS" ]; then MIN_FUNDS=$DEFAULT_MIN_FUNDS; fi

## Fetch details for bitcoin wallet.
btc_address=`cat "$BTC_FUND_FILE" | kgrep ADDRESS`
if [ -z "$btc_address" ]; then 
  printf "Failed to read btc wallet!"
  templ fail && exit 1
fi

## Fetch details for lightning wallet.
cln_address=`cat $CLN_FUND_FILE`
if [ -z "$cln_address" ]; then 
  printf "Failed to read cln wallet!"
  templ fail && exit 1
fi

## Configure faucet
if [ -n "$USE_FAUCET" ]; then

  ## Search for peer file in peers path.
  printf "Checking faucet configuration:\n"
  config=`find "$SHARE_PATH/$USE_FAUCET"* -name bitcoin-peer.conf`

  ## Exit out if peer file is not found.
  if [ ! -e "$config" ]; then templ fail && continue; fi

  ## Parse current peering info.
  onion_host=`cat $config | kgrep ONION_NAME`
  rpc_user=`cat $config | kgrep RPC_USER`
  rpc_pass=`cat $config | kgrep RPC_PASS`

  if [ -n "$(pgrep tor)" ] && [ -n "$onion_host" ]; then
    peer_host="127.0.0.1"
    rpc_port="$RPC_SOCK"
    remote_port=`cat $config | kgrep RPC_PORT`
    if [ -z "$(onionsock -c $RPC_SOCK)" ]; then
      onionsock -p $RPC_SOCK "$onion_host:$remote_port"
    fi
  else
    peer_host="$(cat $config | kgrep HOST_NAME)"
    rpc_port=`cat $config | kgrep RPC_PORT`
  fi

  ## Checking connection to faucet.
  FAUCET_CONF="-rpcconnect=$peer_host -rpcport=$rpc_port -rpcuser=$rpc_user -rpcpassword=$rpc_pass"
  FAUCET_WALLET=`bitcoin-cli $FAUCET_CONF listwallets | tr -d "\" " | tail -n +2 | head -n 1`

  if [ -z "$FAUCET_WALLET" ]; then 
    printf "$IND Faucet configuration failed! Check params:" && templ fail
    printf "$IND '-rpcconnect=$peer_host -rpcport=$rpc_port'\n"
    printf "$IND '-rpcuser=$rpc_user -rpcpassword=$rpc_pass'\n"
  else
    printf "$IND Connected to faucet \"$FAUCET_WALLET\" wallet." && templ conn 
  fi
  echo
fi

## Check if bitcoin wallet has sufficient balance.
printf "Checking bitcoin wallet balance:"
btc_balance=`get_btc_balance`

## If bitcoin balance is low, get funds from faucet.
if ! greater_than $btc_balance $MIN_FUNDS; then
  echo && printf "$IND Bitcoin funds are low! Searching for funding ...\n"
  if [ -n "$MINE_NODE" ]; then
    printf "$IND Mining 5 blocks for funds ...\n"
    bitcoin-cli generatetoaddress 5 $btc_address > /dev/null 2>&1
    if ! greater_than $(get_btc_balance) $MIN_FUNDS; then
      printf "$IND Block height too low! Mining 150 more blocks ...\n"
      bitcoin-cli generatetoaddress 150 $btc_address > /dev/null 2>&1
      if ! greater_than $(get_btc_balance) $MIN_FUNDS; then
        printf "$IND We are still broke! Something is wrong!" && templ fail && exit 1
      fi
    fi
  elif [ -n "$USE_FAUCET" ] && [ -n "$FAUCET_WALLET" ]; then
    printf "$IND Checking faucet ...\n"
    if ! greater_than $(faucet_cli getbalance) $MIN_FUNDS; then 
      printf "$IND Faucet is broke!" && templ fail
    else
      printf "$IND Funding address: $btc_address\n"
      faucet_cli sendtoaddress $btc_address 10 > /dev/null 2>&1
      printf "$IND Waiting for funds to clear ."
      while ! greater_than $(get_btc_balance) $MIN_FUNDS; do sleep 1 && printf "."; done; templ ok
    fi
  else
    printf "$IND No source for funds!" && templ fail && exit 1
  fi
  printf "$IND New Bitcoin balance:" && templ brkt "$(get_btc_balance) BTC."
else 
  templ brkt "$btc_balance BTC."
fi; echo

## Check if lightning wallet has sufficient balance.
printf "Checking lightning wallet balance:"
cln_balance=`get_cln_balance`

## If lightning balance is low, transfer funds from main wallet.
if ! greater_than $cln_balance $MIN_FUNDS; then
  echo && printf "$IND Lightning funds are low! Searching for funding ...\n"
  if ! greater_than $(get_btc_balance) $MIN_FUNDS; then
    printf "$IND Your bitcoin wallet is broke!" && templ fail && exit 1
  else
    printf "$IND Funding address: $cln_address\n"
    rounded_funds=`get_btc_balance | awk -F '.' '{ print $1}'`
    funds_amt="$((rounded_funds / FUND_SPLIT))"
    bitcoin-cli sendtoaddress $cln_address $funds_amt > /dev/null 2>&1
    ## This is a hack to speed up lightning wallet settlment. 
    ## sleep 1 && bitcoin-cli generatetoaddress 1 $cln_address > /dev/null 2>&1
    printf "$IND Waiting for funds to clear ."
    while ! greater_than $(get_cln_balance) $MIN_FUNDS; do sleep 1 && printf "."; done; templ ok
    printf "$IND New Lightning balance:" && templ brkt "$(get_cln_balance) BTC."
  fi
else
  templ brkt "$cln_balance BTC."
fi

## Open a lightning channels with peers.
if [ -n "$CHAN_LIST" ]; then
  sat_amt="5000000"
  for peer in $(printf $CHAN_LIST | tr ',' ' '); do

    ## Search for peer file in peers path.
    echo && printf "Checking channel with $peer:\n"
    config=`find $SHARE_PATH/$peer* -name lightning-peer.conf`

    ## Exit out if peer file is not found.
    if [ ! -e "$config" ]; then templ fail && continue; fi

    ## Parse current peering info.
    node_id=`cat $config | kgrep NODE_ID`
    printf "$IND Node ID: $node_id\n"
  
    ## If valid peer, then connect to node.
    if is_node_connected $node_id; then
      if ! is_channel_confirmed $node_id; then
        printf "$IND Opening channel with $peer for $sat_amt sats.\n"
        printf "$IND Waiting for channel to confirm ."
        lightning-cli fundchannel id=$node_id amount=$sat_amt \
        minconf=1 push_msat=$sat_amt > /dev/null 2>&1
        while ! is_channel_funded $node_id > /dev/null 2>&1; do sleep 1.5 && printf "."; done; templ ok
      fi
      printf "$IND Channel balance:"; templ brkt "$(lcli peerchannelbalance $node_id)"
    else
      printf "$IND No connection to $peer!" && templ fail
    fi
  done
fi