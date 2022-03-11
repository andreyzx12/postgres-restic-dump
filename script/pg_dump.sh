#!/bin/bash

# Check cmd arguments
if [ $# -lt 1 ]; then
  echo "Error: Usage: $0 <csv-dbname>"
  exit 1
fi

# Сheck required utility dependencies
if ! [ -x "$(command -v curl)" ]; then
  echo 'Error: curl is not installed' >&2
  exit 1
fi

# Global vars
csvPath=$1
curlFlags="-s -k"
vaultBaseHost="VAULT_URL"
workdir="/data/pgdumps"

# Function get secret token for role_id and secret_id
# GetVaultToken ${role_id} ${secret_id} - for calling
function GetVaultToken {
    curl --connect-timeout 5 ${curlFlags} "${vaultBaseHost}/v1/auth/approle/login" \
        -d '{"role_id": "'${1}'", "secret_id": "'${2}'"}' \
    | jq .auth.client_token -cr
}

# Function get credentials and parse json
# GetVaultSecret ${secret_dbname} ${token} - for calling
function GetVaultSecret {
    curl --connect-timeout 5 ${curlFlags} \
        -H "X-Vault-Token: ${2}" \
        "${vaultBaseHost}/v1/${1}" \
    | jq '.' -c
}

# Function for parse dsn url
# ParseDsn ${dsn} - fron calling
function ParseDsn {
    protocol="$( echo ${1} | grep :// | sed -e 's#^\(.*://\).*#\1#g')"
    url=$( echo ${1} | sed -e "s#${protocol}##g")
    hostport=$( echo ${url} | sed -e "s,${user}:${password}@,,g" | cut -d '/' -f1)
    host=$( echo ${hostport} | sed -e 's#:.*##g' )
    dbname=$( echo ${url} | grep / | cut -d '/' -f2- | grep ? | cut -d '?' -f1 )
}

# Function up docker container and do dump on remote host
# DumpDb ${user} ${host} ${dbname} ${dsn} - for calling
function DumpDb {
    # get date format day_month_year
    date=$( date +'%Y-%m-%d-%H:%S' )
    
    # init fileName var
    filePath=$(echo -n "${workdir}/${3}@${2}@${date}@${RANDOM}.dump")

    # run db dump
    pg_dump -f ${filePath} --schema=${1} -Fc ${4} && \
    gzip ${filePath}
}

# This loop iterate under csv lines, get vault token, get secret data
# Example csv-line:
    # vault;
    # b49a9b6f-b1cd-c98d-70a8;
    # eb205b01-0df3-90d2-ba56;
    # MX/data/greenfield/some_app/dsn-some_db/5277ad9f-7eb2-11ec
while IFS=";" read -r -a line
do
    # check args count in line
    if [ "${#line[@]}" -ne "4" ]; then
        echo "Error: line fields less then required (4)" 
        exit 1
    fi

    # check PAM system id
    if [ "${line[0]}" == "vault" ]; then

        # get vault token for access to secrets
        token=$( GetVaultToken ${line[1]} ${line[2]} )

        # get vault secret
        secret=$( GetVaultSecret ${line[3]} ${token} )

        # get username from vault secret
        user=$( echo ${secret} | jq '.data.data.user' -cr )

        # get password from vault secret
        password_unencode=$( echo ${secret} | jq '.data.data.password' -cr )

        # encode password 
        password=$(printf %s ${password_unencode} | jq -sRr @uri)

        dsnFormat=$( echo ${secret} | jq '.data.data.dsn' -cr )

        # get dsn from vault secret; setting in dsn username and password
        dsn=$( printf ${dsnFormat} ${user} ${password} )

        # Get extra vars
        ParseDsn ${dsn}
        echo ${host} ${dbname}

        # run docker container to do dump with dsn
        DumpDb ${user} ${host} ${dbname} ${dsn}

    elif [ !"${line[0]}" == "sc" ]; then

        echo "SC"

    else

        echo "Error: undefinded PAM system: ${line[0]} "
        exit 1

    fi
done < ${csvPath}

exit 0
