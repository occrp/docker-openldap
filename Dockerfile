FROM debian:jessie

MAINTAINER Michał "rysiek" Woźniak <rysiek@hackerspace.pl>
# original maintainer Christian Luginbühl <dinke@pimprecords.com>

ENV OPENLDAP_VERSION 2.4.40

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        slapd=${OPENLDAP_VERSION}* \
        ldap-utils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mv /etc/ldap /etc/ldap.dist

EXPOSE 389

VOLUME ["/etc/ldap", "/var/lib/ldap", "/var/run/ldap"]

COPY modules/ /etc/ldap.dist/modules
COPY initialdb.ldif /etc/ldap.dist/initialdb.ldif
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

CMD ["slapd", "-d", "32768", "-u", "openldap", "-g", "openldap", "-h", "ldapi://%2fvar%2frun%2fldap%2fldapi ldap:///"]
