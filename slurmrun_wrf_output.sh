#!/bin/bash
# Job name:
#SBATCH --job-name=proc_wrf
#
#SBATCH --partition=savio
#
# Accout:
#SBATCH --account=co_aiolos
#
# QoS (running a condo job)
#SBATCH --qos=aiolos_savio_normal
#
# Luke indicated that processes like these are extremely IO intensive
# so we should limit the number of tasks being performed or the process
# could hang
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=4
#
# Running on the Aiolos condo requires that the run time be less than 
# 24 hrs or the job will not start
# Wall clock limit:
#SBATCH --time=24:00:00
#
# Mail me for any notification
#SBATCH --mail-type=all
#SBATCH --mail-user=jlaughner@berkeley.edu
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
# its purpose is to launch copies of read_wrf_output.sh in parallel.
# This script also collects the names of the WRF output files that belong
# to each group to pass to read_wrf_output.sh, so it can only
# parallelize up to the number of days (in hourly or daily mode) or months
# (in monthly mode). It appears that the NCO tools are not currently 
# intrinsically parallel.
#
# The easiest way to run this is to make a link in the directory with the WRF
# output, then submit it using sbatch

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
        'behr'|'emis'|'tempo'|'avg')
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

# Where the actual scripts are kept. Export it so all other scripts
# know.
scriptdir='/global/home/users/laughner/MATLAB/BEHR/WRF_Utils'
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
    export WRFPROCMODE=$mode # export so we can use it in the save filename
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

# We'll use this to see if we have a multi-prog config file waiting
# to be run - this will be checked after the loop over days/months
# ends to catch if we need to run one more job step to catch the
# number of time periods being not divisible by 4
jobwaiting=0

# Clear out any existing config files
rm wrf_srun_mpc.conf

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
    if [[ $varsout == 'tempo' ]]
    then
        filepattern=$(echo wrfout_d01_${day}*)
    elif [[ $mode != 'monthly' ]]
    then 
        filepattern=$(echo wrfout_d01_${day}_{18,19,20,21,22}*)
    else
        filepattern=$(echo wrfout_d01_${day}-??_{18,19,20,21,22}*)
    fi
    if [[ $filepattern != *'*'* ]]
    then
        echo "    $filepattern"
        # This operation isn't work using multiple 20-core nodes for multiple
        # files - we just want to assign say 4 files at a time to be processed
        # on one node.  Since the man page implies that using srun with the -r
        # flag will cause job steps to be run on different nodes (rather than
        # different tasks on the same node), it looks like the multiple
        # program configuration is our best option. This means that we will
        # have to create a config file for every 4 files we want to run.
        #
        # The catch here is that the multi-prog config file gets... cranky if
        # the lines are too long. So we can't pass the files to operate on to
        # read_wrf_output as individual command line arguments because that
        # will break srun. Instead, we'll list them in the "wrfproclist" files
        # and read_wrf_output should read them from there.
        
        inname="wrfproclist.$jj"
        echo $filepattern > $inname
        
        if [[ $varsout == 'behr' ]]
        then
            echo "$jj $scriptdir/read_wrf_output.sh $inname" >> wrf_srun_mpc.conf
        elif [[ $varsout == 'emis' ]]
        then
            echo "$jj $scriptdir/read_wrf_emis.sh $inname" >> wrf_srun_mpc.conf
        elif [[ $varsout == 'tempo' ]]
        then
            echo "$jj $scriptdir/read_wrf_tempo.sh $inname" >> wrf_srun_mpc.conf
        elif [[ $varsout == 'avg' ]]
        then
            echo "$jj $scriptdir/avg_wrf_output.sh $inname" >> wrf_srun_mpc.conf
        else
            echo "Error at $LINENO in slurmrun_wrf_output.sh: \"$varsout\" is not a recognized operation"
            exit 1
        fi
        jobwaiting=1        

        if [[ $jj -lt $nthreadsM1 ]]
        then
            jj=`expr $jj + 1`
        else
            # Because we're submitting all 4 jobs at once, we don't need a
            # wait statement, srun should't continue until all four job steps 
            # finish
            srun --multi-prog wrf_srun_mpc.conf
 	        cat wrf_srun_mpc.conf
            echo
            echo "Waited for $nthreads file processing scripts to finish. Launching a new batch of $nthreads scripts ..."
            echo
            
            # Reset for the next set of files. Reset the task counter (jj) to 0
            # Remove the existing config file. Reset jobwaiting to false so that
            # if there aren't any more files to run, we won't waste our time after
            # exiting the loop
            jj=0
            rm wrf_srun_mpc.conf
            rm wrfproclist.?
            jobwaiting=0
        fi
    fi
done

if [[ $jobwaiting -ne 0 ]]
then
    # First we need to make sure all allocated tasks have something to do
    for i in `seq $jj $nthreadsM1`
    do
        echo "$i echo 'Unused task'" >> wrf_srun_mpc.conf
    done
    srun --multi-prog wrf_srun_mpc.conf
    cat wrf_srun_mpc.conf
fi

rm *.tmpnc *.tmp *.hrnc
exit 0
