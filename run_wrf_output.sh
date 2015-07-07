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
#
# The easiest way to run this is to make a link in the directory with the WRF
# output, then submit it using sbatch

# Josh Laughner <joshlaugh5@gmail.com> 2 Jul 2015

# set mode here - I don't know if sbatch allows it's run scripts to take
# command line arguments. Should be 'hourly', 'daily', or 'monthly'
if [[ $# -lt 1 ]]
then
    mode='hourly'
else
    mode=$1
fi

# export the mode so that the child scripts can access it
export WRFPROCMODE=$mode

# Where the actual scripts are kept.
scriptdir='/global/home/users/laughner/WRF/OUTPUT_PROCESSING'

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
for file in ./wrf*
do
    if [[ $mode == 'monthly' ]]
    then
        newdate=${file:13:7}
    else
        newdate=${file:13:10}
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
    filepattern=$(echo wrfout_d01_${day}_{19,20,21,22}*)
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
        
        $scriptdir/read_wrf_output.sh $filepattern
    fi
done

rm *.tmpnc *.tmp
