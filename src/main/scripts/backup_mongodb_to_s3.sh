#!/bin/bash
set -e
set -o pipefail

cat <<EOF >~/.s3cfg
[default]
EOF

if [ a$http_proxy != 'a' ] ; then
  proxy_host=`echo $http_proxy | sed -e 's@http://@@' -e 's/:.*$//'`
  proxy_port=`echo $http_proxy | sed -e 's/^.*://' -e 's@/$@@'`

  cat <<EOF >> ~/.s3cfg
proxy_host = $proxy_host
proxy_port = $proxy_port
EOF
fi

copy_s3 () {
  SRC_FILE=$1
  DEST_FILE=$2

  echo "`date +%Y-%m-%dT%H%M%SZ` Uploading ${DEST_FILE} on S3..."  | tee -a ~/action.log

  if [ -z "${GPG_PASSPHRASE}" ]; then
    echo "`date +%Y-%m-%dT%H%M%SZ` WARNING : GPG_PASSPHRASE is empty" | tee -a ~/action.log
    #echo "cat ${SRC_FILE}  | s3cmd --access_key=${S3_ACCESS_KEY_ID} --secret_key=${S3_SECRET_ACCESS_KEY} --server-side-encryption --ssl put - s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE} || exit 2"
    cat ${SRC_FILE}  | \
     s3cmd --access_key=${S3_ACCESS_KEY_ID} --secret_key=${S3_SECRET_ACCESS_KEY} --ssl --server-side-encryption put - s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE} || exit 2
  else
    echo "`date +%Y-%m-%dT%H%M%SZ` using GPG_PASSPHRASE to encrypt" | tee -a ~/action.log
    #echo "cat ${SRC_FILE}  | s3cmd --access_key=${S3_ACCESS_KEY_ID} --secret_key=${S3_SECRET_ACCESS_KEY} --server-side-encryption --ssl put - s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE} || exit 2"
    echo "${GPG_PASSPHRASE}" | \
     gpg --batch --no-tty --yes --passphrase-fd 0 --symmetric --output - ${SRC_FILE}  | \
     s3cmd --access_key=${S3_ACCESS_KEY_ID} --secret_key=${S3_SECRET_ACCESS_KEY} --ssl --server-side-encryption put - s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE} || exit 2
  fi                                                                                                          
  

  if [ $? != 0 ]; then
    >&2 echo "`date +%Y-%m-%dT%H%M%SZ` Error uploading ${DEST_FILE} on S3" | tee -a ~/action.log
  fi

  rm ${SRC_FILE}
}


if [ -z "${S3_ACCESS_KEY_ID}" ]; then
  echo "`date +%Y-%m-%dT%H%M%SZ` You need to set the S3_ACCESS_KEY_ID environment variable." | tee -a ~/action.log
  exit 1
fi

if [ -z "${S3_SECRET_ACCESS_KEY}" ]; then
  echo "`date +%Y-%m-%dT%H%M%SZ` You need to set the S3_SECRET_ACCESS_KEY environment variable." | tee -a ~/action.log
  exit 1
fi

if [  -z "${S3_BUCKET}" ]; then
  echo "`date +%Y-%m-%dT%H%M%SZ` You need to set the S3_BUCKET environment variable." | tee -a ~/action.log
  exit 1
fi

if [  -z "${S3_PREFIX}" ]; then
  S3_PREFIX="MONGODB"
  echo "`date +%Y-%m-%dT%H%M%SZ` S3_PREFIX is not set in environment variable using ${S3_PREFIX}" | tee -a ~/action.log
  exit 1
fi

if [ -z "${S3_REGION}" ]; then
  S3_REGION="us-west-1"
  echo "`date +%Y-%m-%dT%H%M%SZ` S3_REGION is not set in environment variable using ${S3_REGION}" | tee -a ~/action.log
fi

if [ -z "${MONGODB_VERBOSE}" ]; then
  MONGODB_VERBOSE="0"
  echo "`date +%Y-%m-%dT%H%M%SZ` MONGODB_VERBOSE is not set in environment variable using ${MONGODB_VERBOSE}" | tee -a ~/action.log
fi

if [ -z "${MONGODB_HOST}" ]; then
  MONGODB_HOST="mongodb"
  echo "`date +%Y-%m-%dT%H%M%SZ` S3_REGION is not set in environment variable using $MONGODB_HOST"  | tee -a ~/action.log
fi

if [ -z "${MONGODB_DATABASE}" ]; then
  echo "`date +%Y-%m-%dT%H%M%SZ` You need to set the MONGODB_DATABASE environment variable." | tee -a ~/action.log
  exit 1
fi

if [ -z "${MONGODB_USER}" ]; then
  echo "`date +%Y-%m-%dT%H%M%SZ` You need to set the MONGODB_USER environment variable." | tee -a ~/action.log
  exit 1
fi

if [ -z "${MONGODB_PASSWORD}" ]; then
  echo "`date +%Y-%m-%dT%H%M%SZ` You need to set the MONGODB_PASSWORD environment variable or link to a container named MONGODB."  | tee -a ~/action.log
  exit 1
fi

if [ -z "${GPG_PASSPHRASE}" ]; then
	echo "`date +%Y-%m-%dT%H%M%SZ` WARNING : The GPG_PASSPHRASE is empty" >&2 | tee -a ~/action.log
fi

# env vars needed for aws tools
export AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}
export AWS_DEFAULT_REGION=${S3_REGION}



MONGODB_HOST_OPTS="  --verbose=${MONGODB_VERBOSE} --host=${MONGODB_HOST} --port=${MONGODB_PORT} --username=${MONGODB_USER} --password=${MONGODB_PASSWORD}"


if [ "${MONGODB_DATABASE}" == "--all-databases" ]; then
    MONGO="mongo ${MONGODB_HOST_OPTS} --db=admin --quiet --eval"
    SECONDARY=$(${MONGO} 'db.isMaster()' | grep -c  '"ismaster" : false')
    if [ ${SECONDARY} -eq 1 ]; then
        DATABASES=$(${MONGO} "rs.slaveOk();db.adminCommand( { listDatabases: 1 } )" | /usr/local/bin/jq '.databases[].name' | sed -e 's/^"//'  -e 's/"$//')
    else
        DATABASES=$(${MONGO} "db.adminCommand( { listDatabases: 1 } )" | /usr/local/bin/jq '.databases[].name' | sed -e 's/^"//'  -e 's/"$//')
    fi
else
    DATABASES="$scope"
fi



DUMP_START_TIME=$(date +"%Y-%m-%dT%H%M%SZ")

echo "`date +%Y-%m-%dT%H%M%SZ` Creating dump of ${MONGODB_DATABASE}  and ${DATABASES} database from ${MONGODB_HOST}..." | tee -a ~/action.log

DUMP_FILE="/tmp/dump.raw"
S3_FILE="${DUMP_START_TIME}.dump.raw" 

echo "mongodump ${MONGODB_HOST_OPTS} --archive=${DUMP_FILE} --db=${MONGODB_DATABASE}" | tee -a ~/action.log
mongodump ${MONGODB_HOST_OPTS} --archive=${DUMP_FILE} --db=${MONGODB_DATABASE} | tee -a ~/action.log

copy_s3 ${DUMP_FILE} ${S3_FILE}


echo "`date +%Y-%m-%dT%H%M%SZ` JSON backup uploaded successfully"  | tee -a ~/action.log

bin/notification_webhoock.sh
bin/notification_smtp.sh
