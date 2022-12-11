#!/usr/bin/env bash
# fail if any commands fails
set -e
# debug log
if [ "${show_debug_logs}" == "yes" ]; then
  set -x
fi


function checkLogsFile()
{
    FILENAME=$BITRISE_SOURCE_DIR/result.txt
    if [ -f ${FILENAME} ]
    then
        if [ -s ${FILENAME} ]
        then
            printf "\nThere are some vulnerabilities❌\n" 
            exit 1
        else
            printf "\nNo vulnerabilities found 🤩 The log file is empty\n" 
            exit 0
        fi
    else
        echo "There was an issue generating the tartufo log file. Please try again"
        exit 1
    fi 
}


tartufo --quiet --entropy-sensitivity 100 --config ${tartufo_rules_file_path} scan-local-repo $BITRISE_SOURCE_DIR > /Users/fprieto/PersonalProjects/steps-gd-tartufo/result.txt

checkLogsFile 


