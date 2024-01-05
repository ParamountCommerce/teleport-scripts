#!/usr/bin/env bash

display_usage() {
	echo ""
	echo "This script must be run with ENV:  pc or mz  ... or  all  (all - for DevOps only)"
	echo -e "\nUsage:\n\n$0 env"
	echo -e "\nExample: $0 pc\n"
}

# Check params
if [ $# -le 0 ]; then
	display_usage
	exit 1
fi
# set ENV
case "$1" in
pc | pcca)
	ENV=okta-pcca
	;;
mz | mazooma)
	ENV=okta-mazooma
	;;
all)
	ENV=okta
	;;
esac

function ver { printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' '); }

pstr="============================================================================"
tele_login() {
	#Current time + 4hours
	if [[ "$OSTYPE" == "linux-gnu"* ]]; then
		# Linux (GNU version)
		expirylimit=$(date -d '+4 hour' '+%F'T'%T')
	elif [[ "$OSTYPE" == "darwin"* ]]; then
		# MacOS
		expirylimit=$(date -j -v +4H '+%F'T'%T')
	elif [[ "$OSTYPE" == "cygwin" ]]; then
		# POSIX compatibility layer and Linux environment emulation for Windows
		expirylimit=$(date -d '+4 hour' '+%F'T'%T')
	elif [[ "$OSTYPE" == "msys" ]]; then
		# Lightweight shell and GNU utilities compiled for Windows (part of MinGW)
		expirylimit=$(date -d '+4 hour' '+%F'T'%T')
	else
		# Unknown.
		expirylimit=$(date -d '+4 hour' '+%F'T'%T')
	fi

	#Session expiry time
	sessionexpiry=$(tsh status --format=json 2>/dev/null | jq '.active.valid_until' | tr -d "\"")

	if [[ -z "$(tsh status)" ]]; then
		echo "Not logged in"
		tsh logout
		tsh login --proxy=paramountcommerce.teleport.sh --auth=$ENV
	elif [[ "$sessionexpiry" < "$expirylimit" ]]; then
		echo "Teleport session has expired or is expiring soon, launching a new session..."
		tsh logout
		tsh login --proxy=paramountcommerce.teleport.sh --auth=$ENV
		#tsh login --proxy=paramountcommerce.teleport.sh --auth=okta
		#tsh login --proxy=paramountcommerce.teleport.sh --auth=okta-mazooma
		#tsh login --proxy=paramountcommerce.teleport.sh --auth=okta-pcca
	fi
	echo "Teleport Status"
	tsh status
}
tele_version_check() {
	TELEPORT_VERSION=$(curl -s https://paramountcommerce.teleport.sh/webapi/ping | jq -r .server_version | sed -E 's/([0-9]+\.[0-9]{1,3})[^ ]*/\1/g')
	LOCAL_VERSION=$(tsh version --format=json | jq .version | tr -d '"' | sed -E 's/([0-9]+\.[0-9]{1,3})[^ ]*/\1/g')
	#if [ $($TELEPORT_VERSION > $LOCAL_VERSION) ]; then
	#if (( $(echo "$TELEPORT_VERSION $LOCAL_VERSION" | awk '{print ($1 > $2)}') )); then
	#
	[ $(ver $TELEPORT_VERSION) -gt $(ver $LOCAL_VERSION) ] &&
		echo "You seem to be using an older version of tsh client, please upgrade your local teleport version to the cloud version: $TELEPORT_VERSION or higher and retry" &&
		echo "yum install teleport-$(curl -s https://paramountcommerce.teleport.sh/webapi/ping | jq -r .server_version)" &&
		exit
	#fi
}
tele_db() {
	AVAILABLE_ENVS=$(tsh db ls --format=json | jq -r '[.[].metadata.labels.Environment] | unique' | tr -d \" | sed "s/,/ /g")
	echo "Enter the environment you'd like to access $AVAILABLE_ENVS"
	read environment
	if [ -z "$(tsh db ls Environment="$environment" | tail -n +3 | cut -f1 -d' ')" ]; then
		echo "No RDS found for the specified environment, taking you back to the main menu..."
		break
	else
		tsh db ls Environment="$environment"
		echo $pstr
		echo "Enter/Paste the DB name you'd like to connect from the list above:"
		read db_name
		echo "Select DB username : (one of below)"
		echo $(tsh db ls --format=json | jq -r '[.[].users.allowed] | unique')
		read db_user
		tsh db login $db_name --db-user $db_user --db-name postgres
		key=$(tsh db config $db_name --format=json | jq -r '.key')
#		temp_key=$(tsh db config $db_name | grep 'Key:')
#		key=${temp_key#"Key:"}
#		echo $key
		openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt -in $key -out $key.pk8
		connection_info=$(tsh db config $db_name --format=json)
		echo "Hello! Use the below details to configure dBeaver:"
		echo "DB Connection Name : $(echo $connection_info | jq -r '.name')"
		echo "Host : localhost"
		echo "Port : 11144"
		echo "Database : postgres"
		echo "Authentication: Database Native"
		echo "Username : $(echo $connection_info | jq -r '.user')"
		echo "SSL Configuration"
		echo "CA Certificate : $(echo $connection_info | jq -r '.ca')"
		echo "Client Certificate : $(echo $connection_info | jq -r '.cert')"
#		tsh db config $db_name
#		echo "NOTE!"
		echo "Client Private Key: $key.pk8"
#		if [ -z "$(pidof tsh)" ]; then
		if [ -z "$(fuser 11144/tcp)" ]; then
			proxy="tsh proxy db $db_name --port 11144"
			$proxy > /dev/null 2>&1 &
		fi
	fi
}
tele_assume() {
	tsh requests ls
	echo $pstr
	echo "Enter the request ID you'd like to use for this session:"
	read requestid
	tsh request show $requestid
	tsh login --request-id=$requestid
}
tele_k8s() {
  export KUBECONFIG=${HOME?}/teleport-kubeconfig.yaml
  echo "Here is the list of clusters you have access to:"
	tsh kube ls
	echo $pstr
	echo "Enter/Paste the Kubernetes Cluster name you'd like to connect from the list above:"
	read k8s_cluster_name
  tsh kube login $k8s_cluster_name
}

tele_migrate() {
	  echo "NOTE! This script will automatically change the dbeaver connection configuration for HOST to localhost which is a requirement for Teleport TLS versions to work"
		read -p "Continue (y/n)?" choice
		case "$choice" in
			y|Y|yes|Yes|YES )
				echo "You chose YES"
				echo "modifying script..."
				tmp=$(mktemp)
				jq ".connections[].configuration |= (
				    if .host == \"paramountcommerce.teleport.sh\" then
        				.host = \"localhost\"
    				else
				        .
				    end)" ~/.local/share/DBeaverData/workspace6/General/.dbeaver/data-sources.json > "$tmp" && mv "$tmp" ~/.local/share/DBeaverData/workspace6/General/.dbeaver/data-sources.json
				echo "Migration complete, please restart dBeaver"
				;;
			n|N|NO|No|no )
				echo "You chose NO, aborting";;
			* )
				echo "invalid";;
		esac
}
tele_request_access() {
  ALLOWED_ROLES=$(tctl get roles --format json | jq -r '.[] | .metadata.name')
  REQ_TTL=$(expr $(expr $(date +"%s" -d $(tsh status --format=json 2>/dev/null | jq '.active.valid_until' | tr -d "\"")) - $(date +"%s")) / 3600)
	echo "Enter the role(s) separated by comma, you'd like to request access from $ALLOWED_ROLES"
	read req_role
	echo "Type below the reason for your request"
	read req_reason
  tsh request create --roles "$req_role" --reason "$req_reason" --request-ttl "${REQ_TTL}h" > /dev/null 2>&1 &
	echo "Request submitted successfully"
}

