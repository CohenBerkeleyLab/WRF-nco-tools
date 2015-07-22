#!/bin/bash
# Script to be executed on the HPC cluster through the
# slurmrun_wrf_output.sh shell script. Will iterate
# through the list of files passed to it and pull out
# the desired emissions quantities.
#
# Josh Laughner <joshlaugh5@gmail.com> 1 Jul 2015

# Retrieve the operational mode from the environmental variable
mode=$WRFPROCMODE

# Where the various NCO scripts are located
scriptdir=$JLL_WRFSCRIPT_DIR
if [[ $scriptdir == '' ]]
then
    echo "Error at $LINENO in read_wrf_output.sh: JLL_WRFSCRIPT_DIR not set"
    exit 1
fi

# Keep a list of the files to concatenate
catfiles=''

wrffiles=$(cat $1)

for file in $wrffiles
do
    # Get the date from the file names for the save name
    day=${file:11:10}

    # Get the hour of the day (in UTC time) from the file name
    # and write it to our temporary file, we can use this later
    # to select or weight profiles
    hr=${file:22:2}
    echo "        Saving UTC hour..."
    ncap2 -O -v -s "utchr[Time]=$hr" $file $file.tmpnc

    # Copy the variables needed to keep track of position & time,
    # plus the emissions themselves
    echo "        Copying variables..."
    ncks -A -v 'Times,XLAT,XLONG,E_NO,EBIO_NO,EBIO_NO2' $file $file.tmpnc

    # Append the current .tmpnc file to the list of files to concatenate
    catfiles=$(echo $catfiles $file.tmpnc)
done

# WRFPROCMODE is set in the slurmrun script - it's basically the level of averaging
savename="WRF_EMIS_${WRFPROCMODE}_${day}"
# Concatenate (along time as it's the record dimension)
ncrcat $catfiles $savename.tmpnc

# Unless we're keeping the hourly profiles, average over time, weighting
# by the weights we calculated before
if [[ $mode != 'hourly' ]]
then
        ncwa -a Time -w lonweight $savename.tmpnc $savename.nc
else
        mv $savename.tmpnc $savename.nc
fi
