#!/bin/bash

# When not limiting the open file descritors limit, the memory consumption of
# slapd is absurdly high. See https://github.com/docker/docker/issues/8231
ulimit -n 8192


set -e

# make sure that the run directories exists and has proper permissions
# - /var/run/ldap  -> ldapi:// UNIX socket
# - /var/run/slapd -> pidfile directory
mkdir -p /var/run/ldap/ /var/run/slapd
chown -R openldap:openldap /var/run/ldap/ /var/run/slapd

#
# if we have config *and* database initialized, skip init
#

# config?
if [[ -d /etc/ldap/slapd.d ]]; then
    # aye! since config is there, we're ignoring SLAPD_DBPATH and getting the DBPath from config
    SLAPD_DBPATH="$( grep 'olcDbDirectory' /etc/ldap/slapd.d/cn=config/olcDatabase={1}*.ldif | cut -d ' ' -f 2 )"
    
    # database? can be either mdb, hdb/bdb, or ldif!
    if [ -s "$SLAPD_DBPATH/data.mdb" ] || [ -s "$SLAPD_DBPATH/DB_CONFIG" ] || [ -s "$SLAPD_DBPATH"/*.ldif ]; then
        # aye! skip init!
        SLAPD_SKIP_INIT=1
    fi
fi

#
# TODO if there is no config file, but the $SLAPD_DBPATH/ is not empty and
# contains a slapd database, should we react to it somehow?
# 
# skip init?
# clear the directory?
# 

# are we supposed to skip init?
if [ ! -z ${SLAPD_SKIP_INIT+x} ]; then
    slapd_configs_in_env=`env | grep -v 'SLAPD_SKIP_INIT' | grep 'SLAPD_'`

    if [ -n "${slapd_configs_in_env:+x}" ]; then
        echo "Info: Container already configured, therefore ignoring SLAPD_xxx environment variables"
    fi

#
# not skipping init
# 
# if config exists, that means the db doesn't
# if config does not exis, we do not care about db
#
else

    # we need those
    if [[ -z "$SLAPD_PASSWORD" ]]; then
        echo -n >&2 "Error: Container not configured and SLAPD_PASSWORD not set. "
        echo >&2 "Did you forget to add -e SLAPD_PASSWORD=... ?"
        exit 2
    fi
    # we're gonna need that later
    SLAPD_PASSWORD_HASH="$( slappasswd -s "${SLAPD_PASSWORD}" )"
    SAFE_SLAPD_PASSWORD_HASH=${SLAPD_PASSWORD_HASH//\//\\\/}

    if [[ -z "$SLAPD_DOMAIN" ]]; then
        echo -n >&2 "Error: Container not configured and SLAPD_DOMAIN not set. "
        echo >&2 "Did you forget to add -e SLAPD_DOMAIN=... ?"
        exit 3
    fi
    # we're gonna need that later
    SLAPD_DOMAINDN="dc=${SLAPD_DOMAIN//./,dc=}"

    # and this.
    SLAPD_ORGANIZATION="${SLAPD_ORGANIZATION:-${SLAPD_DOMAIN}}"

    # if the config does not exist...
    if [[ ! -d /etc/ldap/slapd.d ]]; then
        # create it
        cp -a /etc/ldap.dist/* /etc/ldap
    
        # if SLAPD_DBPATH is set, we need to handle it
        if [[ ! -z ${SLAPD_DBPATH+x} ]]; then
            mkdir -p "$SLAPD_DBPATH"
            chown -R openldap:openldap "$SLAPD_DBPATH"
        fi
        
        # config password, if needed
        if [[ -n "$SLAPD_CONFIG_PASSWORD" ]]; then
            SLAPD_CONFIG_PASSWORD_HASH=`slappasswd -s "${SLAPD_CONFIG_PASSWORD}"`
            SAFE_SLAPD_CONFIG_PASSWORD_HASH=${SLAPD_CONFIG_PASSWORD_HASH//\//\\\/}
        fi
        
    
        slapcat -n0 -F /etc/ldap/slapd.d -l /tmp/config.ldif
        # these are mandatory to handle
        sed -i "s/olcSuffix: .*/olcSuffix: $SLAPD_DOMAINDN/" /tmp/config.ldif
        perl -0777 -pi -e "s/olcRootDN: cn=admin,dc=nodomain\nolcRootPW:[^\n]+/olcRootDN: cn=admin,$SLAPD_DOMAINDN\nolcRootPW: $SAFE_SLAPD_PASSWORD_HASH/igs" /tmp/config.ldif
        # handle only the options that are actually set
        [ -z $SAFE_SLAPD_CONFIG_PASSWORD_HASH ] || sed -i "s/\(olcRootDN: cn=admin,cn=config\)/\1\nolcRootPW: ${SAFE_SLAPD_CONFIG_PASSWORD_HASH}/g" /tmp/config.ldif
        [ -z $SLAPD_DBPATH ] || sed -i -r -e "s/^(olcDbDirectory|olcModulePath):.*$/\1: ${SLAPD_DBPATH}/" /tmp/config.ldif
        rm -rf /etc/ldap/slapd.d/*
        slapadd -n0 -F /etc/ldap/slapd.d -l /tmp/config.ldif >/dev/null 2>&1
        
        # permissions
        chown -R openldap:openldap /etc/ldap/slapd.d/
        
        # at this point we should definitely have working config
        SLAPD_DBPATH="$( grep 'olcDbDirectory' /etc/ldap/slapd.d/cn=config/olcDatabase={1}*.ldif | cut -d ' ' -f 2 )"
        # make sure that the database folder exists
        mkdir -p "$SLAPD_DBPATH"
        # permissions
        chown -R openldap:openldap "$SLAPD_DBPATH"
        
        # starting slapd, needed for schemas, modules and init scripts
        echo -n "+-- running temporary slapd process... "
        slapd -d 32768 -u openldap -g openldap -h "ldapi://%2fvar%2frun%2fldap%2fldapi" >/dev/null 2>&1 &
        SLAPD_PID="$!"
        sleep 5
        echo "PID: $SLAPD_PID"
        
        # schemas
        if [[ -n "$SLAPD_ADDITIONAL_SCHEMAS" ]]; then
            IFS=","; declare -a schemas=($SLAPD_ADDITIONAL_SCHEMAS)

            for schema in "${schemas[@]}"; do
                echo "+-- adding schema: $schema..."
                ldapadd -H ldapi://%2fvar%2frun%2fldap%2fldapi -Y EXTERNAL -f "/etc/ldap/schema/${schema}.ldif" >/dev/null 2>&1
            done
        fi

        # modules
        if [[ -n "$SLAPD_ADDITIONAL_MODULES" ]]; then
            IFS=","; declare -a modules=($SLAPD_ADDITIONAL_MODULES)

            for module in "${modules[@]}"; do
                echo "+-- adding module: $module..."
                ldapadd -H ldapi://%2fvar%2frun%2fldap%2fldapi -Y EXTERNAL -f "/etc/ldap/modules/${module}.ldif" >/dev/null 2>&1
            done
        fi
        
        # TODO FIXME handle SLAPD_PASSWORD also in cn=config for olcRootPW?
    
    # if we do have the config, we just need the SLAPD_DBPATH handled, and the server temporarily started
    else
        # at this point we should definitely have working config
        SLAPD_DBPATH="$( grep 'olcDbDirectory' /etc/ldap/slapd.d/cn=config/olcDatabase={1}*.ldif | cut -d ' ' -f 2 )"
        # make sure that the database folder exists
        mkdir -p "$SLAPD_DBPATH"
        # permissions
        chown -R openldap:openldap "$SLAPD_DBPATH"
        # starting slapd, needed for init scripts
        echo -n "+-- running temporary slapd process... "
        slapd -d 32768 -u openldap -g openldap -h "ldapi://%2fvar%2frun%2fldap%2fldapi" >/dev/null 2>&1 &
        SLAPD_PID="$!"
        sleep 5
        echo "PID: $SLAPD_PID"
    fi
    
    # handle initial data
    sed -i "s/#SLAPD_DOMAINDN#/$SLAPD_DOMAINDN/" /etc/ldap/initialdb.ldif
    sed -i "s/#SLAPD_PASSWORD#/$SAFE_SLAPD_PASSWORD_HASH/" /etc/ldap/initialdb.ldif
    sed -i "s/#SLAPD_ORGANIZATION#/$SLAPD_ORGANIZATION/" /etc/ldap/initialdb.ldif
    SLAPD_ROOTDC="$( echo $SLAPD_DOMAIN | cut -d '.' -f 1 )"
    sed -i "s/#SLAPD_ROOTDC#/$SLAPD_ROOTDC/" /etc/ldap/initialdb.ldif
    
    echo "Info: Importing config"
    echo '- - - - - - - - - - - - - - - - - - - - - - - - - - - - - -'
    cat /etc/ldap/initialdb.ldif
    echo
    echo '- - - - - - - - - - - - - - - - - - - - - - - - - - - - - -'
    
    ldapadd -H ldapi://%2fvar%2frun%2fldap%2fldapi -x -D "cn=admin,$SLAPD_DOMAINDN" -w "$SLAPD_PASSWORD" -f /etc/ldap/initialdb.ldif
    rm /etc/ldap/initialdb.ldif
    
    # init scripts
    echo
    if ls /docker-entrypoint-initdb.d/* > /dev/null 2>&1; then
        echo "running scripts from /docker-entrypoint-initdb.d/..."
        for f in /docker-entrypoint-initdb.d/*; do
            case "$f" in
                # run any shell script found, as root
                *.sh)  echo "+-- $0: running $f"; . "$f" ;;
                # run any LDIF scripts found, on the first database
                *.ldif) echo "+-- $0: running $f"; ldapadd -H ldapi://%2fvar%2frun%2fldap%2fldapi -x -D "cn=admin,$SLAPD_DOMAINDN" -w "$SLAPD_PASSWORD" -f "$f" && echo ;;
                # ignoring anything else
                *)     echo "+-- $0: ignoring $f" ;;
            esac
            echo
        done
    fi
    
    # stop the temporary slapd
    kill -INT "$SLAPD_PID"
    
    # as a cherry on top
    # handle base string in /etc/ldap/ldap.conf
    sed -i "s/^#BASE.*/BASE $SLAPD_DOMAINDN/g" /etc/ldap/ldap.conf

    #        slapd slapd/backend select HDB TODO

fi

# run the darn thing
exec "$@"
