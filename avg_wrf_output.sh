#!/bin/bash

echo "In avg_wrf_output.sh"

mode=$WRFPROCMODE
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
    echo "Reading day file $file"
    # Get the date from the file names for the save name
    day=${file:11:10}

    # Get the hour of the day (in UTC time) from the file name
    # and write it to our temporary file, we can use this later
    # to select or weight profiles
    hr=${file:22:2}
    echo "        Saving UTC hour..."
    ncap2 -O -v -s "utchr[Time]=$hr" $file $file.tmpnc

    # Copy the variables needed to keep track of position & time,
    # plus the species mixing ratios that we're interested in.
    # U and V are temporary for studying the effect of wind on a priori
    # COSALPHA AND SINALPHA are needed to convert the winds from grid
    # relative to earth relative. See http://forum.wrfforum.com/viewtopic.php?f=8&t=3225
    echo "        Copying variables..."
    # Simpler output, all that is really needed for BEHR. Assumes that calculated_quantities.nco
    # has already been run on the files being averaged
    ncks -A -v 'Times,XLAT,XLONG,no2,z,zlev,pres,TT,ndens,no2_ndens,U,V,COSALPHA,SINALPHA' $file $file.tmpnc
    
    # Also calculate the longitudinal weights (var lonweight)
    # these will be used to weight the time average of the 
    # profiles to account for the representativeness of the 
    # profiles
    echo "        Calculating lonweights..."
    ncap2 -A -v -S $scriptdir/lonweight.nco $file $file.tmpnc

    # Append the current .tmpnc file to the list of files to concatenate
    catfiles=$(echo $catfiles $file.tmpnc)
done

# WRFPROCMODE is set in the slurmrun script - it's basically the level of averaging
savename="WRF_BEHR_${WRFPROCMODE}_${day}"
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
