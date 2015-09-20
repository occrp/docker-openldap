#!/bin/bash

# When not limiting the open file descritors limit, the memory consumption of
# slapd is absurdly high. See https://github.com/docker/docker/issues/8231
ulimit -n 8192


set -e

# make sure that the run directory exists and has proper permissions
mkdir -p /var/run/slapd/
chown -R openldap:openldap /var/run/slapd/

#
# if we have config *and* database initialized, skip init
#

# config?
if [[ -d /etc/ldap/slapd.d ]]; then
    # aye! since config is there, we're ignoring SLAPD_DBPATH and getting the DBPath from config
    SLAPD_DBPATH="$( grep 'olcDbDirectory' /etc/ldap/slapd.d/cn=config/olcDatabase={1}*.ldif | cut -d ' ' -f 2 )"
    
    # database?
    if [ -s "$SLAPD_DBPATH/data.mdb" ]; then
        # aye! skip init!
        SLAPD_SKIP_INIT=1
    fi
fi


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
        
        if [[ -n "$SLAPD_ADDITIONAL_SCHEMAS" ]]; then
            IFS=","; declare -a schemas=($SLAPD_ADDITIONAL_SCHEMAS)

            for schema in "${schemas[@]}"; do
                slapadd -n0 -F /etc/ldap/slapd.d -l "/etc/ldap/schema/${schema}.ldif" >/dev/null 2>&1
            done
        fi

        if [[ -n "$SLAPD_ADDITIONAL_MODULES" ]]; then
            IFS=","; declare -a modules=($SLAPD_ADDITIONAL_MODULES)

            for module in "${modules[@]}"; do
                slapadd -n0 -F /etc/ldap/slapd.d -l "/etc/ldap/modules/${module}.ldif" >/dev/null 2>&1
            done
        fi

        chown -R openldap:openldap /etc/ldap/slapd.d/
        
        # TODO FIXME handle SLAPD_PASSWORD also in cn=config for olcRootPW?
    fi
    
    # at this point we should definitely have working config
    SLAPD_DBPATH="$( grep 'olcDbDirectory' /etc/ldap/slapd.d/cn=config/olcDatabase={1}*.ldif | cut -d ' ' -f 2 )"
    
    # make sure that the database folder exists
    mkdir -p "$SLAPD_DBPATH"
    
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
    
    slapadd -n1 -F /etc/ldap/slapd.d/ -l /etc/ldap/initialdb.ldif
    rm /etc/ldap/initialdb.ldif
    # permissions
    chown -R openldap:openldap "$SLAPD_DBPATH"
    
    # as a cherry on top
    # handle base string in /etc/ldap/ldap.conf
    sed -i "s/^#BASE.*/BASE $SLAPD_DOMAINDN/g" /etc/ldap/ldap.conf

#        slapd slapd/backend select HDB TODO

fi

# run the darn thing
exec "$@"