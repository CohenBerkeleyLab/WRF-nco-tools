#!/bin/bash
#
# This script will run the necessary operations to process WRF-Chem output
# for use as BEHR a priori.  There are 3 modes of processing, which should
# be set by modifying the "mode" variable below.
#
#	"hourly" will just extract all profiles within the OMI overpass times 
# of the continental US, with the intention that the user will select the 
# appropriate profile later. 
#	"daily" will average those profiles for each day based on the 
# longitude and UTC time - profiles will be given more weight the closer 
# they are to 1400 local standard time. Those more than an hour off will 
# have a weight of 0.  
#	"monthly" will average with weights as in "daily" but over a month
# rather than a single day.
#
# This script does not directly perform any of those calculations, instead
# it collects the names of the WRF output files that belong
# to each group to pass to read_wrf_output.sh to do the actual calculation.
# This keeps the structure of this program the same as on the HPC cluster,
# where it needs to be done this way to launch multiple instances of 
# read_wrf_output.sh in parallel.

# Josh Laughner <joshlaugh5@gmail.com> 2 Jul 2015

# Parse command arguments looking for two things: the averaging mode and which set of 
# output quantities to copy/calculate. Credit to 
# http://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
# for the code outline.
while [[ $# > 0 ]]
do
keyin="$1"
# Ensure input is lower case
key=$(echo $keyin | awk '{print tolower($0)}')
    case $key in
        'monthly'|'daily'|'hourly')
        mode=$key
        shift # shift the input arguments left by one
        ;;
        'behr'|'emis'|'avg')
        varsout=$key
        shift
        ;;
        *) # catch unrecognized arguments
        echo "The argument \"$key\" is not recognized"
        exit 1
        ;;
    esac
done

# Set the defaults - averaging mode will default to "hourly"
# and the outputs to "behr"
if [[ $mode == '' ]]
then
    mode='hourly'
fi

if [[ $varsout == '' ]]
then
    varsout='behr'
 fi

# export the mode so that the child scripts can access it
export WRFPROCMODE=$mode

# Where the actual scripts are kept.
scriptdir='/Users/Josh/Documents/MATLAB/BEHR/WRF_Utils/'
export JLL_WRFSCRIPT_DIR=$scriptdir

# nprocs should match the number of cpus in the node (32 for brewer)
nprocs=20
# nthreads should divide nprocs evenly. Small is good.
nthreads=4

# Initialization
nthreadsM1=`expr $nthreads - 1`     # just nthreads minus 1
procskip=`expr $nprocs / $nthreads` # number of processors to skip
jj=0                                # parallel thread counter


# Check the mode selection

if [[ $mode != 'daily' && $mode != 'monthly' && $mode != 'hourly' ]]
then
    echo "Input must be 'daily' or 'monthly'"
    exit 1
else
    echo "mode set to $mode"
fi

# Find all unique dates - we'll need this to iterate over each day
# If we're doing monthly averages, then we just need to get the year and month
dates=''
olddate=''
for file in ./wrfout*
do
    # Handle wrfout and wrfout_subset files
    dtmp=$(awk -v a="$file" -v b="d01" 'BEGIN{print index(a,b)}')
    dstart=$((dtmp+3))
    if [[ $mode == 'monthly' ]]
    then
        newdate=${file:$dstart:7}
    else
        newdate=${file:$dstart:10}
    fi

    if [[ $olddate != $newdate ]]
    then
        dates=$(echo $dates $newdate)
    fi
    olddate=$newdate
done


for day in $dates
do
    echo ""
    echo "Files on $day"
    echo ""
    # WRF file names include output time in UTC. We'll look for the output
    # in the range of UTC times when OMI will be passing over North America
    # for this day
    # If there are no files for this day or month, then it will try to iterate
    # over the wildcard patterns themselves. Since those contain *, we
    # can avoid doing anything in that case by requiring that the file
    # name does not include a *
    filepattern=$(echo wrfout*_d01_${day}-??_{18,19,20,21,22}*)
    if [[ $filepattern != *'*'* ]]
    then
        echo "    $filepattern"
        echo "$filepattern" > read_wrf.conf
        # Choose which command to execute based on the command arguments
        if [[ $varsout == 'behr' ]]
        then
            echo "Calling read_wrf_output"
            $scriptdir/read_wrf_output.sh read_wrf.conf
        elif [[ $varsout == 'emis' ]]
        then
            $scriptdir/read_wrf_emis.sh read_wrf.conf
        elif [[ $varsout == 'avg' ]]
        then
            $scriptdir/avg_wrf_output.sh read_wrf.conf
        else
            echo "Error at $LINENO in slurmrun_wrf_output.sh: \"$varsout\" is not a recognized operation"
            exit 1
        fi
    fi
done

rm *.tmpnc *.tmp