PS3='Please enter your choice(1-Tsh Login, 2-ConnectDB, 3-AssumeRole, 4-RequestRoleAccess, 5-ConnectKubernetes, 6-SessionLogout, 7-MigrateToV2Script, 8-Quit): '
options=("Teleport Login" "Connect to DB" "Assume Role & Connect to DB" "Request Role Access" "Connect to Kubernetes Cluster" "Tsh Logout" "Migrate To V2 Script" "Quit")
select opt in "${options[@]}"; do
	case $opt in
	"Teleport Login")
		echo "You chose: Teleport Login"
		tele_version_check
		tele_login
		;;
	"Connect to DB")
		echo "You chose: Connecting to a DB"
		tele_version_check
		tele_login
		tele_db
		;;
	"Assume Role & Connect to DB")
		echo "You chose: Logging in with new access / request ID"
		tele_version_check
		tele_login
		tele_assume
		tele_db
		;;
	"Request Role Access")
		echo "You chose: Request access to a Teleport role"
    tele_request_access
		;;
	"Connect to Kubernetes Cluster")
		echo "You chose: Connecting to a Kubernetes Cluster"
		tele_version_check
		tele_login
    tele_k8s
		;;
	"Tsh Logout")
		echo "You chose: Logging out all teleport sessions"
		tsh logout
#		kill running tsh process
		kill_proxy="fuser -k 11144/tcp"
		$kill_proxy > /dev/null 2>&1 &
		echo "Killed all teleport background processes"
		;;
	"Migrate To V2 Script")
    tele_migrate
		;;
	"Quit")
		break
		;;
	*) echo "invalid option $REPLY" ;;
	esac
done